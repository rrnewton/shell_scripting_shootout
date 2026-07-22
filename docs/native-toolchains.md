# Native Toolchains on `benchmark host`

Every candidate passes the shared conformance suite directly on the CentOS
Stream 9 host. Containers are not required for ordinary use.

| Candidate | Native toolchain |
| --- | --- |
| Python | Python 3.12.13, mypy 1.18.2 |
| Bun | Bun 1.3.14 in `~/.bun` plus locked npm packages |
| Deno | Deno 2.9.3 in `~/.deno` |
| Rust | Rust 1.96.0 and `rust-script` 0.36.0 |
| Cargo script | nightly-2026-06-01 |
| Go | Go 1.26.4 |
| OCaml | opam 2.5.2, OCaml 5.3.0, Dune and pinned libraries |
| Typed Racket | system Racket 7.9 BC; the source also passes 8.18 CS |
| Nim | Nim 2.2.10 in `~/.local/opt/nim-2.2.10` |
| D | DMD/`rdmd` 2.112.0 in `~/.local/opt/dmd-2.112.0` |
| Scala | OpenJDK 17 and Scala CLI 1.15.0 |

`dnf` supplied the host compiler/build prerequisites and OpenJDK 17. CentOS's
Racket 7.9 exposed compatibility bugs that were fixed in the candidate rather
than hidden by replacing the package. Bun, Deno, Nim, DMD, Scala CLI, and the
Rust nightly were installed at the versions used by their pinned images because
CentOS repositories do not provide those releases.

The Bun and Deno login paths are in `~/.bash_profile`. Scala CLI's user-local
wrapper selects `/usr/lib/jvm/java-17-openjdk` explicitly because this host also
has an unrelated Java 8 under `/usr/local/bin`.

Verify all native launchers from the repository root:

```sh
python3 harness/conformance.py
python3 harness/host_environment.py
```

The resulting sanitized inventory is stored in
`results/raw/host-environment.json`. Tool downloads installed during the
shootout were checksum-verified where upstream publishes a stable artifact
checksum (DMD, Nim, and Scala CLI).
