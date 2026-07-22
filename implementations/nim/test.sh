#!/usr/bin/env bash
set -euo pipefail

directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cache="$(mktemp -d "${TMPDIR:-/tmp}/pr-plan-nim-tests.XXXXXX")"
trap 'rm -rf -- "$cache"' EXIT

cd -- "$directory"
nim c --path:. --nimcache:"$cache" --hints:off --out:"$cache/tests" tests.nim
"$cache/tests"
