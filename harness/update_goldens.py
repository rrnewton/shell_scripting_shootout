#!/usr/bin/env python3
"""Regenerate canonical outputs after an intentional contract change."""

from __future__ import annotations

import json
from pathlib import Path

from create_git_fixture import create_fixture
from reference_plan import build_graph, collect_git


ROOT = Path(__file__).resolve().parents[1]
FIXTURE_REPO = ROOT / ".benchmark-cache" / "fixture-repo"
EXPECTED = ROOT / "fixtures" / "expected"


def load(path: Path) -> dict[str, object]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise TypeError(f"expected a JSON object in {path}")
    return value


def write(name: str, value: object) -> None:
    EXPECTED.mkdir(parents=True, exist_ok=True)
    (EXPECTED / name).write_text(
        json.dumps(value, indent=2, ensure_ascii=True) + "\n", encoding="utf-8"
    )


def main() -> int:
    create_fixture(FIXTURE_REPO)
    pure = load(ROOT / "fixtures" / "pure-input.json")
    git_input = load(ROOT / "fixtures" / "git-input.json")
    write("pure-output.json", build_graph(pure))
    write("git-output.json", build_graph(collect_git(git_input, FIXTURE_REPO)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
