# Rust `pr-plan`

The entry point is [`pr-plan.rs`](pr-plan.rs), an executable `rust-script`
source file with exact, inline dependency versions.

It requires stable Rust, Git with `merge-tree --write-tree`, and
`rust-script 0.36.0` (`cargo install rust-script --version 0.36.0 --locked`).

```sh
./pr-plan pure --input fixture.json
./pr-plan pure --input fixture.json --human
./pr-plan git --input git-fixture.json --git-dir /path/to/repository
rust-script --test pr-plan.rs
```

`--input -` reads standard input. JSON is pretty-printed with two-space
indentation and one final newline. Records, edges, paths, reasons, cycles, and
batches are sorted deterministically.

## Input schemas

Both modes require `schema_version: 1`, a nonempty `repository`, and strictly
decoded PR records. Unknown fields and incorrectly typed values are rejected.
Enums use GitHub-style uppercase strings. Both PR timestamps must be strict
RFC 3339 values with a UTC offset and a valid calendar date.

Pure mode takes collected `files` and `base_conflict_paths` on every PR, plus
top-level `conflict_edges` (`a`, `b`, `paths`) and `ancestry_edges` (`before`,
`after`). Git mode replaces the two collected path lists with `git_head` and
`git_base` revision strings. It resolves both revisions to commits, obtains
changed paths with `git diff`, uses `git merge-tree` for real base and pairwise
conflicts, and queries commit ordering with `git merge-base --is-ancestor`.

All Git commands use structured argument vectors. Exit status 1 is accepted
only where Git documents it as a normal negative/conflict result; every other
nonzero status includes captured stderr in the diagnostic.
