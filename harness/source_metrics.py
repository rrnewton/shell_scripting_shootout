#!/usr/bin/env python3
"""Count comparable authored source, test, launcher, and manifest lines."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CODE_SUFFIXES = {".py", ".rs", ".ts", ".go", ".ml", ".mli", ".rkt", ".d", ".nim", ".scala", ".sc"}
MANIFESTS = {
    "Cargo.toml",
    "go.mod",
    "go.sum",
    "package.json",
    "bun.lock",
    "pyproject.toml",
    "dune-project",
    "dune",
    "pr_plan.opam",
    "dub.json",
    "dub.sdl",
    "build.sbt",
    "project.scala",
}
SKIP_PARTS = {
    ".cache",
    ".git",
    ".mypy_cache",
    ".scala-build",
    ".venv",
    "_build",
    "compiled",
    "nimcache",
    "node_modules",
    "target",
}


def line_metrics(path: Path) -> dict[str, int]:
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    return {
        "files": 1,
        "lines": len(lines),
        "nonblank_lines": sum(1 for line in lines if line.strip()),
        "bytes": len(text.encode("utf-8")),
    }


def add(target: dict[str, int], value: dict[str, int]) -> None:
    for key, amount in value.items():
        target[key] = target.get(key, 0) + amount


def classify(path: Path) -> str | None:
    if any(part in SKIP_PARTS for part in path.parts):
        return None
    if path.name == "pr-plan":
        return "launcher"
    if path.name in MANIFESTS:
        return "manifest"
    if path.suffix not in CODE_SUFFIXES:
        return None
    lowered = [part.lower() for part in path.parts]
    if "test" in lowered or "tests" in lowered or "test" in path.stem.lower():
        return "tests"
    return "implementation"


def collect() -> dict[str, object]:
    result: dict[str, object] = {"schema_version": 1, "candidates": {}}
    candidates = result["candidates"]
    assert isinstance(candidates, dict)
    implementations = ROOT / "implementations"
    for directory in sorted(path for path in implementations.iterdir() if path.is_dir()):
        categories: dict[str, dict[str, int]] = {}
        for path in directory.rglob("*"):
            if not path.is_file():
                continue
            category = classify(path.relative_to(directory))
            if category is None:
                continue
            add(categories.setdefault(category, {}), line_metrics(path))
        if categories:
            candidates[directory.name] = categories
    return result


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    rendered = json.dumps(collect(), indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered, encoding="utf-8")
    else:
        print(rendered, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
