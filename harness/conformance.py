#!/usr/bin/env python3
"""Run every available candidate against the shared behavioral contract."""

from __future__ import annotations

import argparse
import difflib
import json
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Sequence

from create_git_fixture import create_fixture


ROOT = Path(__file__).resolve().parents[1]
IMPLEMENTATIONS = ROOT / "implementations"
FIXTURE_REPO = ROOT / ".benchmark-cache" / "fixture-repo"


def candidates(selected: set[str] | None) -> list[tuple[str, Path]]:
    found: list[tuple[str, Path]] = []
    if not IMPLEMENTATIONS.exists():
        return found
    for directory in sorted(path for path in IMPLEMENTATIONS.iterdir() if path.is_dir()):
        launcher = directory / "pr-plan"
        if launcher.is_file() and (selected is None or directory.name in selected):
            found.append((directory.name, launcher))
    return found


def run(args: Sequence[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, cwd=ROOT, capture_output=True, text=True, check=False)


def load_json(path: Path) -> object:
    return json.loads(path.read_text(encoding="utf-8"))


def compare_json(name: str, scenario: str, actual_text: str, expected: object) -> bool:
    try:
        actual = json.loads(actual_text)
    except json.JSONDecodeError as error:
        print(f"FAIL {name} {scenario}: output is not JSON: {error}", file=sys.stderr)
        print(actual_text[:1000], file=sys.stderr)
        return False
    if actual == expected:
        print(f"PASS {name} {scenario}")
        return True
    expected_text = json.dumps(expected, indent=2, sort_keys=True).splitlines()
    actual_normalized = json.dumps(actual, indent=2, sort_keys=True).splitlines()
    difference = "\n".join(
        difflib.unified_diff(expected_text, actual_normalized, "expected", "actual", lineterm="")
    )
    print(f"FAIL {name} {scenario}: output mismatch\n{difference[:12000]}", file=sys.stderr)
    return False


def require_success(name: str, scenario: str, process: subprocess.CompletedProcess[str]) -> bool:
    if process.returncode == 0:
        return True
    detail = process.stderr.strip() or process.stdout.strip()
    print(
        f"FAIL {name} {scenario}: exit {process.returncode}\n{detail[:4000]}",
        file=sys.stderr,
    )
    return False


def check_candidate(name: str, launcher: Path, malformed: Path, fixture_repo: Path) -> bool:
    expected_pure = load_json(ROOT / "fixtures" / "expected" / "pure-output.json")
    expected_git = load_json(ROOT / "fixtures" / "expected" / "git-output.json")
    ok = True

    pure_args = [str(launcher), "pure", "--input", str(ROOT / "fixtures" / "pure-input.json")]
    pure = run(pure_args)
    if require_success(name, "pure", pure):
        ok = compare_json(name, "pure", pure.stdout, expected_pure) and ok
    else:
        ok = False

    git_args = [
        str(launcher),
        "git",
        "--input",
        str(ROOT / "fixtures" / "git-input.json"),
        "--git-dir",
        str(fixture_repo),
    ]
    git_process = run(git_args)
    if require_success(name, "git", git_process):
        ok = compare_json(name, "git", git_process.stdout, expected_git) and ok
    else:
        ok = False

    human = run([*pure_args, "--human"])
    if human.returncode != 0 or not human.stdout.strip():
        print(f"FAIL {name} human: expected successful nonempty output", file=sys.stderr)
        ok = False
    else:
        print(f"PASS {name} human")

    invalid = run([str(launcher), "pure", "--input", str(malformed)])
    if invalid.returncode == 0:
        print(f"FAIL {name} malformed: accepted invalid input", file=sys.stderr)
        ok = False
    else:
        print(f"PASS {name} malformed")
    return ok


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--candidate",
        action="append",
        default=[],
        help="implementation directory name; repeat to select several",
    )
    parser.add_argument(
        "--require",
        action="append",
        default=[],
        help="fail if this implementation is not present",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    selected = set(args.candidate) if args.candidate else None
    found = candidates(selected)
    names = {name for name, _ in found}
    missing = sorted(set(args.require) - names)
    if missing:
        print("missing required candidates: " + ", ".join(missing), file=sys.stderr)
        return 2
    if not found:
        print("no runnable candidates found", file=sys.stderr)
        return 2

    with tempfile.TemporaryDirectory(prefix="shootout-invalid-") as temporary:
        temporary_path = Path(temporary)
        fixture_repo = temporary_path / "fixture-repo"
        create_fixture(fixture_repo)
        malformed = temporary_path / "invalid.json"
        malformed.write_text('{"schema_version":1,"repository":7,"prs":[]}', encoding="utf-8")
        results = [
            check_candidate(name, launcher.resolve(), malformed, fixture_repo)
            for name, launcher in found
        ]
    return 0 if all(results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
