from __future__ import annotations

import json
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path
from typing import Sequence
from unittest.mock import patch

from harness.collect_github import CollectionError, JsonValue, collect


def run(args: Sequence[str], cwd: Path) -> str:
    result = subprocess.run(args, cwd=cwd, check=True, capture_output=True, text=True)
    return result.stdout.strip()


class CollectGithubTest(unittest.TestCase):
    temporary: tempfile.TemporaryDirectory[str]
    root: Path
    remote: Path
    local: Path
    head_oid: str
    fake_gh: Path
    gh_output: Path
    gh_log: Path

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="collect-github-test-")
        self.root = Path(self.temporary.name)
        self.remote = self.root / "remote.git"
        seed = self.root / "seed"
        self.local = self.root / "local"

        run(["git", "init", "--bare", str(self.remote)], self.root)
        run(["git", "init", "-b", "main", str(seed)], self.root)
        run(["git", "config", "user.name", "Test User"], seed)
        run(["git", "config", "user.email", "test@example.invalid"], seed)
        (seed / "base.txt").write_text("base\n", encoding="utf-8")
        run(["git", "add", "base.txt"], seed)
        run(["git", "commit", "-m", "base"], seed)
        run(["git", "switch", "-c", "feature"], seed)
        (seed / "feature.txt").write_text("feature\n", encoding="utf-8")
        run(["git", "add", "feature.txt"], seed)
        run(["git", "commit", "-m", "feature"], seed)
        self.head_oid = run(["git", "rev-parse", "HEAD"], seed)
        run(["git", "remote", "add", "origin", str(self.remote)], seed)
        run(["git", "push", "origin", "main", "feature"], seed)
        run(
            ["git", "update-ref", "refs/pull/7/head", self.head_oid],
            self.remote,
        )

        run(["git", "init", str(self.local)], self.root)
        run(["git", "remote", "add", "origin", str(self.remote)], self.local)

        fake_dir = self.root / "fake gh bin"
        fake_dir.mkdir()
        self.fake_gh = fake_dir / "gh"
        self.fake_gh.write_text(
            "#!/usr/bin/env python3\n"
            "import os, pathlib, sys\n"
            "pathlib.Path(os.environ['FAKE_GH_LOG']).write_text('\\n'.join(sys.argv[1:]))\n"
            "sys.stderr.write(os.environ.get('FAKE_GH_STDERR', ''))\n"
            "sys.stdout.write(pathlib.Path(os.environ['FAKE_GH_OUTPUT']).read_text())\n"
            "raise SystemExit(int(os.environ.get('FAKE_GH_EXIT', '0')))\n",
            encoding="utf-8",
        )
        self.fake_gh.chmod(self.fake_gh.stat().st_mode | stat.S_IXUSR)
        self.gh_output = self.root / "gh-output.json"
        self.gh_log = self.root / "gh-argv.txt"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def gh_pr(self, oid: str | None = None) -> dict[str, JsonValue]:
        return {
            "number": 7,
            "title": "A live PR",
            "author": None,
            "headRefName": "feature",
            "baseRefName": "main",
            "headRefOid": oid if oid is not None else self.head_oid,
            "isDraft": False,
            "mergeable": "MERGEABLE",
            "reviewDecision": "",
            "createdAt": "2026-07-20T01:02:03Z",
            "updatedAt": "2026-07-21T04:05:06Z",
            "additions": 1,
            "deletions": 0,
        }

    def environment(self, *, exit_code: int = 0, stderr: str = "") -> dict[str, str]:
        return {
            "GH_BIN": str(self.fake_gh),
            "FAKE_GH_OUTPUT": str(self.gh_output),
            "FAKE_GH_LOG": str(self.gh_log),
            "FAKE_GH_EXIT": str(exit_code),
            "FAKE_GH_STDERR": stderr,
        }

    def test_success_fetches_and_verifies_refs(self) -> None:
        self.gh_output.write_text(json.dumps([self.gh_pr()]), encoding="utf-8")
        with patch.dict(os.environ, self.environment(), clear=False):
            document = collect("owner/project", self.local)

        prs = document["prs"]
        self.assertIsInstance(prs, list)
        assert isinstance(prs, list)
        pr = prs[0]
        self.assertIsInstance(pr, dict)
        assert isinstance(pr, dict)
        self.assertEqual(pr["author"], None)
        self.assertEqual(pr["review_decision"], "NONE")
        self.assertEqual(pr["git_head"], "refs/pr-plan/head/7")
        self.assertEqual(
            run(["git", "rev-parse", "refs/pr-plan/head/7"], self.local),
            self.head_oid,
        )
        self.assertEqual(
            self.gh_log.read_text(encoding="utf-8").splitlines()[:4],
            ["pr", "list", "--repo", "owner/project"],
        )

    def test_rejects_malformed_gh_output_before_fetch(self) -> None:
        malformed: list[tuple[str, object, str]] = [
            ("root", {"number": 7}, "expected an array"),
            ("author", [{**self.gh_pr(), "author": "alice"}], "expected an object"),
            ("enum", [{**self.gh_pr(), "mergeable": "MAYBE"}], "expected one of"),
            (
                "timestamp",
                [{**self.gh_pr(), "createdAt": "2026-07-20 01:02:03Z"}],
                "RFC 3339",
            ),
            ("oid", [{**self.gh_pr(), "headRefOid": "abc123"}], "Git OID"),
        ]
        for label, value, message in malformed:
            with self.subTest(label=label):
                self.gh_output.write_text(json.dumps(value), encoding="utf-8")
                with patch.dict(os.environ, self.environment(), clear=False):
                    with self.assertRaisesRegex(CollectionError, message):
                        collect("owner/project", self.local)
        result = subprocess.run(
            ["git", "show-ref", "--verify", "--quiet", "refs/pr-plan/head/7"],
            cwd=self.local,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)

    def test_reports_gh_failure(self) -> None:
        self.gh_output.write_text("[]", encoding="utf-8")
        with patch.dict(
            os.environ,
            self.environment(exit_code=9, stderr="authentication required\n"),
            clear=False,
        ):
            with self.assertRaisesRegex(
                CollectionError, "exited 9: authentication required"
            ):
                collect("owner/project", self.local)

    def test_rejects_fetched_head_oid_mismatch(self) -> None:
        self.gh_output.write_text(json.dumps([self.gh_pr("0" * 40)]), encoding="utf-8")
        with patch.dict(os.environ, self.environment(), clear=False):
            with self.assertRaisesRegex(CollectionError, "does not match fetched"):
                collect("owner/project", self.local)


if __name__ == "__main__":
    unittest.main()
