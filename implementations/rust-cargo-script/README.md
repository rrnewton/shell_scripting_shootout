# Upstream Cargo script runner

This is a runner variant for the exact Rust implementation in
`../rust/pr-plan.rs`. It converts the `rust-script` inline manifest into Cargo's
current `---cargo` frontmatter and stores the generated source by content hash.

Cargo 1.96 still gates single-file packages behind nightly `-Zscript`, so the
launcher pins `nightly-2026-06-01`. Warm invocations measure Cargo's official
single-file package cache and driver overhead without duplicating application
logic.

```sh
./pr-plan pure --input ../../fixtures/pure-input.json
```
