# OCaml candidate

This candidate uses Cmdliner, Yojson, Bos, Fpath, Rresult, and Ptime. The
`pr-plan` source launcher builds a cached native Dune executable when source or
build metadata changes, then directly executes that artifact on warm runs.

```sh
opam install . --deps-only --with-test
dune runtest
./pr-plan pure --input ../../fixtures/pure-input.json
```

Git commands are constructed as Bos command values, run with a sanitized
environment, and have stdout, stderr, and expected nonzero statuses handled
explicitly.

