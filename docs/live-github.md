# Live GitHub Collection

Live GitHub access is a shared, untimed acceptance step. The candidates do not
call `gh` themselves: `harness/collect_github.py` queries the open PRs once,
strictly validates the response, fetches the base and pull-request refs, and
checks every fetched head commit against GitHub's `headRefOid`. This prevents
network variability from affecting the language measurements and gives every
candidate identical input.

The local repository must have a remote for the GitHub repository and `gh` must
already be authenticated:

```sh
python3 harness/collect_github.py \
  --repo OWNER/REPOSITORY \
  --git-dir /path/to/worktree \
  --output /tmp/pr-plan-live.json

implementations/rust/pr-plan git \
  --input /tmp/pr-plan-live.json \
  --git-dir /path/to/worktree
```

Use `--remote NAME` when the relevant remote is not `origin`. `GH_BIN` and
`GIT_BIN` can select alternate executables; they are treated as single argv
entries, not shell commands. The collector invokes both tools with structured
argument arrays and never evaluates shell text.

The generated `refs/pr-plan/base/<number>` and
`refs/pr-plan/head/<number>` refs are intentionally stable. Collection fails
without writing the output if `gh` returns malformed fields, a fetch fails, or
a PR is force-pushed between the API query and fetch.
