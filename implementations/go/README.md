# Go `pr-plan`

This candidate uses Go 1.26.4 and only the standard library. The launcher hashes
the compiler version, Go sources, and module files, then builds a content-keyed
executable under `.cache` on the first invocation. Atomic publication remains
safe when several cold invocations race to build the same source.

```sh
./pr-plan pure --input ../../fixtures/pure-input.json
./pr-plan git --input ../../fixtures/git-input.json --git-dir /path/to/repository
go test ./...
```

Both input modes use strict token-level JSON decoding. Incorrect types, missing,
unknown, and duplicate fields, invalid enum values, unsafe Git revisions, and
invalid graph references are rejected before planning. Git is invoked with
structured argument vectors, a sanitized environment, a 30-second timeout, and
explicit accepted exit statuses.

The `Containerfile` pins the Go toolchain image to 1.26.4 on Debian Bookworm and
installs Python 3, Git, and GNU `time` for the shared harness. Build it from the
repository root so the harness and fixtures are included:

```sh
podman build -f implementations/go/Containerfile -t pr-plan-go .
podman run --rm pr-plan-go
```

The image runs Go conformance while building and defaults to the same check for
CI. Override the command with `python3 harness/benchmark.py --candidate go` to
collect benchmark results.
