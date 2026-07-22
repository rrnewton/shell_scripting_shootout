# Python `pr-plan`

This is the Python baseline for the shell scripting shootout. It uses only the
standard library at runtime and is checked with `mypy --strict`. All JSON is
decoded from `object` values by an explicit runtime validator; no `Any`, cast,
or unchecked `TypedDict` is used in the implementation.

## Run

From this directory:

```console
./pr-plan pure --input fixture.json
python3 -m pr_plan pure --input fixture.json
python3 -m pr_plan pure --input fixture.json --human
python3 -m pr_plan git --input metadata.json --git-dir /path/to/repository
```

Installing the project exposes the same CLI as `pr-plan`:

```console
python3 -m pip install -e .
pr-plan --help
```

## Input schema

Both modes require `schema_version: 1`, a nonempty `repository` string, and a
`prs` array. Every PR has these exact fields:

```json
{
  "number": 1,
  "title": "Example",
  "author": "octocat",
  "head_ref": "feature/example",
  "base_ref": "main",
  "draft": false,
  "mergeable": "MERGEABLE",
  "review_decision": "APPROVED",
  "created_at": "2025-01-01T00:00:00Z",
  "updated_at": "2025-01-02T00:00:00Z",
  "additions": 10,
  "deletions": 2
}
```

`author` may be `null`. `review_decision` is `APPROVED`, `CHANGES_REQUESTED`,
`REVIEW_REQUIRED`, or `NONE`. `mergeable` is
`MERGEABLE`, `CONFLICTING`, or `UNKNOWN`.

Pure mode adds `files: string[]` and `base_conflict_paths: string[]` to each PR.
Its root also has:

```json
{
  "conflict_edges": [{"a": 1, "b": 2, "paths": ["src/app.py"]}],
  "ancestry_edges": [{"before": 1, "after": 2}]
}
```

Git mode instead adds `git_head` and `git_base` revision strings to each PR.
It resolves both to commits and derives files, base conflicts, pair conflicts,
and ancestry with `git merge-base`, `git diff`, and `git merge-tree`. Revisions
starting with `-` or containing control characters are rejected. Git is never
invoked through a shell.

`base_ref` matching another PR's `head_ref` creates a `base-ref` ordering edge.
Review state is reported but does not hold a PR. Holds use the frozen reasons
`draft`, `local-base-conflict`, `github-base-conflicting`, and
`depends-on-held:#<number>`.

Output JSON is pretty-printed with sorted object keys, a trailing newline, and
all graph collections sorted by PR number and path. Resolved commit IDs are
intentionally omitted so golden output is stable across equivalent fixtures.

## Verify

```console
python3 -m unittest discover -s tests -v
python3 -m mypy --strict pr_plan tests
```
