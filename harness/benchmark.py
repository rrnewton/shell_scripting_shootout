#!/usr/bin/env python3
"""Measure fresh-process warm latency and peak RSS for conforming candidates."""

from __future__ import annotations

import argparse
import json
import math
import os
import statistics
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Sequence

from conformance import FIXTURE_REPO, ROOT, candidates
from create_git_fixture import create_fixture
from create_large_fixture import DEFAULT_OUTPUT as LARGE_INPUT
from create_large_fixture import build_fixture


def percentile(sorted_values: list[float], percentile_value: float) -> float:
    if not sorted_values:
        raise ValueError("cannot compute a percentile of no values")
    rank = (len(sorted_values) - 1) * percentile_value
    lower = math.floor(rank)
    upper = math.ceil(rank)
    if lower == upper:
        return sorted_values[lower]
    fraction = rank - lower
    return sorted_values[lower] * (1.0 - fraction) + sorted_values[upper] * fraction


def invoke(command: Sequence[str]) -> float:
    started = time.perf_counter_ns()
    process = subprocess.run(command, cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=False)
    elapsed_ms = (time.perf_counter_ns() - started) / 1_000_000.0
    if process.returncode != 0:
        raise RuntimeError(
            f"command failed ({process.returncode}): {' '.join(command)}\n"
            + process.stderr.decode(errors="replace")[:2000]
        )
    return elapsed_ms


def maximum_rss(command: Sequence[str]) -> int:
    with tempfile.NamedTemporaryFile(prefix="shootout-rss-", mode="r+") as output:
        process = subprocess.run(
            ["/usr/bin/time", "-f", "%M", "-o", output.name, *command],
            cwd=ROOT,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            check=False,
        )
        if process.returncode != 0:
            raise RuntimeError(
                f"memory command failed ({process.returncode}): {' '.join(command)}\n"
                + process.stderr.decode(errors="replace")[:2000]
            )
        output.seek(0)
        return int(output.read().strip())


def measure(command: list[str], runs: int) -> dict[str, object]:
    for _ in range(3):
        invoke(command)
    samples: list[float] = []
    for _ in range(runs):
        samples.append(invoke(command))
    ordered = sorted(samples)
    mean = statistics.fmean(samples)
    return {
        "runs": runs,
        "mean_ms": mean,
        "median_ms": statistics.median(samples),
        "p95_ms": percentile(ordered, 0.95),
        "min_ms": min(samples),
        "max_ms": max(samples),
        "stddev_ms": statistics.stdev(samples) if len(samples) > 1 else 0.0,
        "invocations_per_second": 1000.0 / mean,
        "max_rss_kb": maximum_rss(command),
        "samples_ms": samples,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", action="append", default=[])
    parser.add_argument("--runs", type=int, default=30)
    parser.add_argument("--output", type=Path)
    return parser.parse_args()


def git_commit() -> str:
    supplied = os.environ.get("SHOOTOUT_GIT_COMMIT")
    if supplied:
        return supplied
    process = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    return process.stdout.strip() if process.returncode == 0 else "unavailable"


def main() -> int:
    args = parse_args()
    if args.runs < 2:
        raise ValueError("--runs must be at least 2")
    selected = set(args.candidate) if args.candidate else None
    found = candidates(selected)
    if not found:
        raise RuntimeError("no runnable candidates found")
    create_fixture(FIXTURE_REPO)
    LARGE_INPUT.parent.mkdir(parents=True, exist_ok=True)
    LARGE_INPUT.write_text(json.dumps(build_fixture(400), indent=2) + "\n", encoding="utf-8")

    result: dict[str, object] = {
        "schema_version": 1,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "git_commit": git_commit(),
        "candidates": {},
    }
    candidate_results = result["candidates"]
    assert isinstance(candidate_results, dict)
    for name, launcher in found:
        absolute = str(launcher.resolve())
        scenarios = {
            "help": [absolute, "--help"],
            "pure_small": [
                absolute,
                "pure",
                "--input",
                str(ROOT / "fixtures" / "pure-input.json"),
            ],
            "pure_large": [absolute, "pure", "--input", str(LARGE_INPUT)],
            "git": [
                absolute,
                "git",
                "--input",
                str(ROOT / "fixtures" / "git-input.json"),
                "--git-dir",
                str(FIXTURE_REPO),
            ],
        }
        candidate_results[name] = {
            scenario: measure(command, args.runs) for scenario, command in scenarios.items()
        }
        print(f"measured {name}", file=sys.stderr)

    rendered = json.dumps(result, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered, encoding="utf-8")
    else:
        print(rendered, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
