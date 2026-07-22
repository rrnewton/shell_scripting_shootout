from __future__ import annotations

import argparse
import sys
from collections.abc import Sequence
from pathlib import Path

from pr_plan.git_analysis import GitError, analyze_repository
from pr_plan.planner import make_plan
from pr_plan.render import render_human, render_json
from pr_plan.validation import InputError, load_document


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="pr-plan",
        description="Build deterministic pull-request conflict and landing plans.",
    )
    subparsers = parser.add_subparsers(dest="mode", required=True)

    pure = subparsers.add_parser("pure", help="plan from precomputed graph data")
    pure.add_argument("--input", type=Path, required=True, metavar="FILE")
    pure.add_argument("--human", action="store_true", help="render human-readable output")

    git = subparsers.add_parser("git", help="analyze a local Git repository and plan")
    git.add_argument("--input", type=Path, required=True, metavar="FILE")
    git.add_argument("--git-dir", type=Path, required=True, metavar="DIR")
    git.add_argument("--human", action="store_true", help="render human-readable output")
    return parser


def run(argv: Sequence[str]) -> int:
    args = _parser().parse_args(argv)
    try:
        data = load_document(args.input, args.mode)
        if args.mode == "git":
            data = analyze_repository(data, args.git_dir)
        plan = make_plan(data)
        output = render_human(plan) if args.human else render_json(plan)
        sys.stdout.write(output)
        return 0
    except (InputError, GitError) as error:
        print(f"pr-plan: error: {error}", file=sys.stderr)
        return 1
    except BrokenPipeError:
        return 0


def main() -> int:
    return run(sys.argv[1:])
