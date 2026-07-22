#!/usr/bin/env python3
"""Generate a deterministic large pure-planning workload."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = ROOT / ".benchmark-cache" / "pure-large.json"


def build_fixture(count: int) -> dict[str, object]:
    if count < 2:
        raise ValueError("count must be at least 2")
    prs: list[dict[str, object]] = []
    for number in range(1, count + 1):
        head_ref = f"feature-{number:04d}"
        base_ref = f"feature-{number - 1:04d}" if number % 25 == 0 else "main"
        base_conflict = number % 53 == 0
        files = sorted(
            {
                f"src/component_{number % 80:03d}.rs",
                f"src/shared_{number % 20:03d}.rs",
                f"docs/topic_{number % 45:03d}.md",
                f"tests/group_{number % 30:03d}.rs",
            }
        )
        prs.append(
            {
                "number": number,
                "title": f"Synthetic PR {number}",
                "author": None if number % 41 == 0 else f"author-{number % 17:02d}",
                "head_ref": head_ref,
                "base_ref": base_ref,
                "draft": number % 47 == 0,
                "mergeable": "CONFLICTING" if base_conflict else "MERGEABLE",
                "review_decision": (
                    "APPROVED" if number % 3 == 0 else "REVIEW_REQUIRED"
                ),
                "created_at": f"2026-03-{(number % 28) + 1:02d}T00:00:00Z",
                "updated_at": f"2026-04-{(number % 28) + 1:02d}T00:00:00Z",
                "additions": (number * 7) % 200,
                "deletions": (number * 3) % 80,
                "files": files,
                "base_conflict_paths": [files[0]] if base_conflict else [],
            }
        )

    conflicts = [
        {
            "a": number,
            "b": number + 7,
            "paths": [f"src/conflict_{number % 23:03d}.rs"],
        }
        for number in range(3, count - 6, 3)
    ]
    ancestry = [
        {"before": number, "after": number + 1}
        for number in range(30, count, 30)
    ]
    return {
        "schema_version": 1,
        "repository": "fixture/large",
        "prs": prs,
        "conflict_edges": conflicts,
        "ancestry_edges": ancestry,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--count", type=int, default=400)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(build_fixture(args.count), indent=2) + "\n", encoding="utf-8")
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
