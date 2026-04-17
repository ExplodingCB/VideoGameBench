"""Flask dashboard for BalatroBench.

Run with: `python -m bench serve`

Exposes a single-page dashboard where you can:
  - pick an OpenRouter model (autocomplete from the OpenRouter catalog)
  - choose a deck / stake / number of runs
  - start a benchmark batch and watch each run graph itself live
  - browse historical runs stored in results.jsonl + run_events/

The server uses threads (not asyncio) to keep things simple: one background
thread orchestrates the benchmark run, each browser opens an SSE stream that
tails the per-run JSONL files written by bench.runner.EventLogger.
"""

from __future__ import annotations

import json
import os
import queue
import threading
import time
from dataclasses import dataclass, field
from typing import Optional

import requests
from flask import Flask, Response, jsonify, request, stream_with_context

from .balatro_supervisor import restart_balatro_and_wait_for_mod
from .client import BalatroBenchClient
from .config import load_config
from .models import ModelAdapter
from .results import ResultsTracker
from .runner import EVENTS_DIR, BenchmarkRunner, EventLogger


REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESULTS_FILE = os.path.join(REPO_ROOT, "results.jsonl")
SETTINGS_FILE = os.path.join(REPO_ROOT, ".webapp_settings.json")
STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")


# ---------------------------------------------------------------------------
# Settings persistence (active model, default deck/stake)
# ---------------------------------------------------------------------------

DEFAULT_SETTINGS = {
    "model": "arcee-ai/trinity-large-preview:free",
    "provider": "openrouter",
    "deck": "Red Deck",
    "stake": 1,
    "runs": 5,
    "api_key": "",  # optional override — else OPENROUTER_API_KEY env var is used
    # When true, kill+relaunch Balatro before every run. Costs ~20s per run
    # but guarantees the mod is in a clean state. Strongly recommended: we've
    # seen models trip the mod into unrecoverable states and subsequent runs
    # silently time out with 0 actions.
    "auto_restart_balatro": True,
}


def load_settings() -> dict:
    if os.path.exists(SETTINGS_FILE):
        try:
            with open(SETTINGS_FILE, "r", encoding="utf-8") as f:
                data = json.load(f)
                return {**DEFAULT_SETTINGS, **data}
        except (OSError, json.JSONDecodeError):
            pass
    return dict(DEFAULT_SETTINGS)


def save_settings(updates: dict) -> dict:
    current = load_settings()
    current.update(updates)
    with open(SETTINGS_FILE, "w", encoding="utf-8") as f:
        json.dump(current, f, indent=2)
    return current


# ---------------------------------------------------------------------------
# Job orchestration — at most one benchmark batch runs at a time
# ---------------------------------------------------------------------------


@dataclass
class Job:
    job_id: str
    model: str
    provider: str
    deck: str
    stake: int
    requested_runs: int
    auto_restart_balatro: bool = True
    run_ids: list[str] = field(default_factory=list)
    current_run_index: int = 0
    status: str = "queued"  # queued | running | restarting_game | finished | failed | stopped
    error: Optional[str] = None
    started_at: float = field(default_factory=time.time)
    finished_at: Optional[float] = None
    stop_requested: bool = False


JOB_LOCK = threading.Lock()
CURRENT_JOB: Optional[Job] = None


def _job_snapshot(job: Optional[Job]) -> Optional[dict]:
    if job is None:
        return None
    return {
        "job_id": job.job_id,
        "model": job.model,
        "provider": job.provider,
        "deck": job.deck,
        "stake": job.stake,
        "requested_runs": job.requested_runs,
        "auto_restart_balatro": job.auto_restart_balatro,
        "run_ids": list(job.run_ids),
        "current_run_index": job.current_run_index,
        "status": job.status,
        "error": job.error,
        "started_at": job.started_at,
        "finished_at": job.finished_at,
    }


def _connect_client(host: str, port: int, retries: int = 30) -> Optional[BalatroBenchClient]:
    """Open a fresh TCP client to the mod. Returns None on failure."""
    client = BalatroBenchClient(host=host, port=port)
    if not client.connect(retries=retries):
        return None
    return client


def _run_job(job: Job, api_key: str, host: str, port: int):
    """Worker thread: runs `job.requested_runs` benchmark runs back to back.

    If job.auto_restart_balatro is True (the default), we kill + relaunch
    Balatro before each run so the mod always starts from main menu in a
    known-clean state. This costs ~20s per run but prevents the silent
    "0 actions, 104s timeout" failure mode where a previous run left the
    mod in an unrecoverable state.
    """
    global CURRENT_JOB
    tracker = ResultsTracker(RESULTS_FILE)
    client: Optional[BalatroBenchClient] = None
    try:
        adapter = ModelAdapter(model=job.model, provider=job.provider, api_key=api_key or None)

        import uuid
        for i in range(job.requested_runs):
            if job.stop_requested:
                job.status = "stopped"
                break
            job.current_run_index = i + 1

            # Drop any stale client — a restart will invalidate the socket.
            if client is not None and job.auto_restart_balatro:
                try: client.disconnect()
                except Exception: pass
                client = None

            # Restart Balatro before every run when auto_restart is on.
            # This guarantees the mod begins at the main menu, not in some
            # post-game-over zombie state.
            if job.auto_restart_balatro:
                job.status = "restarting_game"
                ok, msg = restart_balatro_and_wait_for_mod(host=host, port=port)
                if not ok:
                    job.status = "failed"
                    job.error = f"Balatro restart failed: {msg}"
                    return
                # Give the mod loop a beat to fully settle before we connect
                time.sleep(1.5)

            # Fresh TCP connection for this run
            if client is None:
                client = _connect_client(host, port)
                if client is None:
                    job.status = "failed"
                    job.error = f"Cannot connect to Balatro mod at {host}:{port} after restart"
                    return

            job.status = "running"
            runner = BenchmarkRunner(client=client, model=adapter,
                                     results=tracker, verbose=False)

            # Pre-generate a run_id so we can register it before the run
            # starts — the browser polls /api/status to discover new
            # run_ids and opens an SSE stream for each one.
            run_id = f"run_{time.strftime('%Y%m%d_%H%M%S')}_{uuid.uuid4().hex[:6]}"

            def _on_start(rid):
                if rid not in job.run_ids:
                    job.run_ids.append(rid)

            # Wire the Stop button: the runner polls this callable at
            # safe points (before each loop iteration, before each model
            # call) and aborts as soon as it returns True.
            record = runner.run(deck=job.deck, stake=job.stake,
                                run_id=run_id, on_run_start=_on_start,
                                should_stop=lambda: job.stop_requested)

            # "go until either it wins or loses": stop the batch early
            # when a run is won, since continuing past a win doesn't add
            # new information. Losses continue the batch up to the cap.
            if record.get("result", {}).get("won"):
                job.status = "finished"
                break

        # Resolve final status: if user asked to stop, mark stopped;
        # otherwise mark finished (whether we early-terminated on a win
        # or completed the full requested count).
        if job.stop_requested:
            job.status = "stopped"
        else:
            job.status = "finished"
    except Exception as exc:  # noqa: BLE001 — surface any failure to UI
        job.status = "failed"
        job.error = f"{type(exc).__name__}: {exc}"
    finally:
        # Tidy the socket — Balatro itself is left running for the user.
        if client is not None:
            try: client.disconnect()
            except Exception: pass
        job.finished_at = time.time()
        with JOB_LOCK:
            # Don't clear CURRENT_JOB — leave it as the last job so polling
            # clients can still read its final state. Starting a new job
            # replaces this atomically.
            pass


# ---------------------------------------------------------------------------
# OpenRouter model catalog (cached)
# ---------------------------------------------------------------------------

_MODEL_CACHE = {"ts": 0.0, "models": []}


def fetch_openrouter_models() -> list[dict]:
    """Return (and cache for 10 min) the list of OpenRouter models."""
    now = time.time()
    if _MODEL_CACHE["models"] and now - _MODEL_CACHE["ts"] < 600:
        return _MODEL_CACHE["models"]
    try:
        r = requests.get("https://openrouter.ai/api/v1/models", timeout=10)
        r.raise_for_status()
        data = r.json()
        models = [{"id": m["id"],
                   "name": m.get("name", m["id"]),
                   "context": m.get("context_length"),
                   "pricing": m.get("pricing", {})}
                  for m in data.get("data", [])]
        models.sort(key=lambda x: x["id"])
        _MODEL_CACHE["models"] = models
        _MODEL_CACHE["ts"] = now
    except Exception:
        pass  # keep any stale cache
    return _MODEL_CACHE["models"]


# ---------------------------------------------------------------------------
# Flask app
# ---------------------------------------------------------------------------

def create_app() -> Flask:
    app = Flask(__name__, static_folder=STATIC_DIR, static_url_path="/static")

    @app.route("/")
    def index():
        index_path = os.path.join(STATIC_DIR, "index.html")
        with open(index_path, "r", encoding="utf-8") as f:
            return Response(f.read(), mimetype="text/html")

    @app.route("/api/models")
    def api_models():
        models = fetch_openrouter_models()
        return jsonify({"models": models})

    @app.route("/api/settings", methods=["GET", "POST"])
    def api_settings():
        if request.method == "POST":
            payload = request.get_json(force=True) or {}
            # Only allow known keys through
            allowed = set(DEFAULT_SETTINGS.keys())
            updates = {k: v for k, v in payload.items() if k in allowed}
            if "stake" in updates:
                try:
                    updates["stake"] = int(updates["stake"])
                except (TypeError, ValueError):
                    updates.pop("stake")
            if "runs" in updates:
                try:
                    updates["runs"] = max(1, min(100, int(updates["runs"])))
                except (TypeError, ValueError):
                    updates.pop("runs")
            saved = save_settings(updates)
            return jsonify(saved)
        return jsonify(load_settings())

    @app.route("/api/start", methods=["POST"])
    def api_start():
        global CURRENT_JOB
        payload = request.get_json(force=True) or {}
        settings = load_settings()

        with JOB_LOCK:
            if CURRENT_JOB and CURRENT_JOB.status in ("queued", "running"):
                return jsonify({"error": "A job is already running",
                                "job": _job_snapshot(CURRENT_JOB)}), 409

            config = load_config(os.path.join(REPO_ROOT, "config.yaml"))
            defaults = config.get("default", {})
            host = payload.get("host") or defaults.get("mod_host", "127.0.0.1")
            port = int(payload.get("port") or defaults.get("mod_port", 12345))

            model = payload.get("model") or settings["model"]
            provider = payload.get("provider") or settings["provider"]
            deck = payload.get("deck") or settings["deck"]
            stake = int(payload.get("stake") or settings["stake"])
            runs = max(1, min(100, int(payload.get("runs") or settings["runs"])))
            api_key = payload.get("api_key") or settings.get("api_key") or os.environ.get("OPENROUTER_API_KEY", "")
            # auto_restart is an explicit bool — only override the saved
            # setting if the caller sends the key. We treat None (missing)
            # as "use saved value".
            auto_restart = payload.get("auto_restart_balatro")
            if auto_restart is None:
                auto_restart = bool(settings.get("auto_restart_balatro", True))
            else:
                auto_restart = bool(auto_restart)

            # Persist the choice so next visit remembers it
            save_settings({"model": model, "provider": provider, "deck": deck,
                           "stake": stake, "runs": runs,
                           "auto_restart_balatro": auto_restart})

            import uuid
            job = Job(
                job_id=f"job_{int(time.time())}_{uuid.uuid4().hex[:6]}",
                model=model, provider=provider, deck=deck, stake=stake,
                requested_runs=runs, auto_restart_balatro=auto_restart,
            )
            CURRENT_JOB = job
            t = threading.Thread(target=_run_job, args=(job, api_key, host, port), daemon=True)
            t.start()
            return jsonify({"job": _job_snapshot(job)})

    @app.route("/api/stop", methods=["POST"])
    def api_stop():
        with JOB_LOCK:
            if CURRENT_JOB and CURRENT_JOB.status in ("queued", "running"):
                CURRENT_JOB.stop_requested = True
                return jsonify({"job": _job_snapshot(CURRENT_JOB)})
        return jsonify({"error": "No running job"}), 404

    @app.route("/api/status")
    def api_status():
        return jsonify({"job": _job_snapshot(CURRENT_JOB)})

    @app.route("/api/runs")
    def api_runs():
        """All historical runs from results.jsonl, newest first."""
        records = []
        if os.path.exists(RESULTS_FILE):
            with open(RESULTS_FILE, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        records.append(json.loads(line))
                    except json.JSONDecodeError:
                        continue
        records.reverse()
        return jsonify({"runs": records})

    @app.route("/api/run/<run_id>/events")
    def api_run_events(run_id):
        """Return all events for a given run_id (one-shot, non-streaming)."""
        path = os.path.join(EVENTS_DIR, f"{run_id}.jsonl")
        events = []
        if os.path.exists(path):
            with open(path, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        events.append(json.loads(line))
                    except json.JSONDecodeError:
                        continue
        return jsonify({"run_id": run_id, "events": events})

    @app.route("/api/run/<run_id>/stream")
    def api_run_stream(run_id):
        """Server-sent events: tail the run's JSONL as it's written."""
        path = os.path.join(EVENTS_DIR, f"{run_id}.jsonl")

        @stream_with_context
        def gen():
            pos = 0
            deadline = time.time() + 60 * 30  # hard 30-min stream cap
            finished = False
            while time.time() < deadline and not finished:
                if os.path.exists(path):
                    with open(path, "r", encoding="utf-8") as f:
                        f.seek(pos)
                        for line in f:
                            line = line.strip()
                            if not line:
                                continue
                            yield f"data: {line}\n\n"
                            try:
                                parsed = json.loads(line)
                                if parsed.get("type") == "run_finished":
                                    finished = True
                            except json.JSONDecodeError:
                                pass
                        pos = f.tell()
                # Heartbeat so proxies don't drop the connection
                yield ": keepalive\n\n"
                time.sleep(0.75)

        return Response(gen(), mimetype="text/event-stream")

    @app.route("/api/job/stream")
    def api_job_stream():
        """SSE: emit the current job's snapshot every 1s."""
        @stream_with_context
        def gen():
            last_snap = None
            deadline = time.time() + 60 * 30
            while time.time() < deadline:
                snap = _job_snapshot(CURRENT_JOB)
                if snap != last_snap:
                    yield f"data: {json.dumps(snap)}\n\n"
                    last_snap = snap
                    if snap and snap.get("status") in ("finished", "failed", "stopped"):
                        # Give the client one final snapshot, then stop.
                        break
                yield ": keepalive\n\n"
                time.sleep(1.0)

        return Response(gen(), mimetype="text/event-stream")

    return app


def serve(host: str = "127.0.0.1", port: int = 5000):
    app = create_app()
    print(f"BalatroBench dashboard running at http://{host}:{port}")
    app.run(host=host, port=port, threaded=True, debug=False)


if __name__ == "__main__":
    serve()
