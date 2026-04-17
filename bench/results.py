"""Results tracking and leaderboard display."""

import json
import math
import os
from collections import defaultdict


# ---------------------------------------------------------------------------
# BalatroBench Rating (0-100).
# ---------------------------------------------------------------------------
# A composite score per run. Weighted: round progress dominates, token
# efficiency is closely behind, best-hand-score is a small bonus. The three
# components each normalize to [0, 1] and are summed with the weights below.
#
# Tuning rationale:
#   - Round: Balatro has 8 antes × 3 blinds = 24 rounds. `rounds_won / 24`
#     is a clean linear proxy: "how much of the run did you actually clear?"
#   - Tokens: diminishing-returns curve with halving point at 100k. A 10k run
#     scores ~0.91, 100k scores 0.50, 1M scores 0.09. This preserves
#     meaningful spread between 50k-500k runs (where most benchmarks live)
#     without making "1M vs 10M" a tiny rounding artifact.
#   - Chips: log10-scaled because Balatro scores scale exponentially with
#     ante. Linear would let one good ante-7 hand dominate. Log keeps it
#     a genuine bonus rather than a kingmaker.
#
# All three are capped at [0, 1] so a missing field (0 or None) never produces
# a negative contribution.
WEIGHT_ROUND = 55
WEIGHT_TOKENS = 30
WEIGHT_CHIPS = 15

TOKEN_HALVING_POINT = 100_000  # tokens at which the T factor equals 0.5
CHIP_LOG_CAP = 7  # log10(chips+1) / CHIP_LOG_CAP; 7 ≈ log10(10M)
MAX_ROUNDS = 24  # 8 antes × (Small + Big + Boss)


def score_run(record: dict) -> dict:
    """Compute the BalatroBench rating for a single run record.

    Args:
        record: A run record as produced by BenchmarkRunner (the same shape
                that's appended to results.jsonl).

    Returns:
        A dict with:
          - rating: 0-100 composite score (float, rounded to 1 decimal)
          - components: the three raw [0,1] factors that went into it
          - raw: the integer inputs (rounds, tokens, chips) so callers can
            show them in tooltips without re-parsing the record
    """
    result = record.get("result") or {}
    tokens_blk = record.get("tokens") or {}

    rounds = int(result.get("rounds_won") or 0)
    # total_tokens may be absent on older records where the tracker only
    # stored prompt/completion separately — sum them if needed.
    total_tokens = int(
        tokens_blk.get("total_tokens")
        or (tokens_blk.get("prompt_tokens", 0) + tokens_blk.get("completion_tokens", 0))
    )
    highest_chips = int(result.get("highest_hand_score") or 0)

    # Normalized factors, each clamped to [0, 1].
    r = max(0.0, min(1.0, rounds / MAX_ROUNDS))
    # Guard against zero-token records (impossible in practice but safer).
    t = 1.0 / (1.0 + max(0, total_tokens) / TOKEN_HALVING_POINT)
    t = max(0.0, min(1.0, t))
    c = math.log10(1 + max(0, highest_chips)) / CHIP_LOG_CAP
    c = max(0.0, min(1.0, c))

    # ACHIEVEMENT GATE: "efficiency" is meaningless without accomplishing
    # anything. A model that got rate-limited before ever making a call
    # has total_tokens=0, which would naively score t=1.0 → 30 free points.
    # A model that made one 5k-token call then died scores t=0.95 → 28.5
    # points. Both outcomes are complete failures and should rate 0.
    #
    # Gate: no round progress → token and chip factors don't contribute.
    # One round cleared → full token/chip factors eligible. The round
    # factor itself (R) always contributes because it genuinely encodes
    # progress; its natural value at rounds=0 is already 0 anyway.
    if rounds == 0:
        t = 0.0
        c = 0.0

    # MISSING-USAGE GATE: providers that omit `usage` metadata (some
    # local OpenAI-compatible endpoints, some streaming-only setups)
    # leave total_tokens at 0 even for runs that actually consumed
    # tokens. Without this gate the run would earn full token
    # efficiency credit (t=1.0) which is obviously wrong — we have no
    # evidence of efficiency. Force t=0 so the run scores only on
    # round progress and best-hand chips, which are observable from
    # game state.
    if total_tokens == 0:
        t = 0.0

    # INFRA-FAILURE GATE: runs that died because the provider's API
    # was unreachable shouldn't be scored at all — the model never got
    # a fair chance to play. Return rating=0 with an explicit flag so
    # leaderboards can filter them out rather than averaging in zeros.
    # (result.infra_failed is written by the runner when the retry
    # loop exhausts on HTTP errors without ever getting a successful
    # response.)
    if result.get("infra_failed"):
        return {
            "rating": 0.0,
            "components": {"round_factor": 0.0, "token_factor": 0.0, "chip_factor": 0.0},
            "raw": {
                "rounds_won": rounds,
                "total_tokens": total_tokens,
                "highest_hand_score": highest_chips,
            },
            "weights": {
                "round": WEIGHT_ROUND,
                "tokens": WEIGHT_TOKENS,
                "chips": WEIGHT_CHIPS,
            },
            "infra_failed": True,
            "infra_error": result.get("infra_error"),
        }

    rating = WEIGHT_ROUND * r + WEIGHT_TOKENS * t + WEIGHT_CHIPS * c

    return {
        "rating": round(rating, 1),
        "components": {
            "round_factor": round(r, 3),
            "token_factor": round(t, 3),
            "chip_factor": round(c, 3),
        },
        "raw": {
            "rounds_won": rounds,
            "total_tokens": total_tokens,
            "highest_hand_score": highest_chips,
        },
        "weights": {
            "round": WEIGHT_ROUND,
            "tokens": WEIGHT_TOKENS,
            "chips": WEIGHT_CHIPS,
        },
    }


class ResultsTracker:
    """Tracks benchmark results in a JSONL file."""

    def __init__(self, filepath: str = "results.jsonl"):
        self.filepath = filepath

    def add_result(self, record: dict):
        """Append a result record to the JSONL file."""
        with open(self.filepath, "a", encoding="utf-8") as f:
            f.write(json.dumps(record) + "\n")

    def load_results(self) -> list[dict]:
        """Load all results from the JSONL file."""
        if not os.path.exists(self.filepath):
            return []
        results = []
        with open(self.filepath, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        results.append(json.loads(line))
                    except json.JSONDecodeError:
                        continue
        return results

    def get_leaderboard(self) -> list[dict]:
        """Aggregate results into a leaderboard by model.

        Each entry now includes a `rating` (avg of per-run BalatroBench
        scores), `rating_best` (best single-run rating), and `ratings`
        (the raw per-run rating list for error-bar rendering). Runs are
        sorted by avg rating descending — this is the benchmark's headline
        ranking now.
        """
        results = self.load_results()
        if not results:
            return []

        # Group by model
        by_model: dict[str, list[dict]] = defaultdict(list)
        for r in results:
            by_model[r.get("model", "unknown")].append(r)

        leaderboard = []
        for model, all_runs in by_model.items():
            # Infra-failed runs (provider API unreachable, auth failed,
            # rate-limited into oblivion) are segregated from benchmark-
            # meaningful runs: they have no bearing on the model's
            # capability. Report the count so users know how many
            # attempts were lost to infrastructure, but exclude them
            # from every aggregate (average, best rating, win count,
            # ante, etc.).
            infra_runs = [r for r in all_runs if r.get("result", {}).get("infra_failed")]
            runs = [r for r in all_runs if not r.get("result", {}).get("infra_failed")]
            total_all = len(all_runs)
            total = len(runs)

            if total == 0:
                # Every run on this model died to infrastructure. Emit
                # a placeholder row so the user can still see that
                # attempts were made, but with rating 0 and clear marker.
                leaderboard.append({
                    "model": model,
                    "provider": all_runs[0].get("provider", ""),
                    "rating": 0.0, "rating_best": 0.0, "ratings": [],
                    "wins": 0, "total_runs": 0,
                    "infra_failed_runs": len(infra_runs),
                    "win_rate": 0.0,
                    "avg_ante": 0.0,
                    "avg_highest_score": 0,
                    "avg_time_seconds": 0.0,
                    "avg_actions": 0.0,
                    "avg_invalid_actions": 0.0,
                    "total_tokens": 0,
                })
                continue

            wins = sum(1 for r in runs if r.get("result", {}).get("won", False))
            avg_ante = sum(r.get("result", {}).get("ante_reached", 0) for r in runs) / total
            avg_score = sum(r.get("result", {}).get("highest_hand_score", 0) for r in runs) / total
            avg_time = sum(r.get("timing", {}).get("total_seconds", 0) for r in runs) / total
            avg_actions = sum(r.get("result", {}).get("total_actions", 0) for r in runs) / total
            avg_invalid = sum(r.get("result", {}).get("invalid_actions", 0) for r in runs) / total
            total_tokens = sum(r.get("tokens", {}).get("total_tokens", 0) for r in runs)

            per_run_ratings = [score_run(r)["rating"] for r in runs]
            avg_rating = sum(per_run_ratings) / len(per_run_ratings)
            best_rating = max(per_run_ratings)

            leaderboard.append({
                "model": model,
                "provider": runs[0].get("provider", ""),
                "rating": round(avg_rating, 1),
                "rating_best": round(best_rating, 1),
                "ratings": per_run_ratings,
                "wins": wins,
                "total_runs": total,
                # Counted separately so UI can show "5 runs (2 infra-failed)".
                "infra_failed_runs": len(infra_runs),
                "win_rate": wins / total,
                "avg_ante": round(avg_ante, 1),
                "avg_highest_score": round(avg_score),
                "avg_time_seconds": round(avg_time, 1),
                "avg_actions": round(avg_actions, 1),
                "avg_invalid_actions": round(avg_invalid, 1),
                "total_tokens": total_tokens,
            })

        # Headline sort: average rating descending, then best rating desc as
        # a tiebreaker so a 1-run model with a lucky 80 doesn't beat a 5-run
        # model with consistent 78s. Still fall through to avg_ante and
        # avg_time for very close ties.
        leaderboard.sort(key=lambda x: (-x["rating"], -x["rating_best"],
                                        -x["avg_ante"], x["avg_time_seconds"]))

        return leaderboard


def print_leaderboard(results_file: str = "results.jsonl"):
    """Print a formatted leaderboard table."""
    tracker = ResultsTracker(results_file)
    board = tracker.get_leaderboard()

    if not board:
        print("No results found. Run some benchmarks first!")
        return

    # Header
    print()
    print(f"{'Model':<30} {'Wins':>7} {'Avg Ante':>10} {'Avg Score':>12} "
          f"{'Avg Time':>10} {'Errors':>8} {'Runs':>6}")
    print("-" * 90)

    for entry in board:
        wins_str = f"{entry['wins']}/{entry['total_runs']}"
        print(
            f"{entry['model']:<30} "
            f"{wins_str:>7} "
            f"{entry['avg_ante']:>10.1f} "
            f"{entry['avg_highest_score']:>12,} "
            f"{entry['avg_time_seconds']:>9.1f}s "
            f"{entry['avg_invalid_actions']:>8.1f} "
            f"{entry['total_runs']:>6}"
        )

    print()


def print_run_details(run_id: str, results_file: str = "results.jsonl"):
    """Print detailed info for a specific run."""
    tracker = ResultsTracker(results_file)
    results = tracker.load_results()

    for r in results:
        if r.get("run_id") == run_id:
            print(json.dumps(r, indent=2))
            return

    print(f"Run '{run_id}' not found.")
