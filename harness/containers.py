#!/usr/bin/env python3
"""Build and run candidate conformance images with Podman or Docker."""

from __future__ import annotations

import argparse
import contextlib
import os
import shutil
import subprocess
import sys
from pathlib import Path

from proxy_bridge import bridged_proxy


ROOT = Path(__file__).resolve().parents[1]


def engine_default() -> str:
    for name in ("podman", "docker"):
        if shutil.which(name):
            return name
    raise RuntimeError("neither podman nor docker is installed")


def run(command: list[str]) -> None:
    print("+ " + " ".join(command), flush=True)
    subprocess.run(command, cwd=ROOT, check=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", default=None)
    parser.add_argument("--candidate", action="append", default=[])
    parser.add_argument("--no-cache", action="store_true")
    parser.add_argument(
        "--benchmark-runs",
        type=int,
        help="after conformance, benchmark inside each image and save raw JSON",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    engine = args.engine or engine_default()
    selected = set(args.candidate) if args.candidate else None
    implementations = ROOT / "implementations"
    found: list[tuple[str, Path]] = []
    for directory in sorted(path for path in implementations.iterdir() if path.is_dir()):
        containerfile = directory / "Containerfile"
        if containerfile.exists() and (selected is None or directory.name in selected):
            found.append((directory.name, containerfile))
    if not found:
        raise RuntimeError("no matching Containerfiles found")
    git_commit = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()

    proxy = os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy")
    bridge_context = bridged_proxy(proxy) if engine == "podman" else contextlib.nullcontext(proxy)
    with bridge_context as build_proxy:
        for name, containerfile in found:
            tag = f"shell-scripting-shootout-{name}:local"
            build = [
                engine,
                "build",
                "--network",
                "host",
                "--tag",
                tag,
                "--file",
                str(containerfile),
            ]
            if build_proxy:
                for variable in ("HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"):
                    build.extend(["--build-arg", f"{variable}={build_proxy}"])
            if args.no_cache:
                build.append("--no-cache")
            build.append(str(ROOT))
            run(build)
            run([engine, "run", "--rm", tag])
            if args.benchmark_runs:
                command = [
                    engine,
                    "run",
                    "--rm",
                    "--env",
                    f"SHOOTOUT_GIT_COMMIT={git_commit}",
                    tag,
                    "python3",
                    "harness/benchmark.py",
                    "--candidate",
                    name,
                    "--runs",
                    str(args.benchmark_runs),
                ]
                print("+ " + " ".join(command), flush=True)
                process = subprocess.run(
                    command, cwd=ROOT, capture_output=True, text=True, check=False
                )
                if process.returncode != 0:
                    sys.stderr.write(process.stderr)
                    raise subprocess.CalledProcessError(process.returncode, command)
                sys.stderr.write(process.stderr)
                result = ROOT / "results" / "raw" / f"container-{name}.json"
                result.parent.mkdir(parents=True, exist_ok=True)
                result.write_text(process.stdout, encoding="utf-8")
                print(f"wrote {result}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
