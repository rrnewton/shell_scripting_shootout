# Nim `pr-plan`

This candidate uses Nim 2.2.10 and only its standard library. The launcher
hashes the compiler version and every Nim source file, then compiles a
content-addressed executable under `.cache` on first use. Each concurrent
builder uses a private compiler cache and publishes atomically, so a caller
cannot observe a partial executable.

```sh
./pr-plan pure --input ../../fixtures/pure-input.json
./pr-plan git --input ../../fixtures/git-input.json --git-dir /path/to/repository
./test.sh
```

Both input modes use a streaming JSON parser before typed decoding. Incorrect
types, missing, unknown, and duplicate fields, invalid enums, unsafe Git
revisions, and invalid graph references are rejected before planning. Git is
invoked with argument vectors and a sanitized environment. Standard output and
error are drained independently, commands have a 30-second timeout, and only
explicit expected statuses are accepted.

The `Containerfile` pins the official Nim 2.2.10 image and installs Python 3,
Git, and GNU `time` for the shared harness. Build it from the repository root:

```sh
podman build -f implementations/nim/Containerfile -t pr-plan-nim .
podman run --rm pr-plan-nim
```
