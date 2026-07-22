# D implementation

This candidate uses DMD 2.112.0 and `rdmd`. The container verifies the pinned
compiler archive checksum. The executable launcher compiles
`pr_plan.d` from source into a candidate-local `rdmd` cache and reuses the
artifact while its source dependency hash is unchanged.

The untrusted JSON boundary is decoded explicitly from `std.json.JSONValue`
into typed structs and enums. It rejects missing, extra, incorrectly typed,
out-of-domain, duplicate, and dangling values. Git commands use structured
argument arrays with `std.process.spawnProcess`; stdout and stderr are captured
separately, and each command declares its allowed statuses.

Run the tests from the repository root after activating DMD:

```sh
implementations/d/test.sh
```
