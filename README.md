# Shell Scripting Shootout

This repository compares statically typed languages for substantial repository
management scripts. The target is not a toy CPU benchmark: each implementation
must orchestrate Git and GitHub-style data, validate structured input, build a
conflict graph, and emit a deterministic landing plan.

The main question is:

> Which language gives us concise, maintainable shell scripting with strong
> type checking and fast repeated execution directly from source?

## Status

The benchmark design is being frozen before implementations begin. See
[docs/benchmark-design.md](docs/benchmark-design.md) for the proposed workload,
measurement protocol, scoring, and initial competitor roster. See
[docs/rust-runners.md](docs/rust-runners.md) for the initial Rust source-runner
decision.

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

## Initial Roster

- Rust using `rust-script` (plus a Cargo `-Zscript` runner experiment)
- Strictly typed Python using `mypy --strict`
- TypeScript 7 using Bun and its native type checker
- OCaml using Bos, Fpath, Rresult, Cmdliner, and Yojson
- Typed Racket
- Go
- D using `rdmd`
- Nim
- Scala 3 using Scala CLI as a JVM control case

Deno is planned as a TypeScript runtime variant. C# file-based applications and
F# scripts are possible stretch entries. Bash is intentionally not a
competitor; a shebang or trivial harness glue is allowed, but benchmark logic
must be written in the candidate language.

## Principles

- Correctness is established with shared fixtures and golden outputs before
  performance is measured.
- Live network access is an acceptance test, not a timed workload.
- Warm means a new process with source/dependency/artifact caches populated.
- External JSON must be validated; an unchecked cast does not create type
  safety.
- Results are published as raw measurements as well as a weighted summary.
- Compiler daemons and other persistent helpers must disclose their memory.
