# Shell Scripting Shootout

This repository compares statically typed languages for substantial repository
management scripts. The target is not a toy CPU benchmark: each implementation
must orchestrate Git and GitHub-style data, validate structured input, build a
conflict graph, and emit a deterministic landing plan.

The main question is:

> Which language gives us concise, maintainable shell scripting with strong
> type checking and fast repeated execution directly from source?

## Status

The shootout is complete. The [final report](results/reports/REPORT.md) contains
the measurements, qualitative review, weighted score, limitations, and
recommendation. Machine-readable samples and supporting evidence are in
[`results/raw`](results/raw).

**Verdict:** Rust with `rust-script` is the overall winner. TypeScript with
Deno is the best concise non-Rust option. Cargo's official `-Zscript` is the
preferred long-term architecture but is still nightly-only and adds about
80 ms/32 MiB per warm invocation in the tested release.

See [docs/benchmark-design.md](docs/benchmark-design.md) for the frozen workload,
[docs/rust-runners.md](docs/rust-runners.md) for the Rust runner analysis, and
[docs/research.md](docs/research.md) for prior art and additional candidates.

Candidate toolchains are reproducible through the Podman/Docker workflow in
[containers.md](containers.md).

## Priorities

In approximate order, the shootout evaluates:

1. Idiomatic and concise process-oriented scripting.
2. Strength of static checks and safety at JSON/process boundaries.
3. Warm invocation latency and throughput.
4. Toolchain installation across ordinary hosts and clean containers.
5. Runtime memory, background daemons, and compilation-cache footprint.
6. Maintainability, diagnostics, testing, and success by coding agents.
7. First-invocation cost, with less weight than steady-state use.

Implementations may use normal, idiomatic libraries. Dependency count,
installation cost, lockfile quality, and offline reproducibility are measured
rather than artificially requiring standard-library-only solutions.

## Completed Roster

- Rust using `rust-script` (plus a Cargo `-Zscript` runner experiment)
- Strictly typed Python using `mypy --strict`
- TypeScript using Bun and Deno
- OCaml using Bos, Fpath, Rresult, Cmdliner, and Yojson
- Typed Racket
- Go
- D using `rdmd`
- Nim
- Scala 3 using Scala CLI as a JVM control case

C# file-based applications and F# scripts remain useful future entries. Bash is
intentionally not a competitor; a shebang or trivial launcher is allowed, but
benchmark logic is written in the candidate language.

## Run

All native toolchains are installed on the benchmark host:

```sh
python3 harness/conformance.py
```

Rebuild and verify the digest-pinned images, then repeat the measurements:

```sh
standard-proxy-env python3 harness/containers.py --no-cache
python3 harness/containers.py --benchmark-only --benchmark-runs 30
```

Live GitHub collection through `gh` is shared and untimed; see
[docs/live-github.md](docs/live-github.md).

## Principles

- Correctness is established with shared fixtures and golden outputs before
  performance is measured.
- Live network access is an acceptance test, not a timed workload.
- Warm means a new process with source/dependency/artifact caches populated.
- External JSON must be validated; an unchecked cast does not create type
  safety.
- Results are published as raw measurements as well as a weighted summary.
- Compiler daemons and other persistent helpers must disclose their memory.
