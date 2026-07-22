# Rust Source Runner Evaluation

## Decision

Use [`rust-script`](https://github.com/fornwall/rust-script) as the primary Rust
runner for the first implementation.

Also measure Cargo's upstream `-Zscript` support as an experimental runner using
the same program where practical. Revisit the primary choice when Cargo script
support is stable.

## Ranking

### 1. `rust-script`: best usable default

`rust-script` is purpose-built for executable Rust source files and supports:

- a direct shebang;
- inline Cargo dependency metadata;
- compilation with a stable Rust toolchain;
- reuse of compiled artifacts on unchanged warm invocations; and
- familiar Cargo dependency resolution underneath.

It is narrowly scoped, has current releases, and avoids requiring a nightly
compiler across every machine that executes a repository script. Those traits
make it the best balance of maintenance, design, efficiency, and operational
reliability available now.

Risks to test rather than assume away:

- invalidation when the compiler, dependency metadata, environment, or local
  path dependencies change;
- behavior when several processes compile the same script concurrently;
- cache corruption recovery;
- offline execution from a fully populated dependency cache;
- signal and exit-status forwarding; and
- cache discovery and cleanup.

### 2. Cargo `-Zscript`: preferred long-term design, not yet the default

[RFC 3424](https://rust-lang.github.io/rfcs/3424-cargo-script.html) integrates
single-file packages directly into Cargo. This is architecturally preferable:
dependency semantics, compiler selection, caching, diagnostics, configuration,
and future maintenance belong to the official tool rather than a parallel
runner.

The blocker is stability. Local Cargo 1.96 reports:

```text
-Z script  Enable support for single-file, `.rs` packages
```

under "Available unstable (nightly-only) flags." A nightly-only source entry
point is a material installation and reliability cost for management scripts
intended to run across varied hosts and containers. It remains important to
benchmark because it is the likely eventual winner.

### 3. Scriptisto: useful general experiment

[Scriptisto](https://lib.rs/crates/scriptisto) provides language-agnostic
compiled-script caching and is relevant prior art. Its generic templates can
also give Rust, Go, OCaml, or other compiled languages a common shebang model.

For the Rust production entry it adds configuration and another abstraction
layer without improving Rust/Cargo integration. Its visible release line is
still alpha, and maintenance signals are weaker than `rust-script`. Keep it as
a cross-language runner experiment, not the primary Rust result.

### 4. `cargo-script`: do not use

The older `cargo-script` crate predates upstream Cargo script support and its
published release line is old. It should not be confused with Cargo's RFC 3424
implementation. There is no reason to start a new benchmark implementation on
it.

## Robustness Control

For context, also measure a conventional checked-in Cargo binary invoked with
`cargo run --release --quiet --manifest-path ...`. It is not as script-like and
does not satisfy the direct shebang goal, but it establishes how much overhead
and reliability the specialized source runners add relative to ordinary Cargo.

The production recommendation should be revisited after the cache-invalidation,
concurrency, and offline tests are implemented. Maintenance activity alone does
not prove that a compile cache is correct.
