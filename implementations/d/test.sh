#!/usr/bin/env bash
set -euo pipefail

directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd -- "$directory/../.." && pwd)"

rdmd --tmpdir="$directory/.rdmd-cache" -w -preview=dip1000 \
    -unittest --main "$directory/pr_plan.d"
python3 "$root/harness/conformance.py" --candidate d --require d
