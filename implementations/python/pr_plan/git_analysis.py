from __future__ import annotations

import os
import re
import subprocess
from dataclasses import dataclass, replace
from pathlib import Path

from pr_plan.model import AnalysisInput, ConflictEdge, PrNumber, PullRequest


class GitError(RuntimeError):
    """A Git invocation or repository check failed."""


@dataclass(frozen=True, slots=True)
class CommandResult:
    returncode: int
    stdout: bytes
    stderr: bytes


class GitRepository:
    def __init__(self, path: Path, *, timeout_seconds: float = 30.0) -> None:
        try:
            resolved = path.resolve(strict=True)
        except OSError as error:
            raise GitError(f"{path}: {error.strerror or error}") from error
        if not resolved.is_dir():
            raise GitError(f"{path}: Git directory must be a directory")
        self.path = resolved
        self.timeout_seconds = timeout_seconds
        self.run(("rev-parse", "--git-dir"))

    def run(
        self, args: tuple[str, ...], *, expected: frozenset[int] = frozenset({0})
    ) -> CommandResult:
        command = ("git", "-C", os.fspath(self.path), *args)
        environment = os.environ.copy()
        for variable in (
            "GIT_ALTERNATE_OBJECT_DIRECTORIES",
            "GIT_COMMON_DIR",
            "GIT_CONFIG_COUNT",
            "GIT_CONFIG_PARAMETERS",
            "GIT_DIR",
            "GIT_INDEX_FILE",
            "GIT_OBJECT_DIRECTORY",
            "GIT_WORK_TREE",
        ):
            environment.pop(variable, None)
        environment.update(
            {
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_CONFIG_GLOBAL": os.devnull,
                "GIT_OPTIONAL_LOCKS": "0",
                "GIT_TERMINAL_PROMPT": "0",
                "LC_ALL": "C",
            }
        )
        try:
            completed: subprocess.CompletedProcess[bytes] = subprocess.run(
                command,
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=environment,
                timeout=self.timeout_seconds,
            )
        except FileNotFoundError as error:
            raise GitError("git executable was not found") from error
        except subprocess.TimeoutExpired as error:
            raise GitError(
                f"git {args[0]} timed out after {self.timeout_seconds:g} seconds"
            ) from error
        result = CommandResult(completed.returncode, completed.stdout, completed.stderr)
        if result.returncode not in expected:
            detail = result.stderr.decode("utf-8", errors="replace").strip()
            suffix = f": {detail}" if detail else ""
            raise GitError(
                f"git {args[0]} exited with status {result.returncode}{suffix}"
            )
        return result

    def resolve_commit(self, revision: str) -> str:
        result = self.run(("rev-parse", "--verify", f"{revision}^{{commit}}"))
        object_id = result.stdout.decode("ascii", errors="strict").strip()
        if re.fullmatch(r"[0-9a-fA-F]{40}|[0-9a-fA-F]{64}", object_id) is None:
            raise GitError("git rev-parse returned an invalid commit ID")
        return object_id.lower()

    def merge_base(self, left: str, right: str) -> str:
        result = self.run(("merge-base", left, right))
        object_id = result.stdout.decode("ascii", errors="strict").strip()
        if re.fullmatch(r"[0-9a-fA-F]{40}|[0-9a-fA-F]{64}", object_id) is None:
            raise GitError("git merge-base returned an invalid commit ID")
        return object_id.lower()

    def changed_files(self, base: str, head: str) -> tuple[str, ...]:
        common = self.merge_base(base, head)
        result = self.run(("diff", "--name-only", "-z", common, head, "--"))
        return _nul_paths(result.stdout)

    def conflict_paths(self, left: str, right: str) -> tuple[str, ...]:
        result = self.run(
            (
                "merge-tree",
                "--write-tree",
                "--name-only",
                "--no-messages",
                "-z",
                left,
                right,
            ),
            expected=frozenset({0, 1}),
        )
        if result.returncode == 0:
            return ()
        records = result.stdout.split(b"\0")
        # In --write-tree mode the first record is always the resulting tree ID.
        return _path_records(records[1:])

    def is_ancestor(self, before: str, after: str) -> bool:
        result = self.run(
            ("merge-base", "--is-ancestor", before, after),
            expected=frozenset({0, 1}),
        )
        return result.returncode == 0


def _path_records(records: list[bytes]) -> tuple[str, ...]:
    return tuple(sorted({os.fsdecode(record) for record in records if record}))


def _nul_paths(output: bytes) -> tuple[str, ...]:
    return _path_records(output.split(b"\0"))


def analyze_repository(data: AnalysisInput, path: Path) -> AnalysisInput:
    repository = GitRepository(path)
    resolved_heads: dict[PrNumber, str] = {}
    analyzed_prs: list[PullRequest] = []
    for pr in data.prs:
        if pr.git_head is None or pr.git_base is None:
            raise GitError(f"internal error: missing Git revisions for PR #{pr.number}")
        head = repository.resolve_commit(pr.git_head)
        base = repository.resolve_commit(pr.git_base)
        resolved_heads[pr.number] = head
        analyzed_prs.append(
            replace(
                pr,
                files=repository.changed_files(base, head),
                base_conflict_paths=repository.conflict_paths(base, head),
            )
        )

    conflicts: list[ConflictEdge] = []
    ancestry: list[tuple[PrNumber, PrNumber]] = []
    for left_index, left in enumerate(data.prs):
        left_head = resolved_heads[left.number]
        for right in data.prs[left_index + 1 :]:
            right_head = resolved_heads[right.number]
            paths = repository.conflict_paths(left_head, right_head)
            if paths:
                conflicts.append(ConflictEdge(left.number, right.number, paths))
            if repository.is_ancestor(left_head, right_head):
                ancestry.append((left.number, right.number))
            if repository.is_ancestor(right_head, left_head):
                ancestry.append((right.number, left.number))

    return AnalysisInput(
        repository=data.repository,
        prs=tuple(analyzed_prs),
        conflict_edges=tuple(conflicts),
        ancestry_edges=tuple(sorted(ancestry)),
    )
