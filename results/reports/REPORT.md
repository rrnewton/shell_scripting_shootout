# Shell Scripting Shootout: Final Report

Date: 2026-07-22  
Measured commit: `db68e84f9d8ec28c58f8a67fa985a1a42adfae27`

## Verdict

Use **Rust with `rust-script`** for substantial repository-management scripts.
It is the only candidate that combines the strongest domain types with 5 ms
warm startup, low native memory, stable-toolchain operation, deterministic
source caching, and robust Git/JSON behavior. The cost is verbose application
code and a large install/compile toolchain.

Use **TypeScript with Deno** when source concision and a single-binary runtime
matter more than Rust's type strength. Deno was materially better than Bun in
this workload: 22 ms versus 50 ms startup, 53 ms versus 85 ms large planning,
lower memory, no application dependencies, explicit permissions, subprocess
timeouts, and an isolated Git environment. Bun remains the most concise
process API and implementation, but Zod/npm dependencies, higher memory, no Git
timeout, and the same run-without-typecheck limitation put it second among the
TypeScript choices.

Keep **Cargo `-Zscript`** as the long-term Rust runner to watch, not today's
default. After correcting its development profile to match `rust-script`'s
optimized application code, the official runner still costs 84 ms and 32 MiB
per warm invocation and requires a pinned nightly. `rust-script` costs 5 ms and
5 MiB and works on stable Rust.

Strict Python remains an excellent availability/agent-support baseline, but it
does not change the recommendation for a team that dislikes Python. Go is
operationally dependable but was the most verbose implementation. Nim is the
performance dark horse, with ecosystem and low-level process code as the main
risks.

## Workload and Correctness

Every candidate implements the same `pr-plan` program:

- strict decoding of GitHub-shaped PR data;
- deterministic conflict graphs, stacks, holds, batches, and rebase steps;
- real `git diff`, `merge-base`, and `merge-tree` subprocesses;
- expected nonzero exit-status handling;
- normal and linked-worktree repository support; and
- canonical JSON plus human output.

The final shared suite rejects wrong scalar types, invalid enums and RFC 3339
timestamps, unknown fields, duplicate PR numbers and branch names, dangling
edges, and unsafe Git revisions. All eleven images pass candidate-specific
build checks and the shared suite with networking disabled after build. The
native launcher suite also covers Racket 7.9 compatibility; this caught and
fixed a real version-specific failure.

Live GitHub collection is deliberately shared and untimed. The
[`gh` collector](../../docs/live-github.md) strictly validates `gh pr list`,
fetches PR/base refs, verifies fetched OIDs, and writes the exact Git input used
by every candidate. Network latency and changing PR state never enter scored
timings.

## Warm Performance

Each cell is the median of 30 fresh processes after three warmups. Times are
milliseconds. RSS is the maximum MiB observed across the four scenarios. The
large pure fixture has 400 PRs; Git uses a deterministic local repository.

| Candidate | Help | Pure small | Pure large | Git | Max RSS MiB |
| --- | ---: | ---: | ---: | ---: | ---: |
| Rust / `rust-script` | **5.4** | **5.7** | 68.0 | **324.8** | **5.0** |
| Nim | 12.4 | 14.1 | **45.4** | 335.6 | 14.8 |
| TypeScript / Deno | 21.6 | 25.8 | 52.6 | 363.8 | 54.7 |
| D / `rdmd` | 26.5 | 26.9 | 174.0 | 420.6 | 14.8 |
| Go | 37.2 | 36.3 | 66.1 | 353.3 | 15.0 |
| OCaml | 39.2 | 40.0 | 96.5 | 417.3 | 22.5 |
| TypeScript / Bun | 50.2 | 56.6 | 84.8 | 395.9 | 72.0 |
| Python | 61.5 | 60.9 | 119.8 | 395.2 | 17.3 |
| Cargo `-Zscript` | 84.3 | 84.3 | 146.2 | 427.0 | 32.4 |
| Typed Racket | 521.6 | 528.9 | 752.0 | 1254.6 | 159.2 |
| Scala CLI | 7030.4 | 7128.1 | 7343.6 | 7372.8 | 485.3 |

Git subprocesses compress the differences: Rust, Nim, Go, and Deno all land
between 325 and 364 ms. Startup and pure planning expose the runtime/runner
cost. Scala CLI's 7-second floor and roughly 0.5 GiB RSS fail the central warm
source-execution requirement despite excellent Scala source quality.

Full mean, median, p95, standard deviation, min/max, RSS, and all raw samples
are in [`results/raw`](../raw).

## Rust Runner Shootout

| Runner | Toolchain | Help ms | Pure large ms | Git ms | Max RSS MiB |
| --- | --- | ---: | ---: | ---: | ---: |
| `rust-script` 0.36.0 | stable 1.96 | **5.4** | **68.0** | **324.8** | **5.0** |
| Cargo `-Zscript` | nightly-2026-06-01 | 84.3 | 146.2 | 427.0 | 32.4 |

`rust-script` is well-scoped, actively usable, and delegates dependency/build
semantics to Cargo while caching the final optimized executable. The official
Cargo design is architecturally preferable and should eventually remove an
extra third-party runner, but current stability and driver overhead make that a
future migration, not a present deployment choice. The obsolete `cargo-script`
crate should not be confused with upstream Cargo scripting.

## Source Size

Counts are authored nonblank lines. They are evidence of ergonomics, not a
quality score.

| Candidate | Implementation | Tests | Launcher | Manifest | Container |
| --- | ---: | ---: | ---: | ---: | ---: |
| Scala | **764** | 91 | 10 | 0 | 28 |
| TypeScript / Bun | 859 | 378 | 13 | 70 | 11 |
| Python | 892 | 340 | **3** | 20 | 12 |
| Nim | 1084 | 140 | 26 | 0 | 10 |
| OCaml | 1199 | 111 | 60 | 32 | 31 |
| D | 1223 | 198 | 6 | 0 | 23 |
| Rust | 1248 | 281 | 3 | 0 | 11 |
| TypeScript / Deno | 1256 | 445 | 19 | 20 | 15 |
| Typed Racket | 1320 | 121 | 55 | 0 | 17 |
| Go | 1502 | 319 | 23 | 3 | 12 |

The metrics tool attributes Rust's `#[cfg(test)]` module and D's
`version (unittest)` block to tests even though they remain co-located with the
implementation, preserving each language's idiomatic single-file scripting
layout. Cargo `-Zscript` reuses the Rust source and adds 40 nonblank lines of
runner/generator logic; it is not a separate application implementation.

## Bootstrap and Portability

The following is a no-cache verified image build from already-local,
digest-pinned base images. It includes OS packages, language dependencies,
compilation, unit tests, and conformance; it is **not** a pure first-compile
microbenchmark. Image sizes include each full toolchain and the shared test
harness.

| Candidate | Verified build s | Image MiB |
| --- | ---: | ---: |
| Nim | **11.5** | 1324.9 |
| Go | 13.7 | 931.5 |
| Python | 16.3 | **301.1** |
| Bun | 16.9 | 411.0 |
| Deno | 17.2 | 327.3 |
| Typed Racket | 20.1 | 918.0 |
| D | 29.8 | 688.6 |
| Cargo `-Zscript` | 34.5 | 1653.3 |
| Rust / `rust-script` | 48.5 | 1254.8 |
| OCaml | 49.5 | 1796.8 |
| Scala | 125.6 | 534.7 |

Python, Go, Deno, and Bun are easiest to place on ordinary machines. Rust is a
large but standard toolchain plus one maintained runner. OCaml requires opam,
Dune, and seven direct libraries. Scala requires a JDK, Scala CLI, Coursier
resolution, and a working Maven mirror. D, Nim, and Racket worked natively but
have weaker package availability/version currency across enterprise distros.

Reference native toolchain versions and portability notes are in the
[native toolchain reference](../../docs/native-toolchains.md).

## Type and Process Safety

- **Rust** has the strongest domain separation: newtypes for PRs, revisions,
  and OIDs, closed enums, Serde boundary rejection, exhaustive matches, and
  explicit fallible statuses.
- **OCaml, Scala, and Typed Racket** also provide strong nominal/variant types.
  OCaml preserves duplicate JSON keys; Scala's decoder validates before typed
  construction; Typed Racket is fully typed across modules.
- **Go and Nim** have the strictest duplicate-preserving JSON boundaries. Go's
  token decoder and subprocess timeouts are particularly robust, but its type
  system and 1502-line implementation are less expressive.
- **Deno and Bun** use maximum TypeScript strictness plus runtime schemas and
  checked brands. Execution still does not imply typechecking. Deno has the
  safer process boundary; Bun has the clearer process API.
- **Python** contains no `Any` or unchecked casts and passes `mypy --strict`,
  but `NewType` is erased and checking remains a separate development action.
- **D** improved substantially during review, but interchangeable `long` and
  `string` domains, minimal isolated tests, and no subprocess timeout make it
  the weakest static/process-safety result.

No candidate interpolates untrusted values into a shell command. The stronger
implementations also clear Git repository/config overrides, use argument
vectors, validate revisions/OIDs, distinguish expected statuses, and impose
timeouts.

## Weighted Score

The score uses the weights fixed before implementation. Values are 0–100; raw
measurements remain authoritative. Subjective 0–10 inputs are published in
[`scorecard.json`](../raw/scorecard.json).

| Rank | Candidate | Score |
| ---: | --- | ---: |
| 1 | Rust / `rust-script` | **81.2** |
| 2 | Python | 79.2 |
| 3 | TypeScript / Deno | 76.8 |
| 4 | TypeScript / Bun | 76.0 |
| 5 | Go | 74.8 |
| 6 | Nim | 74.2 |
| 7 | OCaml | 68.0 |
| 8 | D | 62.5 |
| 9 | Typed Racket | 54.2 |
| 10 | Scala | 51.5 |

Python's high aggregate is driven by installation ubiquity, maintainability,
and agent familiarity, not type strength or performance leadership. For the
stated preference against Python, Deno is the practical concise alternative;
Rust remains the overall technical winner.

## Candidate Notes

- **Rust:** best total operational result and strongest types; verbose source,
  long cold compile, and Cargo dependency resolution remain costs.
- **Deno:** best runtime balance; dependency-free and permissioned, but manual
  boundary validation grew to 1256 lines and TypeScript checking is separate.
- **Bun:** best concision/process ergonomics; Zod/lockfile are good, but memory,
  timeout handling, and startup trail Deno.
- **Go:** dependable standard-library process behavior, atomic content cache,
  and easy install; verbose validation/planning code and weaker sum types.
- **Nim:** excellent native measurements and cache design; the safe subprocess
  implementation required POSIX polling/raw buffers, reducing portability.
- **Python:** disciplined, dependency-free runtime baseline; separate static
  checking and erased domain wrappers limit guarantees.
- **OCaml:** strong types and respectable native timing; opam/Dune complexity,
  dependency footprint, and 1199 implementation lines undercut the expected
  scripting advantage.
- **D:** real `rdmd` source workflow and low memory; weakest domain model and
  process safety, with mediocre large-fixture throughput.
- **Typed Racket:** expressive types and bundled libraries, now compatible from
  Racket 7.9 through 8.18; startup and memory are not competitive.
- **Scala:** smallest, strongly typed implementation and good diagnostics;
  Scala CLI/JVM fresh-process cost disqualifies it for frequently invoked
  source scripts under this protocol.

## Limits

The common harness does not yet produce comparable timed values for a no-op
source edit, a cleared artifact cache, concurrent throughput, cache-corruption
recovery, AArch64, or every candidate on every distro. Implementations contain
focused cache invalidation/concurrent-launch tests, but this report does not
claim a measured cache-reliability ranking. No agent-success score is inferred
from commit history because prompts/iterations are not normalized evidence.

All raw samples are retained and no outliers were removed. Infrastructure
identifiers are intentionally omitted from the published artifacts. Container
images use different userlands, so the results represent each documented
deployment environment rather than a libc-only laboratory comparison.

## Reproduce

```sh
# Correctness, directly on the host
python3 harness/conformance.py

# Clean digest-pinned builds and offline conformance
python3 harness/containers.py --no-cache

# Final fresh-process measurements, reusing verified images
python3 harness/containers.py --benchmark-only --benchmark-runs 30

# Authenticated, untimed live GitHub input
python3 harness/collect_github.py \
  --repo OWNER/REPOSITORY --git-dir /path/to/worktree \
  --output /tmp/pr-plan-live.json
```

See [benchmark design](../../docs/benchmark-design.md),
[research notes](../../docs/research.md), and
[container workflow](../../containers.md) for details.
