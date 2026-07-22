# TypeScript/Bun `pr-plan`

This candidate runs TypeScript directly with Bun and checks it with the pinned
TypeScript 7 native preview compiler. Zod validates the complete JSON boundary
before planning. Git commands use `Bun.spawn` with argument arrays, captured
stdout/stderr, awaited completion, and explicit expected exit-code sets; no Git
input is interpolated through a shell.

## Install and run

Bun 1.3.14 or newer is required. Install the locked dependencies once:

```console
cd implementations/typescript-bun
bun install --frozen-lockfile
./pr-plan --help
./pr-plan pure --input ../../fixtures/pure-input.json
./pr-plan pure --input ../../fixtures/pure-input.json --human
./pr-plan git --input ../../fixtures/git-input.json --git-dir /path/to/repository
```

The launcher finds Bun through `BUN_BIN`, `PATH`, or `~/.bun/bin/bun`, in that
order. It contains no benchmark logic.

## Input and output

Both modes accept only `schema_version: 1` and reject missing, extra, or
incorrectly typed properties. Common PR metadata includes `number`, `title`,
nullable `author`, `head_ref`, `base_ref`, `draft`, `mergeable`,
`review_decision`, timestamps, additions, and deletions. Pure mode also takes
`files`, `base_conflict_paths`, `conflict_edges`, and `ancestry_edges`. Git mode
instead takes `git_head` and `git_base` revisions.

Git mode accepts either a worktree root containing `.git` or a bare Git
directory. It resolves untrusted revisions to verified commit object IDs before
using them in `merge-base`, `diff`, or `merge-tree`. Revisions beginning with
`-` or containing control characters are rejected.

JSON output follows the shared canonical field order and ends with a newline.
All nodes, edges, paths, stacks, batches, holds, rebase steps, and cycles are
ordered deterministically. Human output follows the shared one-line summary.
Commit IDs are intentionally absent from both formats.

## Type safety

`tsconfig.json` enables `strict`, `noUncheckedIndexedAccess`,
`exactOptionalPropertyTypes`, `noImplicitReturns`, and the related strictness
flags. The implementation contains no `any`, non-null assertion, ignored child
status, or disabled diagnostic. Its only assertion-style conversions are the
two checked domain-brand constructors: a positive integer becomes `PrNumber`
after Zod validation, and a string becomes `GitObjectId` after a full object-ID
regular-expression check.

The local Node 16 runtime cannot launch the native preview package's
extensionless JavaScript shim in an ESM package, so `typecheck` deliberately
uses `bun --bun` for that shim. The shim then invokes the pinned native `tsgo`
binary.

## Verify

```console
bun run typecheck
bun test
cd ../..
python3 harness/conformance.py --candidate typescript-bun --require typescript-bun
```
