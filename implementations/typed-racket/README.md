# Typed Racket candidate

The candidate uses Racket 8.18 and only bundled libraries. The launcher typechecks
and compiles changed modules with `raco make`, then executes the cached bytecode.

Run the local tests in an environment containing Racket and Git:

```sh
cd implementations/typed-racket
raco make main.rkt tests.rkt
raco test tests.rkt
```

Run the shared conformance suite from the repository root:

```sh
python3 harness/conformance.py --candidate typed-racket --require typed-racket
```
