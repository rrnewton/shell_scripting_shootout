#!/usr/bin/env python3
"""Count comparable authored source, test, launcher, and manifest lines."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CODE_SUFFIXES = {
    ".d",
    ".go",
    ".ml",
    ".mli",
    ".nim",
    ".py",
    ".rkt",
    ".rs",
    ".sc",
    ".scala",
    ".sh",
    ".ts",
}
MANIFESTS = {
    "Cargo.toml",
    "deno.json",
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
    "requirements-dev.txt",
    "tsconfig.json",
}
SKIP_PARTS = {
    ".cache",
    ".git",
    ".mypy_cache",
    ".rdmd-cache",
    ".scala-build",
    ".venv",
    "_build",
    "compiled",
    "nimcache",
    "node_modules",
    "target",
}


def text_metrics(text: str) -> dict[str, int]:
    lines = text.splitlines()
    return {
        "files": 1,
        "lines": len(lines),
        "nonblank_lines": sum(1 for line in lines if line.strip()),
        "bytes": len(text.encode("utf-8")),
    }


def embedded_source_regions(
    candidate: str, path: Path, text: str
) -> list[tuple[str, str]] | None:
    """Split language-native test blocks without changing their source layout."""
    lines = text.splitlines(keepends=True)
    if candidate == "rust" and path.name == "pr-plan.rs":
        marker = next(
            (index for index, line in enumerate(lines) if line.strip() == "#[cfg(test)]"),
            None,
        )
        if marker is not None:
            return [
                ("implementation", "".join(lines[:marker])),
                ("tests", "".join(lines[marker:])),
            ]

    if candidate == "d" and path.name == "pr_plan.d":
        marker = next(
            (
                index
                for index, line in enumerate(lines)
                if line.strip() == "version (unittest)"
            ),
            None,
        )
        if marker is not None:
            continuation = next(
                (
                    index
                    for index in range(marker + 1, len(lines))
                    if lines[index].strip() == "else"
                ),
                None,
            )
            if continuation is not None:
                return [
                    (
                        "implementation",
                        "".join(lines[:marker] + lines[continuation:]),
                    ),
                    ("tests", "".join(lines[marker:continuation])),
                ]

    return None


def add(target: dict[str, int], value: dict[str, int]) -> None:
    for key, amount in value.items():
        target[key] = target.get(key, 0) + amount


def classify(candidate: str, path: Path) -> str | None:
    if any(part in SKIP_PARTS for part in path.parts):
        return None
    if path.name == "Containerfile":
        return "container"
    if candidate == "rust-cargo-script" and path.name == "pr-plan":
        return "implementation"
    if path.name == "pr-plan":
        return "launcher"
    if path.name == "scala-cli-container":
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
            category = classify(directory.name, path.relative_to(directory))
            if category is None:
                continue
            text = path.read_text(encoding="utf-8")
            regions = embedded_source_regions(directory.name, path, text)
            if category == "implementation" and regions is not None:
                for region_category, region_text in regions:
                    add(
                        categories.setdefault(region_category, {}),
                        text_metrics(region_text),
                    )
            else:
                add(categories.setdefault(category, {}), text_metrics(text))
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
