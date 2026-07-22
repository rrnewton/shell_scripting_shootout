# TypeScript/Deno `pr-plan`

This candidate runs strict TypeScript directly on Deno 2. It uses a complete,
dependency-free runtime decoder at the JSON boundary and Deno's native test,
type-check, subprocess, permission, and source-cache facilities.

## Install and run

Deno 2.9.3 is the pinned container version. Populate the content-addressed
source cache and verify the implementation with:

```console
cd implementations/typescript-deno
deno task cache
deno task check
./pr-plan --help
./pr-plan pure --input ../../fixtures/pure-input.json
./pr-plan pure --input ../../fixtures/pure-input.json --human
./pr-plan git --input ../../fixtures/git-input.json --git-dir /path/to/repository
```

The launcher finds Deno through `DENO_BIN`, `PATH`, or `~/.deno/bin/deno`. It
uses `--cached-only` and `--no-prompt`, grants read access explicitly, and adds
permission to execute only `git` in Git mode. It never grants full access or
network access.

## Safety and determinism

Both input modes require exactly schema version 1 and reject missing, extra, or
incorrectly typed fields. Validation also covers safe integer ranges, enums, RFC
3339 timestamps, duplicate PRs and edges, dangling references, paths, and
untrusted Git revisions.

Git commands use `Deno.Command` argument arrays with no shell. The child
environment is cleared and rebuilt with locale, configuration, prompt, and
locking safeguards. Untrusted revisions are resolved with `--end-of-options` to
verified commit object IDs before they reach other Git commands. Every Git
process has a 30-second deadline and an explicit expected-status set.

All nodes, paths, graph products, batches, holds, rebase steps, and cycles have
stable ordering. Canonical JSON field order is fixed and output ends in one
newline.

## Shared verification

```console
cd ../..
python3 harness/conformance.py --candidate typescript-deno --require typescript-deno
python3 harness/benchmark.py --candidate typescript-deno --runs 2
python3 harness/containers.py --candidate typescript-deno --benchmark-runs 2
```
