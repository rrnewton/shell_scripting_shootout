# Native Toolchain Reference

Containers are not required for ordinary use. The versions below are the
reference versions used for the published comparison; they are not claimed as
minimum supported versions.

| Candidate | Native toolchain |
| --- | --- |
| Python | Python 3.12.13, mypy 1.18.2 |
| Bun | Bun 1.3.14 plus locked npm packages |
| Deno | Deno 2.9.3 |
| Rust | Rust 1.96.0 and `rust-script` 0.36.0 |
| Cargo script | nightly-2026-06-01 |
| Go | Go 1.26.4 |
| OCaml | opam 2.5.2, OCaml 5.3.0, Dune and pinned libraries |
| Typed Racket | system Racket 7.9 BC; the source also passes 8.18 CS |
| Nim | Nim 2.2.10 |
| D | DMD/`rdmd` 2.112.0 |
| Scala | OpenJDK 17 and Scala CLI 1.15.0 |

Racket 7.9 exposed compatibility bugs that were fixed in the candidate rather
than hidden by requiring a newer release. The container definitions provide the
authoritative, digest-pinned installation recipes for each candidate.

Verify all native launchers from the repository root:

```sh
python3 harness/conformance.py
```

Tool downloads in the container definitions are checksum-verified where
upstream publishes a stable artifact checksum (DMD, Nim, and Scala CLI).
The same reference versions are retained as structured data in
[`toolchain-versions.json`](../results/raw/toolchain-versions.json).
