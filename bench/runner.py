"""Run orchestration - the main benchmark game loop."""

import json
import os
import re
import time
import uuid

from .client import BalatroBenchClient
from .models import ModelAdapter
from .prompt import SYSTEM_PROMPT, build_messages, parse_action, summarize_state
from .results import ResultsTracker


# Where per-action event logs are written. Each run gets its own JSONL file
# at run_events/<run_id>.jsonl — the web dashboard tails these to draw graphs.
EVENTS_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "run_events")


def _parse_score(state_text):
    """Extract (current_score, target_score, ante, round_label, hands_left, money) from state text.
    Returns None-filled dict when a field isn't present (e.g. blind select / shop phases)."""
    def _int(pattern, text, group=1):
        m = re.search(pattern, text)
        if not m:
            return None
        raw = m.group(group).replace(",", "")
        try:
            return int(raw)
        except ValueError:
            return None

    return {
        "current_score": _int(r"Current Score:\s*(-?[\d,]+)", state_text),
        "target_score": _int(r"Target Score:\s*([\d,]+)", state_text),
        "ante": _int(r"Ante:\s*(\d+)/8", state_text),
        "round_label": (re.search(r"Round:\s*([^\n|]+)", state_text).group(1).strip()
                        if re.search(r"Round:\s*([^\n|]+)", state_text) else None),
        "hands_left": _int(r"Hands Remaining:\s*(\d+)", state_text),
        "discards_left": _int(r"Discards Remaining:\s*(\d+)", state_text),
        "money": _int(r"Money:\s*\$(-?\d+)", state_text),
        "phase": (re.search(r"Phase:\s*([^\n]+)", state_text).group(1).strip()
                  if re.search(r"Phase:\s*([^\n]+)", state_text) else None),
        "rounds_won": _int(r"Rounds Won:\s*(\d+)", state_text),
        "highest_hand": _int(r"Highest Single Hand Score:\s*([\d,]+)", state_text),
    }


class _ActionBlockStripper:
    """Feeds streaming chunks through; once `{"action"` appears, swallows the rest.

    We buffer the trailing 10 chars between emits so we don't leak a half-started
    `{"acti` prefix before the full pattern confirms it's the action block.
    """

    _RE = re.compile(r'\{\s*"action"')

    def __init__(self):
        self.buf = ""
        self.emitted = 0
        self.cut = None

    def feed(self, chunk: str) -> str:
        if self.cut is not None:
            self.buf += chunk
            return ""
        self.buf += chunk
        m = self._RE.search(self.buf, max(0, self.emitted - 2))
        if m:
            self.cut = m.start()
            end = self.cut
        else:
            end = max(self.emitted, len(self.buf) - 10)
        out = self.buf[self.emitted:end]
        self.emitted = end
        return out

    def flush(self) -> str:
        """Emit any 10-char holdback we haven't released yet.
        Call on stream end when no action block was detected."""
        if self.cut is not None:
            return ""
        out = self.buf[self.emitted:]
        self.emitted = len(self.buf)
        return out


class EventLogger:
    """Appends JSON lines to run_events/<run_id>.jsonl so the webapp can
    stream live per-action data back to the browser. Safe if EVENTS_DIR is
    missing — it creates it on first write."""

    def __init__(self, run_id):
        self.run_id = run_id
        os.makedirs(EVENTS_DIR, exist_ok=True)
        self.path = os.path.join(EVENTS_DIR, f"{run_id}.jsonl")

    def emit(self, event_type, **fields):
        record = {"ts": time.time(), "type": event_type, **fields}
        try:
            with open(self.path, "a", encoding="utf-8") as f:
                f.write(json.dumps(record) + "\n")
                f.flush()
        except OSError:
            pass  # dashboard is best-effort; never break the run


class BenchmarkRunner:
    def __init__(self, client, model, results, max_history=10, max_retries=3,
                 verbose=True, event_logger=None):
        self.client = client
        self.model = model
        self.results = results
        self.max_history = max_history
        self.max_retries = max_retries
        self.verbose = verbose
        self.event_logger = event_logger

    def _jimbo_send(self, msg: dict):
        """Fire-and-forget overlay message. Swallow send errors so a broken
        overlay connection never kills the benchmark."""
        try:
            self.client.send_json(msg)
        except Exception:  # noqa: BLE001 — overlay is cosmetic, keep running
            pass

    def _chat_with_jimbo(self, messages, action_index, attempt, use_jimbo):
        """Drive chat_stream and forward visible tokens to the overlay mod.

        Returns (response_text, usage) matching ModelAdapter.chat()'s shape.
        Falls back to non-streaming chat() on any failure, in which case the
        overlay still gets the full text as one synthetic token.
        """
        # Cache the display name once: strip the provider prefix (everything
        # up to and including the first '/') and swap '-' for ' '.
        # e.g. "x-ai/grok-4.1-fast" -> "grok 4.1 fast"
        if not hasattr(self, "_jimbo_model_name"):
            raw = (self.model.model or "")
            self._jimbo_model_name = raw.split("/", 1)[-1].replace("-", " ")

        self._jimbo_send({
            "type": "jimbo_thinking_start",
            "action_index": action_index,
            "attempt": attempt,
            "model_name": self._jimbo_model_name,
        })

        stripper = _ActionBlockStripper()
        response_text = ""
        usage: dict = {}
        stream_err = None

        try:
            stream = self.model.chat_stream(messages)
        except AttributeError:
            stream = None

        if stream is not None:
            try:
                for kind, payload in stream:
                    if kind == "delta":
                        visible = stripper.feed(payload)
                        if visible:
                            self._jimbo_send({
                                "type": "jimbo_token",
                                "text": visible,
                                "action_index": action_index,
                            })
                    elif kind == "done":
                        response_text = payload.get("text", "")
                        usage = payload.get("usage") or {}
                        tail = stripper.flush()
                        if tail:
                            self._jimbo_send({
                                "type": "jimbo_token",
                                "text": tail,
                                "action_index": action_index,
                            })
                        break
                    elif kind == "error":
                        stream_err = payload.get("error", "stream error")
                        break
            except Exception as e:  # noqa: BLE001
                stream_err = f"Stream iteration failed: {e}"

        if not response_text and stream_err is None and stream is None:
            stream_err = "chat_stream unavailable"

        self._jimbo_send({"type": "jimbo_thinking_end", "action_index": action_index})

        if stream_err is not None:
            # Fall back to non-streaming; still feed the bubble so something shows
            response_text, usage = self.model.chat(messages)
            if response_text and "error" not in usage:
                visible = _ActionBlockStripper().feed(response_text)
                if visible:
                    self._jimbo_send({
                        "type": "jimbo_token",
                        "text": visible,
                        "action_index": action_index,
                    })

        return response_text, usage

    def _drain(self):
        """Drain all buffered data from socket."""
        try:
            self.client.sock.settimeout(2)
            while True:
                d = self.client.sock.recv(8192)
                if not d:
                    break
        except Exception:
            pass
        self.client.buffer = ""

    def _poll_state(self, max_attempts=15, delay=1.5) -> str | None:
        """Poll mod for a valid game state with ACTIONS section."""
        for attempt in range(max_attempts):
            self.client.send_json({"method": "gamestate"})
            time.sleep(delay)

            buf = ""
            self.client.sock.settimeout(5)
            while True:
                try:
                    chunk = self.client.sock.recv(8192).decode()
                    if not chunk:
                        break
                    buf += chunk
                    if "===END===" in buf:
                        break
                except Exception:
                    break

            # Check for run_complete JSON
            for line in buf.split("\n"):
                line = line.strip()
                if line.startswith("{"):
                    try:
                        msg = json.loads(line)
                        if msg.get("type") == "run_complete":
                            return json.dumps(msg)
                    except json.JSONDecodeError:
                        pass

            # Check for valid text state
            if "BALATRO BENCH" in buf and "ACTIONS" in buf:
                parts = buf.split("===END===")
                for p in reversed(parts):
                    if "BALATRO BENCH" in p and "ACTIONS" in p:
                        return p.strip()

            if self.verbose and attempt > 2:
                print(f"  [Polling] attempt {attempt + 1}/{max_attempts}...")

        return None

    def _send_action_and_wait(self, action: dict, wait=8):
        """Send action, drain result, wait for game to process."""
        self.client.send_json(action)
        time.sleep(wait)
        self._drain()

    def run(self, deck="Red Deck", stake=1, seed=None, run_id=None,
            on_run_start=None, should_stop=None) -> dict:
        # Allow callers (the webapp) to specify the run_id up front so they
        # can register it in their job state BEFORE the run actually starts,
        # which lets the UI open a live SSE stream immediately.
        #
        # should_stop is an optional zero-arg callable the runner polls at
        # safe points in its loop. Returning truthy aborts the current run
        # immediately; the webapp's Stop button wires this to a flag.
        run_id = run_id or f"run_{time.strftime('%Y%m%d_%H%M%S')}_{uuid.uuid4().hex[:6]}"
        start_time = time.time()
        should_stop = should_stop or (lambda: False)

        # Auto-create an event logger if none was supplied so `python -m bench run`
        # still produces a per-run JSONL the dashboard can show historically.
        logger = self.event_logger or EventLogger(run_id)

        # Give callers a chance to react to a run starting (e.g. append run_id
        # to a shared job list visible to the webapp's status endpoint).
        if on_run_start:
            try:
                on_run_start(run_id)
            except Exception:  # noqa: BLE001 — callback failures shouldn't kill the run
                pass
        logger.emit("run_started",
                    run_id=run_id,
                    model=self.model.model,
                    provider=self.model.provider,
                    deck=deck,
                    stake=stake)

        if self.verbose:
            print(f"\n{'='*60}")
            print(f"BalatroBench Run: {run_id}")
            print(f"Model: {self.model.model} | Deck: {deck} | Stake: {stake}")
            print(f"{'='*60}\n")

        # Start a fresh run
        self.client.send_json({"method": "start", "deck": deck, "stake": stake, "seed": seed})
        time.sleep(5)
        self._drain()

        # Game loop
        history = []
        action_count = 0
        invalid_count = 0
        run_result = None
        # Track the FURTHEST point the model reached. The mod only sends a
        # proper run_complete on clean game-over; on aborts, hangs, pack
        # races, or when the runner gives up polling, run_result stays None
        # and the final record shows Ante 0 / 0 rounds. That's misleading
        # when the model actually played 30 actions and cleared Ante 1.
        # These counters are populated from every live `state` event and
        # used as a fallback when building the final record.
        max_ante_reached = 0
        max_round_label = None
        rounds_won_seen = 0  # highest rounds_won stat observed in state

        aborted = False
        while True:
            if should_stop():
                aborted = True
                break
            # Poll for game state
            state_text = self._poll_state()

            if not state_text:
                print("[BalatroBench] Could not get game state, ending run")
                break

            # Check for run_complete
            if state_text.startswith("{"):
                try:
                    msg = json.loads(state_text)
                    if msg.get("type") == "run_complete":
                        run_result = msg.get("result", {})
                        break
                except json.JSONDecodeError:
                    pass

            if self.verbose:
                lines = state_text.split("\n")
                for line in lines[:6]:
                    if line.strip():
                        print(f"  {line.strip()}")
                print(f"  ... ({len(lines)} lines total)")

            # Emit a state snapshot for the dashboard (score/phase/ante/money)
            state_summary = _parse_score(state_text)
            logger.emit("state", action_index=action_count, **state_summary)

            # Track high-water marks. Ante and rounds_won only ever go up
            # during a run; round_label just records whatever the current
            # blind is called (stale ones are overwritten).
            if state_summary.get("ante"):
                max_ante_reached = max(max_ante_reached, state_summary["ante"])
            if state_summary.get("rounds_won") is not None:
                rounds_won_seen = max(rounds_won_seen, state_summary["rounds_won"])
            if state_summary.get("round_label"):
                max_round_label = state_summary["round_label"]
            # Also emit the FULL formatted state the model will see. Useful
            # for debugging "why did it sell that joker?" — the evaluator
            # can see exactly what the model had on its screen.
            logger.emit("state_text",
                        action_index=action_count,
                        text=state_text)

            # Game over check. We deliberately do NOT send {"action":"quit"}
            # here: quit sets the mod's active flag to false, which blocks
            # subsequent runs in a batch. The next run's start_new_run call
            # re-activates the mod on its own.
            if "Phase: Game Over" in state_text or "Phase: GAME_OVER" in state_text:
                if self.verbose:
                    print("  GAME OVER")
                self._drain()
                break

            # Auto-handle single-option screens that exist only to acknowledge
            # a transition. The "Round Complete - Cash Out" screen has only
            # one legal action (cash_out), so forcing the model to spend a
            # full API turn + 5k+ tokens to press the only button available
            # wastes time and budget. We just send cash_out directly.
            if "Phase: Round Complete" in state_text:
                auto_action = {"action": "cash_out"}
                action_count += 1
                logger.emit("action",
                            action_index=action_count,
                            action=auto_action,
                            auto=True,
                            note="Auto-cash-out: round complete screen has only one legal action.")
                if self.verbose:
                    print("  [auto] cash_out")
                self._send_action_and_wait(auto_action)
                continue

            # Ask the model what to do
            messages = build_messages(SYSTEM_PROMPT, state_text, history[-self.max_history:])

            action = None
            retries = 0
            while action is None and retries <= self.max_retries:
                if should_stop():
                    aborted = True
                    break
                if self.verbose:
                    print(f"  [Model] Thinking... ", end="", flush=True)

                # Let the dashboard know we're waiting on the model so the UI
                # can show a spinner / "thinking..." marker.
                logger.emit("model_thinking",
                            action_index=action_count,
                            attempt=retries + 1,
                            max_attempts=self.max_retries + 1)

                use_jimbo = os.environ.get("BALATROBENCH_JIMBO") == "1"
                response_text, usage = self._chat_with_jimbo(
                    messages, action_count, retries + 1, use_jimbo
                ) if use_jimbo else self.model.chat(messages)

                if "error" in usage:
                    print(f"\n  [!] API error: {usage['error']}")
                    logger.emit("model_error",
                                action_index=action_count,
                                attempt=retries + 1,
                                error=str(usage.get("error", "unknown error")))
                    retries += 1
                    time.sleep(2)
                    continue

                action = parse_action(response_text)

                # Emit the model's raw output for the dashboard. We include
                # the full response text (reasoning + final JSON) so the user
                # can see exactly what the model said and how we parsed it.
                # finish_reason tells us if the provider truncated ("length")
                # vs. the model terminated naturally ("stop").
                logger.emit("model_response",
                            action_index=action_count,
                            attempt=retries + 1,
                            response=response_text or "",
                            parsed_action=action,
                            parse_ok=action is not None,
                            prompt_tokens=usage.get("prompt_tokens", 0),
                            completion_tokens=usage.get("completion_tokens", 0),
                            elapsed_seconds=usage.get("elapsed_seconds"),
                            finish_reason=usage.get("finish_reason"))

                if action is None:
                    invalid_count += 1
                    retries += 1
                    if self.verbose:
                        print(f"\n  [!] Parse failed ({retries}/{self.max_retries}): {(response_text or '')[:100]}")
                    messages.append({"role": "assistant", "content": response_text})
                    messages.append({"role": "user", "content": 'Respond with ONLY a JSON action like {"action": "play", "cards": [1, 3]}'})
                else:
                    if self.verbose:
                        print(f"-> {json.dumps(action)}")

            if aborted:
                break

            if action is None:
                action = {"action": "skip"}
                invalid_count += 1

            action_count += 1

            # Log the chosen action (with current score context) for the graph
            logger.emit("action",
                        action_index=action_count,
                        action=action,
                        score_before=state_summary.get("current_score"),
                        target=state_summary.get("target_score"),
                        ante=state_summary.get("ante"),
                        round=state_summary.get("round_label"),
                        hands_left=state_summary.get("hands_left"))

            if action.get("action") in ("quit", "new_run"):
                self.client.send_json(action)
                break

            history.append({"state": summarize_state(state_text, action), "action": action})

            # Send action to mod and wait for game to process
            self._send_action_and_wait(action)

            if os.environ.get("BALATROBENCH_JIMBO") == "1":
                self._jimbo_send({"type": "jimbo_dispatched", "action_index": action_count})

        # Build result
        elapsed = time.time() - start_time
        model_usage = self.model.get_total_usage()

        # Build result, preferring the mod's run_complete payload (authoritative
        # when the game cleanly ended) but falling back to the high-water marks
        # we tracked from live state events. This way "run that aborted at
        # Ante 3 Big Blind after 42 actions" shows ante=3 instead of ante=0.
        def _rr(key, default):
            if run_result and run_result.get(key) is not None:
                return run_result.get(key)
            return default

        record = {
            "model": self.model.model,
            "provider": self.model.provider,
            "run_id": run_id,
            "seed": _rr("seed", ""),
            "config": {"deck": deck, "stake": stake},
            "result": {
                "won": _rr("won", False),
                "ante_reached": _rr("ante_reached", max_ante_reached),
                "rounds_won": _rr("rounds_won", rounds_won_seen),
                "furthest_blind": max_round_label,
                "highest_hand_score": _rr("highest_hand", 0),
                "final_dollars": _rr("final_dollars", 0),
                "total_actions": action_count,
                "invalid_actions": invalid_count,
                "aborted": aborted,  # true when user hit Stop mid-run
            },
            "timing": {
                "total_seconds": round(elapsed, 1),
                "avg_decision_seconds": round(elapsed / max(action_count, 1), 2),
            },
            "tokens": model_usage,
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }

        self.results.add_result(record)

        logger.emit("run_finished", record=record)

        if self.verbose:
            print(f"\n{'='*60}")
            print("Run Complete!")
            print(f"  Result: {'WIN' if record['result']['won'] else 'LOSS'}")
            print(f"  Ante: {record['result']['ante_reached']}/8")
            print(f"  Actions: {action_count} ({invalid_count} invalid)")
            print(f"  Time: {record['timing']['total_seconds']}s")
            print(f"{'='*60}\n")

        return record


def run_benchmark(model_name, provider="openrouter", endpoint=None, api_key=None,
                  deck="Red Deck", stake=1, runs=1, host="127.0.0.1", port=12345,
                  results_file="results.jsonl", verbose=True):
    adapter = ModelAdapter(model=model_name, provider=provider, endpoint=endpoint, api_key=api_key)
    tracker = ResultsTracker(results_file)
    all_results = []

    with BalatroBenchClient(host=host, port=port) as client:
        if not client.connect():
            print("Failed to connect. Is Balatro running with the BalatroBench mod?")
            return []

        runner = BenchmarkRunner(client=client, model=adapter, results=tracker, verbose=verbose)

        for i in range(runs):
            if runs > 1:
                print(f"\n--- Run {i + 1}/{runs} ---")
            all_results.append(runner.run(deck=deck, stake=stake))

    return all_results
