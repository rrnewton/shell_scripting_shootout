# Scala 3

This candidate runs Scala 3 source directly with Scala CLI. The source pins
Scala 3.8.4 and uPickle 4.4.3 using Scala CLI directives; the container pins
Scala CLI 1.15.0 and verifies the downloaded launcher JAR by SHA-256. The
launcher fixes dependency resolution to the Google-hosted Maven Central mirror
so image-build and offline runtime cache keys remain identical.

Prerequisites outside the container are Scala CLI 1.15.0, JDK 17 or newer,
Git, Python 3, and GNU `time`.

```sh
implementations/scala/pr-plan --help
scala-cli test --server=false implementations/scala
python3 harness/conformance.py --candidate scala --require scala
```

The decoder walks the JSON AST and validates exact object shapes, scalar
types, enums, timestamps, identifiers, paths, references, and uniqueness
before constructing the typed domain model. Git commands are argument-vector
subprocesses with a scrubbed environment, captured output, timeouts, validated
commit IDs, and explicit expected-status handling.
