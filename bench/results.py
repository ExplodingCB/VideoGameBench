"""Results tracking and leaderboard display."""

import json
import os
from collections import defaultdict


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
        """Aggregate results into a leaderboard by model."""
        results = self.load_results()
        if not results:
            return []

        # Group by model
        by_model: dict[str, list[dict]] = defaultdict(list)
        for r in results:
            by_model[r.get("model", "unknown")].append(r)

        leaderboard = []
        for model, runs in by_model.items():
            wins = sum(1 for r in runs if r.get("result", {}).get("won", False))
            total = len(runs)
            avg_ante = sum(r.get("result", {}).get("ante_reached", 0) for r in runs) / total
            avg_score = sum(r.get("result", {}).get("highest_hand_score", 0) for r in runs) / total
            avg_time = sum(r.get("timing", {}).get("total_seconds", 0) for r in runs) / total
            avg_actions = sum(r.get("result", {}).get("total_actions", 0) for r in runs) / total
            avg_invalid = sum(r.get("result", {}).get("invalid_actions", 0) for r in runs) / total
            total_tokens = sum(r.get("tokens", {}).get("total_tokens", 0) for r in runs)

            leaderboard.append({
                "model": model,
                "provider": runs[0].get("provider", ""),
                "wins": wins,
                "total_runs": total,
                "win_rate": wins / total,
                "avg_ante": round(avg_ante, 1),
                "avg_highest_score": round(avg_score),
                "avg_time_seconds": round(avg_time, 1),
                "avg_actions": round(avg_actions, 1),
                "avg_invalid_actions": round(avg_invalid, 1),
                "total_tokens": total_tokens,
            })

        # Sort by: win rate desc, then avg ante desc, then avg time asc
        leaderboard.sort(key=lambda x: (-x["win_rate"], -x["avg_ante"], x["avg_time_seconds"]))

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
