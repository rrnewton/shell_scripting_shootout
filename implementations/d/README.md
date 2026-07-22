# D implementation

This candidate uses DMD 2.112.0 and `rdmd`. The container verifies the pinned
compiler archive checksum. The executable launcher compiles
`pr_plan.d` from source into a candidate-local `rdmd` cache and reuses the
artifact while its source dependency hash is unchanged.

The untrusted JSON boundary is decoded explicitly from `std.json.JSONValue`
into typed structs and enums. It rejects missing, extra, incorrectly typed,
out-of-domain, duplicate, and dangling values, including malformed RFC 3339
timestamps, duplicate paths, and unsafe Git revisions. Git commands use
structured argument arrays with `std.process.spawnProcess`; stdout and stderr
are captured separately, inherited repository overrides are removed, and each
command declares its allowed statuses. Git mode validates the repository even
when the input contains no pull requests.

Run the tests from the repository root after activating DMD:

```sh
implementations/d/test.sh
```
