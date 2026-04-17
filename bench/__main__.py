"""BalatroBench CLI - Benchmark AI models on Balatro."""

import argparse
import sys

from .config import load_config
from .results import print_leaderboard, print_run_details
from .runner import run_benchmark


def main():
    parser = argparse.ArgumentParser(
        prog="balatrobench",
        description="Benchmark AI models by having them play Balatro",
    )
    subparsers = parser.add_subparsers(dest="command", help="Available commands")

    # --- run command ---
    run_parser = subparsers.add_parser("run", help="Run a benchmark")
    run_parser.add_argument("--model", "-m", required=True, help="Model name/ID (e.g., 'qwen/qwen-2.5-72b')")
    run_parser.add_argument("--provider", "-p", default="openrouter",
                           choices=["openrouter", "local"],
                           help="Model provider (default: openrouter)")
    run_parser.add_argument("--endpoint", "-e", default=None,
                           help="Custom API endpoint URL")
    run_parser.add_argument("--api-key", "-k", default=None,
                           help="API key (or set OPENROUTER_API_KEY env var)")
    run_parser.add_argument("--deck", "-d", default=None,
                           help="Deck name (default: from config)")
    run_parser.add_argument("--stake", "-s", type=int, default=None,
                           help="Stake level 1-8 (default: from config)")
    run_parser.add_argument("--runs", "-n", type=int, default=1,
                           help="Number of runs (default: 1)")
    run_parser.add_argument("--host", default=None,
                           help="Mod TCP host (default: 127.0.0.1)")
    run_parser.add_argument("--port", type=int, default=None,
                           help="Mod TCP port (default: 12345)")
    run_parser.add_argument("--results-file", default="results.jsonl",
                           help="Results file path (default: results.jsonl)")
    run_parser.add_argument("--quiet", "-q", action="store_true",
                           help="Suppress verbose output")
    run_parser.add_argument("--config", "-c", default="config.yaml",
                           help="Config file path (default: config.yaml)")

    # --- leaderboard command ---
    lb_parser = subparsers.add_parser("leaderboard", aliases=["lb"],
                                      help="Show leaderboard")
    lb_parser.add_argument("--results-file", default="results.jsonl",
                          help="Results file path")

    # --- results command ---
    res_parser = subparsers.add_parser("results", help="Show run details")
    res_parser.add_argument("--run-id", required=True, help="Run ID to show")
    res_parser.add_argument("--results-file", default="results.jsonl",
                          help="Results file path")

    # --- serve command ---
    serve_parser = subparsers.add_parser("serve", help="Launch the web dashboard")
    serve_parser.add_argument("--host", default="127.0.0.1",
                              help="Dashboard bind address (default: 127.0.0.1)")
    serve_parser.add_argument("--port", type=int, default=5000,
                              help="Dashboard port (default: 5000)")

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        sys.exit(1)

    if args.command == "run":
        config = load_config(args.config)
        defaults = config.get("default", {})

        results = run_benchmark(
            model_name=args.model,
            provider=args.provider,
            endpoint=args.endpoint,
            api_key=args.api_key,
            deck=args.deck or defaults.get("deck", "Red Deck"),
            stake=args.stake or defaults.get("stake", 1),
            runs=args.runs,
            host=args.host or defaults.get("mod_host", "127.0.0.1"),
            port=args.port or defaults.get("mod_port", 12345),
            results_file=args.results_file,
            verbose=not args.quiet,
        )

        if not results:
            sys.exit(1)

        # Print summary
        wins = sum(1 for r in results if r["result"]["won"])
        print(f"\nCompleted {len(results)} run(s): {wins} win(s), {len(results) - wins} loss(es)")

    elif args.command in ("leaderboard", "lb"):
        print_leaderboard(args.results_file)

    elif args.command == "results":
        print_run_details(args.run_id, args.results_file)

    elif args.command == "serve":
        from .webapp import serve
        serve(host=args.host, port=args.port)


if __name__ == "__main__":
    main()
