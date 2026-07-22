#!/usr/bin/env python3
"""Create the deterministic local Git repository used by every candidate."""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
from pathlib import Path
from typing import Mapping, Sequence


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = ROOT / ".benchmark-cache" / "fixture-repo"


def run(repo: Path, args: Sequence[str], *, env: Mapping[str, str] | None = None) -> str:
    command = ["git", "-C", str(repo), *args]
    process = subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
        env=None if env is None else {**os.environ, **env},
    )
    if process.returncode != 0:
        detail = process.stderr.strip() or process.stdout.strip()
        raise RuntimeError(f"command failed ({process.returncode}): {' '.join(command)}\n{detail}")
    return process.stdout.strip()


def write_files(repo: Path, changes: Mapping[str, str]) -> None:
    for relative, contents in changes.items():
        path = repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents, encoding="utf-8")


def commit(repo: Path, message: str, sequence: int) -> None:
    stamp = f"2026-02-{sequence:02d}T12:00:00+00:00"
    run(repo, ["add", "."])
    run(
        repo,
        ["commit", "--quiet", "-m", message],
        env={"GIT_AUTHOR_DATE": stamp, "GIT_COMMITTER_DATE": stamp},
    )


def branch(
    repo: Path,
    name: str,
    start: str,
    changes: Mapping[str, str],
    sequence: int,
) -> None:
    run(repo, ["switch", "--quiet", "--force-create", name, start])
    write_files(repo, changes)
    commit(repo, name, sequence)


def create_fixture(output: Path) -> None:
    if output.exists():
        shutil.rmtree(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["git", "init", "--quiet", "--initial-branch=main", str(output)],
        check=True,
    )
    run(output, ["config", "user.name", "Shootout Fixture"])
    run(output, ["config", "user.email", "fixture@example.invalid"])

    write_files(
        output,
        {
            "shared.txt": "base\n",
            "base-conflict.txt": "base\n",
            "overlap.txt": "one\ntwo\nthree\n",
            "README.md": "fixture\n",
        },
    )
    commit(output, "base", 1)

    branch(output, "pr-one", "main", {"shared.txt": "left\n"}, 2)
    branch(output, "pr-two", "main", {"shared.txt": "right\n"}, 3)
    branch(output, "pr-three", "pr-one", {"stacked.txt": "stacked\n"}, 4)
    branch(output, "pr-four", "main", {"docs.txt": "draft\n"}, 5)
    branch(output, "pr-five", "main", {"base-conflict.txt": "branch\n"}, 6)
    branch(output, "pr-six", "pr-two", {"followup.txt": "followup\n"}, 7)
    branch(
        output,
        "pr-seven",
        "main",
        {"overlap.txt": "ONE\ntwo\nthree\n"},
        8,
    )
    branch(
        output,
        "pr-eight",
        "main",
        {"overlap.txt": "one\ntwo\nTHREE\n"},
        9,
    )

    run(output, ["switch", "--quiet", "main"])
    write_files(output, {"base-conflict.txt": "main\n"})
    commit(output, "advance main", 10)

    for name in (
        "pr-one",
        "pr-two",
        "pr-three",
        "pr-four",
        "pr-five",
        "pr-six",
        "pr-seven",
        "pr-eight",
    ):
        run(output, ["show-ref", "--verify", f"refs/heads/{name}"])


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    create_fixture(args.output.resolve())
    print(args.output.resolve())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
