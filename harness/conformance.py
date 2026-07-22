#!/usr/bin/env python3
"""Run every available candidate against the shared behavioral contract."""

from __future__ import annotations

import argparse
import copy
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


def check_candidate(
    name: str,
    launcher: Path,
    invalid_cases: list[tuple[str, str, Path]],
    fixture_repo: Path,
) -> bool:
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

    for label, mode, invalid_path in invalid_cases:
        invalid_args = [str(launcher), mode, "--input", str(invalid_path)]
        if mode == "git":
            invalid_args.extend(["--git-dir", str(fixture_repo)])
        invalid = run(invalid_args)
        if invalid.returncode == 0:
            print(f"FAIL {name} invalid/{label}: accepted invalid input", file=sys.stderr)
            ok = False
        else:
            print(f"PASS {name} invalid/{label}")
    return ok


def write_invalid_cases(directory: Path) -> list[tuple[str, str, Path]]:
    pure = load_json(ROOT / "fixtures" / "pure-input.json")
    git_input = load_json(ROOT / "fixtures" / "git-input.json")
    assert isinstance(pure, dict) and isinstance(git_input, dict)
    cases: list[tuple[str, str, object]] = []

    wrong_root = {"schema_version": 1, "repository": 7, "prs": []}
    cases.append(("wrong-root-type", "pure", wrong_root))

    wrong_number = copy.deepcopy(pure)
    wrong_number["prs"][0]["number"] = "1"  # type: ignore[index]
    cases.append(("wrong-pr-number", "pure", wrong_number))

    invalid_enum = copy.deepcopy(pure)
    invalid_enum["prs"][0]["mergeable"] = "MAYBE"  # type: ignore[index]
    cases.append(("invalid-enum", "pure", invalid_enum))

    unknown_field = copy.deepcopy(pure)
    unknown_field["prs"][0]["surprise"] = True  # type: ignore[index]
    cases.append(("unknown-field", "pure", unknown_field))

    duplicate_pr = copy.deepcopy(pure)
    duplicate_pr["prs"].append(copy.deepcopy(duplicate_pr["prs"][0]))  # type: ignore[union-attr,index]
    cases.append(("duplicate-pr", "pure", duplicate_pr))

    dangling_edge = copy.deepcopy(pure)
    dangling_edge["conflict_edges"][0]["b"] = 9999  # type: ignore[index]
    cases.append(("dangling-edge", "pure", dangling_edge))

    unsafe_revision = copy.deepcopy(git_input)
    unsafe_revision["prs"][0]["git_head"] = "--help"  # type: ignore[index]
    cases.append(("unsafe-git-revision", "git", unsafe_revision))

    written: list[tuple[str, str, Path]] = []
    for label, mode, value in cases:
        path = directory / f"{label}.json"
        path.write_text(json.dumps(value), encoding="utf-8")
        written.append((label, mode, path))
    return written


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
        invalid_cases = write_invalid_cases(temporary_path)
        results = [
            check_candidate(name, launcher.resolve(), invalid_cases, fixture_repo)
            for name, launcher in found
        ]
    return 0 if all(results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
