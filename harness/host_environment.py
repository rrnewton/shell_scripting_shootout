#!/usr/bin/env python3
"""Record a sanitized benchmark-host and native-toolchain inventory."""

from __future__ import annotations

import json
import os
import platform
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HOME = Path.home()


def executable(name: str, fallback: Path | None = None) -> str:
    found = shutil.which(name)
    if found is not None:
        return found
    if fallback is not None and fallback.is_file():
        return str(fallback)
    return name


def output(command: list[str]) -> str:
    process = subprocess.run(
        command,
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
        timeout=30,
    )
    rendered = (process.stdout + process.stderr).strip()
    first_lines = rendered.splitlines()[:3]
    return "\n".join(first_lines) if process.returncode == 0 else f"unavailable: {rendered}"


def os_release() -> dict[str, str]:
    result: dict[str, str] = {}
    for line in Path("/etc/os-release").read_text(encoding="utf-8").splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        result[key] = value.strip('"')
    return result


def cpu_model() -> str:
    for line in Path("/proc/cpuinfo").read_text(encoding="utf-8").splitlines():
        if line.startswith("model name"):
            return line.split(":", 1)[1].strip()
    return "unavailable"


def main() -> int:
    java17 = Path("/usr/lib/jvm/java-17-openjdk/bin/java")
    commands = {
        "bun": [executable("bun", HOME / ".bun/bin/bun"), "--version"],
        "deno": [executable("deno", HOME / ".deno/bin/deno"), "--version"],
        "dmd": [executable("dmd", HOME / ".local/bin/dmd"), "--version"],
        "git": [executable("git"), "--version"],
        "gh": [executable("gh"), "--version"],
        "go": [executable("go"), "version"],
        "java": [str(java17 if java17.is_file() else executable("java")), "-version"],
        "mypy": [executable("mypy", HOME / ".local/bin/mypy"), "--version"],
        "nim": [executable("nim", HOME / ".local/bin/nim"), "--version"],
        "ocaml": [executable("opam"), "exec", "--", "ocamlc", "-version"],
        "opam": [executable("opam"), "--version"],
        "python": [executable("python3"), "--version"],
        "racket": [executable("racket"), "--version"],
        "rust": [executable("rustc"), "--version"],
        "rust-nightly": [executable("rustc"), "+nightly-2026-06-01", "--version"],
        "rust-script": [executable("rust-script"), "--version"],
        "scala-cli": [executable("scala-cli", HOME / ".local/bin/scala-cli"), "version"],
    }
    result = {
        "schema_version": 1,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "git_commit": output(["git", "rev-parse", "HEAD"]),
        "host": {
            "os_release": os_release(),
            "kernel": platform.release(),
            "machine": platform.machine(),
            "cpu_count": os.cpu_count(),
            "cpu_model": cpu_model(),
            "podman": output(["podman", "--version"]),
        },
        "toolchains": {name: output(command) for name, command in commands.items()},
    }
    destination = ROOT / "results/raw/host-environment.json"
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(destination)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
