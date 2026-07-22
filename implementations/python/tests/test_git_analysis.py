from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from pr_plan.git_analysis import GitError, GitRepository, analyze_repository
from pr_plan.planner import make_plan
from pr_plan.validation import decode_document
from tests.helpers import git_pr


def _git(repository: Path, *args: str) -> str:
    completed: subprocess.CompletedProcess[str] = subprocess.run(
        ("git", "-C", str(repository), *args),
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return completed.stdout.strip()


def _commit(repository: Path, message: str) -> None:
    _git(
        repository,
        "-c",
        "user.name=Test User",
        "-c",
        "user.email=test@example.com",
        "commit",
        "-am",
        message,
    )


class GitAnalysisTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.repository = Path(self.temporary_directory.name)
        _git(self.repository, "init", "--initial-branch=main")
        (self.repository / "shared.txt").write_text("base\n", encoding="utf-8")
        _git(self.repository, "add", "shared.txt")
        _commit(self.repository, "base")
        self.base = _git(self.repository, "rev-parse", "HEAD")

        _git(self.repository, "checkout", "-b", "left")
        (self.repository / "shared.txt").write_text("left\n", encoding="utf-8")
        (self.repository / "left.txt").write_text("left\n", encoding="utf-8")
        _git(self.repository, "add", "left.txt")
        _commit(self.repository, "left")

        _git(self.repository, "checkout", "-b", "right", self.base)
        (self.repository / "shared.txt").write_text("right\n", encoding="utf-8")
        _commit(self.repository, "right")

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def test_real_git_analysis_detects_files_and_conflict(self) -> None:
        document: dict[str, object] = {
            "schema_version": 1,
            "repository": "acme/widgets",
            "prs": [
                git_pr(1, "refs/heads/left", "refs/heads/main"),
                git_pr(2, "refs/heads/right", "refs/heads/main"),
            ],
        }
        analyzed = analyze_repository(decode_document(document, "git"), self.repository)
        plan = make_plan(analyzed)
        self.assertEqual(analyzed.prs[0].files, ("left.txt", "shared.txt"))
        self.assertEqual(analyzed.prs[1].files, ("shared.txt",))
        self.assertEqual(analyzed.prs[0].base_conflict_paths, ())
        self.assertEqual(
            tuple((edge.a, edge.b, edge.paths) for edge in plan.conflict_edges),
            ((1, 2, ("shared.txt",)),),
        )
        self.assertEqual(plan.suggested_landing_batches, ((1,), (2,)))

    def test_expected_and_unexpected_nonzero_status(self) -> None:
        repository = GitRepository(self.repository)
        left = repository.resolve_commit("refs/heads/left")
        right = repository.resolve_commit("refs/heads/right")
        self.assertFalse(repository.is_ancestor(left, right))
        with self.assertRaisesRegex(GitError, "exited with status 1"):
            repository.run(("merge-base", "--is-ancestor", left, right))

    def test_missing_revision_is_a_clean_error(self) -> None:
        repository = GitRepository(self.repository)
        with self.assertRaisesRegex(GitError, "git rev-parse exited"):
            repository.resolve_commit("refs/heads/missing")

    def test_inherited_git_dir_cannot_redirect_repository(self) -> None:
        with mock.patch.dict(os.environ, {"GIT_DIR": "/definitely/not/the/repository"}):
            repository = GitRepository(self.repository)
            self.assertEqual(repository.resolve_commit("refs/heads/main"), self.base)


if __name__ == "__main__":
    unittest.main()
