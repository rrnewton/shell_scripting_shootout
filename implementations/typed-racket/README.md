# Typed Racket candidate

The candidate is tested on Racket 7.9 and 8.18 and uses only bundled libraries.
The launcher hashes the Racket version and source modules, typechecks and
compiles changed content with `raco make`, then executes the cached bytecode.

| Racket | Runtime | Verification |
| --- | --- | --- |
| 7.9 BC | Fedora host package | `raco make`, unit tests, conformance suite |
| 8.18 CS | pinned `racket:8.18-full` image | image build, unit tests, conformance suite |

Racket 7.9 is the oldest tested release. In particular, compatibility does not
depend on importing newer Typed Racket signatures for runtime APIs.

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

Reproduce the pinned Racket 8.18 verification from the repository root:

```sh
podman build -f implementations/typed-racket/Containerfile -t pr-plan-typed-racket .
podman run --rm pr-plan-typed-racket
```
