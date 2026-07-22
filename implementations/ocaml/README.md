# OCaml candidate

This candidate uses Cmdliner, Yojson, Bos, Fpath, Rresult, and Ptime. The
`pr-plan` source launcher fingerprints the compiler, Dune, source, and build
metadata, then builds a cached native executable when that fingerprint changes.
Warm runs directly execute the validated artifact.

```sh
opam install . --deps-only --with-test
dune runtest
./pr-plan pure --input ../../fixtures/pure-input.json
```

Git commands are constructed as Bos command values, run with a sanitized
environment, and have stdout, stderr, and expected nonzero statuses handled
explicitly.
