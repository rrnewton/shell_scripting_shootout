# Benchmark Design

## 1. Objective

The shootout evaluates languages as replacements for medium-to-large Python or
shell repository-management scripts. The desired solution has:

- strong static checking;
- an ergonomic process, filesystem, CLI, and JSON story;
- transparent execution from source;
- fast invocations after compilation and dependency caches are warm;
- reasonable memory use;
- a toolchain that can be installed and pinned on developer boxes and in
  containers; and
- enough ecosystem and agent familiarity to remain maintainable.

This is not primarily a language runtime benchmark. Repository scripts often
spend most of their time in `git`, `gh`, and filesystem operations, so the
suite separates runtime overhead, in-process work, and subprocess-heavy work.

## 2. Reference Workload

The proposed program is `pr-plan`, a standalone conflict graph and landing-plan
tool inspired by two existing scripts:

- DeepScry's file-overlap PR interference planner; and
- Hermit's newer PR conflict planner, which performs real pairwise
  `git merge-tree` checks.

The benchmark version should be a frozen functional subset rather than a
line-for-line port. It must exercise:

- command-line parsing;
- typed decoding and validation of GitHub-style JSON;
- subprocess execution with captured stdout and stderr;
- meaningful handling of nonzero but expected exit codes;
- filesystem and path handling;
- Git changed-file and ancestry queries;
- actual pairwise merge-conflict detection;
- sets, maps, sorting, graph traversal, and greedy planning;
- deterministic JSON output; and
- useful human-readable output and error messages.

### 2.1 Inputs

The common input is a JSON array of pull-request metadata. Required fields
include:

- PR number, title, and optional author;
- base and head ref names;
- head commit ID;
- draft and mergeability state;
- review state and timestamps; and
- additions, deletions, and changed-file count.

JSON is an untrusted boundary. Each implementation must reject malformed or
incorrectly typed fields. Type assertions such as Python `cast(...)`,
TypeScript `as Pr[]`, or an unchecked generic map do not satisfy this rule by
themselves.

### 2.2 Outputs

The canonical JSON result contains:

- normalized PR nodes;
- actual merge-conflict edges and their paths;
- file-overlap risk edges;
- explicit-stack and commit-ancestry ordering edges;
- detected stacks;
- held PRs and reasons;
- pairwise-conflict-free landing batches;
- required rebase/retarget steps; and
- detected ordering cycles.

Object keys, list ordering, whitespace, and error exit codes will be specified
so implementations can be checked against shared golden files.

### 2.3 Modes

`pr-plan` has three conceptual modes:

1. **Pure plan:** Read fully collected nodes and edges from a large fixture and
   run only validation, graph construction, planning, and rendering.
2. **Offline Git analysis:** Read PR metadata, inspect an immutable local Git
   fixture, run real Git subprocesses, and produce the plan.
3. **Live acceptance:** Query open PRs with `gh`, fetch refs, verify that API and
   fetched commit IDs agree, and then analyze them.

Only the first two modes are timed. Network latency and remote service state
would make live measurements neither reproducible nor useful.

## 3. Fixtures and Correctness

The fixture repository must include at least:

- independent clean branches;
- two branches with a content conflict;
- overlapping files without a merge conflict;
- rename/delete and add/add conflicts;
- an explicit stacked branch chain;
- ancestry produced by a rebase;
- a draft PR;
- a PR conflicting with its base;
- missing optional author data; and
- an artificial ordering cycle in the pure fixture.

Fixture construction is shared and excluded from timed runs. Prefer a
deterministic `git fast-import` stream or Git bundle so commit IDs and golden
outputs do not depend on local Git configuration or wall-clock time.

Before timing, every implementation must pass:

- golden JSON and human-output tests;
- malformed-input tests;
- subprocess failure and expected-exit-code tests;
- empty and single-PR cases;
- deterministic-output repetition;
- cache invalidation after a source edit; and
- concurrent first-run/cache-population tests.

## 4. Timed Scenarios

All scenarios launch a fresh program process. A long-lived application server
is not permitted, although a runner's default compiler daemon may be used if
its existence and memory consumption are reported.

### 4.1 Warm Startup

Run `pr-plan --help` after all compilation and dependency caches are populated.
This measures the source runner, runtime startup, imports, and CLI construction.

### 4.2 Warm Pure Planning

Validate and plan a large synthetic graph with no child processes. The fixture
should be large enough to expose runtime throughput and allocation behavior
without turning the benchmark into an unrelated numerical workload.

### 4.3 Warm Git Analysis

Analyze the local fixture using real `git merge-base`, `git diff`, and
`git merge-tree` processes. This is the most representative operational case,
though language runtime differences will be partially hidden by Git.

### 4.4 Warm After No-op Edit

Modify a harmless source literal or comment and invoke the source entry point.
This measures dependency discovery, type checking, recompilation, linking, and
cache update behavior after a typical edit.

### 4.5 Cold Artifact Cache

Clear only the candidate's compilation/artifact cache, leaving the toolchain
and locked dependencies installed and downloaded. This avoids conflating
compilation with network and package-registry performance.

### 4.6 Bootstrap

Separately measure a clean machine or container from base image to successful
first invocation. Record network transfer, installation wall time, disk delta,
root requirements, and manual steps. Bootstrap has a low score weight but is
important operational evidence.

### 4.7 Sequential and Concurrent Throughput

Measure many sequential warm invocations and a bounded group of concurrent
invocations. The latter exposes compilation-cache locking, cache corruption,
per-process memory amplification, and tools that unexpectedly serialize.

## 5. Measurement Protocol

Use a pinned benchmark host configuration and record kernel, CPU governor,
filesystem, toolchain versions, and relevant environment variables.

The intended tools are:

- `hyperfine` for distributions, warmups, repeated runs, and JSON export;
- `/usr/bin/time -v` for maximum resident set size and CPU time;
- `perf stat` where available for cycles, instructions, faults, and context
  switches; and
- ordinary disk-usage tools for toolchain and cache footprints.

Each measured command must discard or verify output consistently. Harness
shell startup must not be accidentally included for some candidates but not
others. Store raw samples, not only means. Report at least median, mean,
standard deviation, p95, minimum, and maximum.

Do not drop outliers merely because they are inconvenient. Investigate and
label scheduler noise, lazy downloads, background compilation, and cache misses.

## 6. Type-Safety Evaluation

Static strength cannot be summarized by whether a language has type syntax.
The evaluation includes strict compiler settings, boundary validation, and a
shared set of deliberate defects.

Candidate mutations include:

1. Treat an optional author as always present.
2. Decode a PR number from a JSON string instead of a number.
3. Pass a filesystem path where a commit ID is expected.
4. Use a batch index as a PR number.
5. Omit a mergeability-state case.
6. Index a possibly empty list without a check.
7. Substitute a list for a set and silently retain duplicates.
8. Forget to await asynchronous process completion.
9. Ignore a fallible result or child-process status.
10. Return a human-rendered value from a JSON-producing path.

Use idiomatic domain wrappers or newtypes when a language supports them. Record
which defects are rejected by the standard checker, which require an extra
linter, which reach runtime validation, and which survive until tests.

Also record explicit unsafe escapes: `Any`, unchecked casts, null assertions,
dynamic maps, disabled warnings, and equivalent constructs.

## 7. Ergonomics and Maintainability

Raw source-line count is evidence, not the verdict. Report separately:

- implementation lines, tests, manifests, and launcher glue;
- direct and transitive dependencies;
- boilerplate required for CLI, process execution, and JSON codecs;
- quality of compiler and runtime diagnostics;
- test startup and test-writing ergonomics;
- formatting and editor/LSP support;
- cross-platform behavior;
- dependency and compiler version pinning;
- offline reproducibility; and
- number of implementation/fix iterations needed by a coding agent working
  from the frozen specification and tests.

Shell interpolation should not be used for structured argument lists. Libraries
with a shell-like DSL are acceptable if they preserve argument boundaries and
make exit-status handling explicit.

## 8. Installation Matrix

At minimum, test pinned releases of:

- Debian or Ubuntu slim;
- Fedora; and
- Alpine Linux.

Where practical, test both x86-64 and AArch64. Record whether the documented
installation path works without root and whether it depends on `curl | sh`, a
system package, a language-specific version manager, a C compiler, a JVM, or
other host tooling.

After bootstrap, disable network access and verify that an unchanged script and
then a locally edited script can execute using locked dependencies.

## 9. Scoring

Raw results remain authoritative. A secondary weighted score provides a useful
summary without hiding tradeoffs.

| Criterion | Weight |
| --- | ---: |
| Idiomatic process/JSON code and concision | 20% |
| Type strength and boundary safety | 20% |
| Warm latency and sequential throughput | 20% |
| Installation and portability | 15% |
| Runtime, daemon, and cache memory | 10% |
| Maintainability, diagnostics, tests, and agent success | 10% |
| First invocation | 5% |

Scores should include a short rationale and link to raw evidence. Results may
also be presented as separate "developer experience" and "operational cost"
rankings if a single ordering obscures important differences.

## 10. Initial Competitors

### 10.1 Rust

Use `rust-script` with idiomatic libraries such as Clap, Serde, and either
`xshell`, `duct`, or a comparably structured process API. Measure Cargo's native
single-file `-Zscript` path as a runner variant, not as a separate language
implementation. Local Cargo 1.96 still describes `-Zscript` as nightly-only.

Expected strengths are type safety, validated decoding, native warm execution,
and low runtime memory. Expected costs are source size, compile latency, and a
large toolchain.

### 10.2 Python

Use modern Python and `mypy --strict`, with `uv` considered for interpreter,
dependency, and script management. The implementation should reflect serious
strict-Python practice rather than relying on implicit `Any` or unchecked
`TypedDict` casts.

This is the availability, ecosystem, and coding-agent baseline.

### 10.3 TypeScript with Bun

Use strict TypeScript 7 settings and its native checker, with Bun as the source
runtime. Bun's process/shell API may be used when it safely preserves argument
boundaries. Use an actual schema decoder for JSON.

Execution and type checking are separate operations, so measure both ordinary
warm run and a verified post-edit run.

### 10.4 OCaml

Use native OCaml with Bos, Fpath, Rresult, Cmdliner, and Yojson or their current
idiomatic equivalents. Dune's cached build is acceptable even if the executable
source-entry experience requires minimal launcher glue.

OCaml is expected to be competitive in native startup, memory, type strength,
and concision. Opam installation and script-runner ergonomics are open risks.

### 10.5 Typed Racket

Use `#lang typed/racket`, Racket's process and JSON libraries, and compiled
bytecode caching. Report typed/untyped boundaries and contracts explicitly.

Typed Racket provides a useful test of expressive scripting against runtime
startup and memory costs.

### 10.6 Go

Use idiomatic Go process and JSON APIs. Compare standard `go run` with a
maintained transparent executable-cache runner if `go run` continues to pay a
material linking/driver cost on every invocation.

Go should install and compile simply, but its JSON semantics, nullable values,
sum-type limitations, and verbosity must be scored rather than assumed away.

### 10.7 D

Use `rdmd`, `std.process`, and typed JSON conversion or validation. D is a core
dark-horse entry because `rdmd` directly targets cached run-from-source use.

The major unknowns are toolchain distribution, library ergonomics, ecosystem
maintenance, and coding-agent reliability.

### 10.8 Nim

Use `nim r`, `osproc`, `jsonutils`, and an idiomatic CLI library such as Cligen
if appropriate. Confirm whether the chosen runner actually reuses a final
executable or merely reuses intermediate compilation output.

Nim is included for concise syntax, static types, and fast compilation, with
ecosystem and cache correctness treated as measured questions.

### 10.9 Scala 3

Use Scala CLI's script support and source directives. This is a strong-type,
mature-script-tool control case. JVM process startup, compiler services, and
resident daemon memory must be fully counted.

## 11. Variants and Stretch Entries

- Deno is a worthwhile runtime variant for the TypeScript implementation,
  especially for its permissions and single-binary installation story.
- Node's native TypeScript stripping is another possible runner variant, but it
  must still be paired with a separate type check.
- .NET 10 C# file-based applications are a relevant stretch entry.
- F# scripts offer a more functional and concise .NET comparison.
- Nushell may be included as a structured-shell exhibition entry, but it should
  not be scored as providing the same static guarantees.

Zig, Swift, Haskell, Crystal, and V are deferred until a core entry demonstrates
that one of them would plausibly change the decision. Their current concerns
include toolchain size, slow or uncached source execution, weak scripting
libraries, verbosity, portability, or ecosystem maturity.

## 12. Relevant Prior Art

- [rust-script](https://github.com/fornwall/rust-script)
- [Cargo script RFC 3424](https://rust-lang.github.io/rfcs/3424-cargo-script.html)
- [Cargo unstable features](https://doc.rust-lang.org/cargo/reference/unstable.html)
- [Scriptisto](https://lib.rs/crates/scriptisto)
- [Bun runtime](https://bun.sh/docs/runtime)
- [Bun Shell](https://bun.sh/blog/the-bun-shell)
- [Deno TypeScript support](https://docs.deno.com/runtime/fundamentals/typescript/)
- [Node native TypeScript execution](https://nodejs.org/learn/typescript/run-natively)
- [TypeScript 7 native compiler](https://devblogs.microsoft.com/typescript/announcing-typescript-7-0/)
- [Scala CLI scripts](https://scala-cli.virtuslab.org/docs/guides/scripting/scripts/)
- [OCaml Bos](https://opam.ocaml.org/packages/bos/)
- [Typed Racket guide](http://docs.racket-lang.org/ts-guide/)
- [Racket subprocesses](http://docs.racket-lang.org/reference/subprocess.html)
- [D standard process library](https://dlang.org/library/std/process.html)
- [Nim process library](https://nim-lang.org/docs/osproc.html)
- [.NET file-based applications](https://learn.microsoft.com/en-us/dotnet/core/sdk/file-based-apps)
- [hyperfine](https://github.com/sharkdp/hyperfine)
- [Computer Language Benchmarks Game measurement notes](https://benchmarksgame-team.pages.debian.net/benchmarksgame/how-programs-are-measured.html)
- [Interpreter startup comparison](https://dev.to/serpent7776/measuring-startup-and-shutdown-overhead-of-several-code-interpreters-5hbl)

Existing comparisons mostly emphasize long-running compute kernels or empty
interpreter startup. They are useful methodological references but do not
answer the combined question of typed repository automation, transparent source
caching, installation burden, and maintainability.

## 13. Proposed Repository Layout

```text
docs/
  benchmark-design.md
fixtures/
  pr-metadata.json
  pure-graph-large.json
  repository.bundle
  expected/
implementations/
  rust/
  python/
  typescript-bun/
  ocaml/
  typed-racket/
  go/
  d/
  nim/
  scala/
harness/
results/
  raw/
  reports/
```

Generated local caches and exploratory results should remain outside tracked
fixture and published-result directories.

