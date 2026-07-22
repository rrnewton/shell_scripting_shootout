# Shared Fixtures

`pure-input.json` contains already analyzed PRs plus actual conflict and
ancestry edges. It measures validation, graph planning, and rendering without
child processes.

`git-input.json` identifies local Git refs. Generate the repository with:

```sh
python3 harness/create_git_fixture.py
```

The command prints the generated repository path, normally
`.benchmark-cache/fixture-repo`. Candidate Git modes must derive changed files,
base conflicts, pair conflicts, and ancestry edges from that repository.

Fixture commits use fixed identities and timestamps. Canonical candidate output
omits commit IDs, so results remain stable if a future Git version changes an
object-format detail.
