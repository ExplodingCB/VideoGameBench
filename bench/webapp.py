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
from .models import (
    ALL_PROVIDERS,
    STATIC_CONTEXT_WINDOWS,
    ModelAdapter,
    make_adapter,
)
from .results import (
    CHIP_LOG_CAP,
    MAX_ROUNDS,
    TOKEN_HALVING_POINT,
    WEIGHT_CHIPS,
    WEIGHT_ROUND,
    WEIGHT_TOKENS,
    ResultsTracker,
    score_run,
)
from .runner import EVENTS_DIR, BenchmarkRunner, EventLogger


REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESULTS_FILE = os.path.join(REPO_ROOT, "results.jsonl")
SETTINGS_FILE = os.path.join(REPO_ROOT, ".webapp_settings.json")
STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")


# ---------------------------------------------------------------------------
# Settings persistence (active model, default deck/stake)
# ---------------------------------------------------------------------------

DEFAULT_SETTINGS = {
    "model": "deepseek/deepseek-v3.2",
    "provider": "openrouter",
    "deck": "Red Deck",
    "stake": 1,
    "runs": 5,
    # Legacy single key field — still honored so old settings files
    # don't lose their saved OpenRouter key. New callers should use the
    # per-provider fields below; /api/settings migrates on first save.
    "api_key": "",
    # One API key slot per supported native provider. The dashboard UI
    # swaps the active input based on which provider is selected. Keys
    # are persisted to .webapp_settings.json locally (gitignored) and
    # never sent to the model calls of OTHER providers.
    "api_key_openrouter": "",
    "api_key_openai": "",
    "api_key_anthropic": "",
    "api_key_google": "",
    "api_key_inception": "",
    "api_key_cerebras": "",
    # When true, kill+relaunch Balatro before every run. Costs ~20s per run
    # but guarantees the mod is in a clean state. Strongly recommended: we've
    # seen models trip the mod into unrecoverable states and subsequent runs
    # silently time out with 0 actions.
    "auto_restart_balatro": True,
}

# Env var fallback per provider. Checked only when the user hasn't saved
# a key in the dashboard — keeps existing shell-based setups working.
PROVIDER_ENV_KEYS = {
    "openrouter": "OPENROUTER_API_KEY",
    "openai":     "OPENAI_API_KEY",
    "anthropic":  "ANTHROPIC_API_KEY",
    "google":     "GOOGLE_API_KEY",  # also accepts GEMINI_API_KEY
    "inception":  "INCEPTION_API_KEY",
    "cerebras":   "CEREBRAS_API_KEY",
}


def _resolve_api_key(provider: str, settings: dict, override: str | None = None) -> str:
    """Pick the right API key for a given provider.
    Precedence: explicit override → provider-specific setting → legacy
    `api_key` field (only for openrouter) → environment variable."""
    if override:
        return override
    provider = (provider or "openrouter").lower()
    key = settings.get(f"api_key_{provider}") or ""
    if key:
        return key
    # Legacy fallback: the pre-multi-provider settings file had one
    # `api_key` field that was always OpenRouter's. Respect it for
    # backward compatibility but nothing else.
    if provider == "openrouter" and settings.get("api_key"):
        return settings["api_key"]
    env_name = PROVIDER_ENV_KEYS.get(provider)
    if env_name:
        env_val = os.environ.get(env_name, "")
        if env_val:
            return env_val
        # Google has a second accepted env var name
        if provider == "google":
            return os.environ.get("GEMINI_API_KEY", "")
    return ""


# Curated per-provider model pickers. OpenRouter gets its catalog from
# the live /api/v1/models endpoint (already cached by fetch_openrouter_models
# later in this file), but the three direct providers don't expose a
# public models-list without auth, and even with auth their lists are
# very long (OpenAI returns 80+ IDs, most useless for benchmarking).
# Hardcoding a curated list keeps the dropdown sane and gives users a
# sensible starting set. Users can always type a custom model ID too.
# Curated per-provider model lineups, verified against each vendor's own
# docs as of April 2026:
#   - OpenAI:    developers.openai.com/api/docs/models/all
#   - Anthropic: platform.claude.com/docs/en/about-claude/models/overview
#   - Google:    ai.google.dev/gemini-api/docs/models
# The first entry in each list is the vendor's current flagship.
CURATED_MODELS = {
    "openai": [
        # GPT-5.4 is the current frontier line (5.4 Pro and the mini/nano
        # tiers were introduced after the original GPT-5 was retired from
        # ChatGPT). All 5.x share a 400k context window.
        "gpt-5.4",
        "gpt-5.4-pro",
        "gpt-5.4-mini",
        "gpt-5.4-nano",
        "gpt-5",
        "gpt-5-mini",
        "gpt-5-nano",
        # Coding-specialist snapshots — still chat-completions compatible
        # and useful as reasoning baselines since they're cheaper than
        # 5.4 Pro but share the same family capabilities.
        "gpt-5-codex",
        "gpt-5.3-codex",
        "gpt-5.2-codex",
        # GPT-4.1 / 4o family — API-available even though retired from
        # ChatGPT in Feb 2026. Included for cost-floor baselines.
        "gpt-4.1",
        "gpt-4.1-mini",
        "gpt-4o",
        "gpt-4o-mini",
    ],
    "anthropic": [
        # Claude Opus 4.7 is the latest flagship (released April 2026).
        # Opus 4.7 + Sonnet 4.6 have 1M-token context windows; Haiku 4.5
        # and all older models are 200k. Aliases like "claude-opus-4-7"
        # resolve to the current snapshot server-side — we use them here
        # so the benchmark auto-follows updates without a code change.
        "claude-opus-4-7",
        "claude-sonnet-4-6",
        "claude-haiku-4-5",
        # Legacy (still available)
        "claude-opus-4-6",
        "claude-sonnet-4-5",
        "claude-opus-4-5",
        "claude-opus-4-1",
    ],
    "google": [
        # Gemini 3.1 Pro Preview (Feb 2026) is the current reasoning
        # flagship. 3 Flash / 3.1 Flash-Lite previews fill the speed
        # tier. 2.5 family remains as the cost-optimized fallback.
        # gemini-3-pro-preview was shut down 2026-03-09 so we don't list
        # it here.
        "gemini-3.1-pro-preview",
        "gemini-3-flash-preview",
        "gemini-3.1-flash-lite-preview",
        "gemini-2.5-pro",
        "gemini-2.5-flash",
        "gemini-2.5-flash-lite",
    ],
    "inception": [
        # Inception Labs' Mercury family — diffusion-based LLMs. mercury-2
        # is the current flagship (128k context), mercury-2-mini is the
        # smaller/faster variant. mercury-coder is the coding-specialist
        # snapshot of v1. Endpoint is OpenAI-compatible, so the same
        # ModelAdapter handles it — we just route a different base URL.
        "mercury-2",
        "mercury-2-mini",
        "mercury-coder",
        "mercury",
    ],
    "cerebras": [
        # Cerebras Inference — open-weight models served on wafer-scale
        # chips at ~1000+ tok/s. April 2026 tier access is NOT uniform:
        # the /v1/models endpoint lists every model on the platform,
        # but individual API keys may only have tier access to a subset.
        # Ordered here with the commonly-accessible models first
        # (llama3.1-8b, qwen-3-235b), so the default pick works for new
        # accounts. 404s on a specific model usually mean "upgrade tier
        # or request access" rather than a typo.
        "qwen-3-235b-a22b-instruct-2507",
        "llama3.1-8b",
        # Tier-gated on most accounts:
        "gpt-oss-120b",
        "zai-glm-4.7",
        # Other models Cerebras advertises (may appear on enterprise tiers):
        "llama-3.3-70b",
        "llama-4-scout-17b-16e-instruct",
        "qwen-3-32b",
        "qwen-3-coder-480b",
    ],
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
        # Factory picks the right adapter class based on provider —
        # OpenAI-compat for openrouter/openai/local/custom, AnthropicAdapter
        # for anthropic, GeminiAdapter for google. Interface is identical
        # so the rest of the runner doesn't branch on provider.
        adapter = make_adapter(
            provider=job.provider,
            model=job.model,
            api_key=api_key or None,
        )

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
        """Model catalog for the picker. Behavior depends on ?provider=:
          - openrouter (default): live fetch from OpenRouter's /api/v1/models
          - openai / anthropic / google: curated list from CURATED_MODELS
          - anything else: empty — user can still type a custom model ID.
        Returns {models: [{id, name, description}]} so the frontend can
        render the same datalist shape for all providers.
        """
        provider = (request.args.get("provider") or "openrouter").lower()
        if provider == "openrouter":
            return jsonify({"models": fetch_openrouter_models()})
        if provider in CURATED_MODELS:
            models = [
                {"id": mid, "name": mid, "description": ""}
                for mid in CURATED_MODELS[provider]
            ]
            return jsonify({"models": models})
        return jsonify({"models": []})

    @app.route("/api/settings", methods=["GET", "POST"])
    def api_settings():
        """Read/write the dashboard's settings blob. The blob now stores
        a key per provider (api_key_openrouter, _openai, _anthropic,
        _google) so switching providers in the UI doesn't clobber keys.
        The legacy single `api_key` field is still honored for reads
        (maps to openrouter) so existing .webapp_settings.json works."""
        if request.method == "POST":
            payload = request.get_json(force=True) or {}
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
            provider = (payload.get("provider") or settings["provider"] or "openrouter").lower()
            if provider not in ALL_PROVIDERS:
                return jsonify({"error": f"Unknown provider '{provider}'. "
                                         f"Valid: {sorted(ALL_PROVIDERS)}"}), 400
            deck = payload.get("deck") or settings["deck"]
            stake = int(payload.get("stake") or settings["stake"])
            runs = max(1, min(100, int(payload.get("runs") or settings["runs"])))
            # The frontend sends the API key for the currently-selected
            # provider as `api_key`. We accept that as an override, then
            # fall back to the provider-specific stored setting, then to
            # the env var. _resolve_api_key handles the whole precedence.
            api_key = _resolve_api_key(provider, settings, payload.get("api_key"))
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
        """All historical runs from results.jsonl, newest first. Each record
        gets a `rating` field computed retroactively by score_run() so old
        runs contribute to the leaderboard without re-running them."""
        records = []
        if os.path.exists(RESULTS_FILE):
            with open(RESULTS_FILE, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        rec = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    rec["rating"] = score_run(rec)
                    records.append(rec)
        records.reverse()
        return jsonify({"runs": records})

    @app.route("/api/leaderboard")
    def api_leaderboard():
        """Per-model leaderboard with BalatroBench ratings. The dashboard's
        bottom chart reads this. Returns:
          - models: sorted list of per-model entries with avg/best rating,
            run counts, wins, and the raw rating list for spark-lines.
          - scoring_weights: so the UI can show the R/T/C breakdown in a
            tooltip without hardcoding the weights in two places.
        """
        tracker = ResultsTracker(RESULTS_FILE)
        board = tracker.get_leaderboard()
        return jsonify({
            "models": board,
            "scoring_weights": {
                "round": WEIGHT_ROUND,
                "tokens": WEIGHT_TOKENS,
                "chips": WEIGHT_CHIPS,
                "token_halving_point": TOKEN_HALVING_POINT,
                "chip_log_cap": CHIP_LOG_CAP,
                "max_rounds": MAX_ROUNDS,
            },
        })

    def _delete_run_records(run_ids: set[str]) -> dict:
        """Remove the given run_ids from results.jsonl and delete their
        per-run event log files. Writes results.jsonl atomically (temp
        file + rename) so a crash mid-delete can't produce a partial
        file. Returns a breakdown of what was actually removed so the
        caller can surface it to the UI."""
        removed_from_results = 0
        removed_event_files = 0
        skipped_active = []

        # Guard: never delete a run that the currently-running job is
        # actively producing. If we yanked its line out of results.jsonl
        # mid-run, the next run_finished emission would recreate it and
        # the user would be confused why their "delete" silently
        # reappeared.
        with JOB_LOCK:
            active_ids = set()
            if CURRENT_JOB and CURRENT_JOB.status in ("queued", "running", "restarting_game"):
                active_ids = set(CURRENT_JOB.run_ids or [])

        for rid in list(run_ids):
            if rid in active_ids:
                skipped_active.append(rid)
                run_ids.discard(rid)

        # Rewrite results.jsonl without the matching lines.
        if os.path.exists(RESULTS_FILE) and run_ids:
            tmp_path = RESULTS_FILE + ".tmp"
            with open(RESULTS_FILE, "r", encoding="utf-8") as src, \
                 open(tmp_path, "w", encoding="utf-8") as dst:
                for line in src:
                    stripped = line.strip()
                    if not stripped:
                        continue
                    try:
                        rec = json.loads(stripped)
                    except json.JSONDecodeError:
                        # Malformed line — preserve it rather than
                        # silently dropping on the user's behalf.
                        dst.write(line if line.endswith("\n") else line + "\n")
                        continue
                    if rec.get("run_id") in run_ids:
                        removed_from_results += 1
                        continue
                    dst.write(json.dumps(rec) + "\n")
            os.replace(tmp_path, RESULTS_FILE)

        # Delete per-run event log files too. These can be large (full
        # transcripts + every state_text snapshot) so leaving them
        # behind after a delete is the wrong default — the history
        # table would still have a "View events" link to a phantom row.
        for rid in run_ids:
            evt_path = os.path.join(EVENTS_DIR, f"{rid}.jsonl")
            if os.path.exists(evt_path):
                try:
                    os.remove(evt_path)
                    removed_event_files += 1
                except OSError:
                    pass

        return {
            "removed_from_results": removed_from_results,
            "removed_event_files": removed_event_files,
            "skipped_active": skipped_active,
        }

    @app.route("/api/run/<run_id>", methods=["DELETE"])
    def api_delete_run(run_id):
        """Delete a single run from the leaderboard + its event log.
        Active runs are rejected with 409 so we don't yank a line the
        still-running job is about to append."""
        result = _delete_run_records({run_id})
        if result["removed_from_results"] == 0 and result["removed_event_files"] == 0:
            if run_id in result["skipped_active"]:
                return jsonify({"error": "Run is currently active", **result}), 409
            return jsonify({"error": f"Run '{run_id}' not found", **result}), 404
        return jsonify({"ok": True, **result})

    @app.route("/api/runs/delete", methods=["POST"])
    def api_bulk_delete_runs():
        """Delete multiple runs at once. Body: {"run_ids": [...]}.
        Useful for wiping out a batch of test runs without clicking
        delete on each row. Returns counts + any active-run IDs that
        were skipped for safety."""
        payload = request.get_json(force=True) or {}
        run_ids = payload.get("run_ids") or []
        if not isinstance(run_ids, list) or not run_ids:
            return jsonify({"error": "run_ids (non-empty list) required"}), 400
        result = _delete_run_records(set(str(r) for r in run_ids))
        return jsonify({"ok": True, **result})

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
