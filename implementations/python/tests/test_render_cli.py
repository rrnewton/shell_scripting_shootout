from __future__ import annotations

import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

from pr_plan.cli import run
from pr_plan.planner import make_plan
from pr_plan.render import plan_object, render_human, render_json
from pr_plan.validation import decode_document
from tests.helpers import pure_document, pure_pr


class RenderTests(unittest.TestCase):
    def test_json_golden_and_repeatability(self) -> None:
        plan = make_plan(decode_document(pure_document([pure_pr(1)]), "pure"))
        expected: dict[str, object] = {
            "repository": "acme/widgets",
            "nodes": [
                {
                    "pr": 1,
                    "title": "PR 1",
                    "author": "alice",
                    "head_ref": "feature/1",
                    "base_ref": "main",
                    "draft": False,
                    "mergeable": "MERGEABLE",
                    "review_decision": "APPROVED",
                    "additions": 1,
                    "deletions": 0,
                    "files_count": 0,
                    "base_conflict_paths": [],
                }
            ],
            "conflict_edges": [],
            "file_overlap_edges": [],
            "ordering_edges": [],
            "stacks": [],
            "suggested_landing_batches": [[1]],
            "suggested_rebase_plan": [],
            "ready_landing_batches": [[1]],
            "ready_now": [1],
            "held_prs": [],
            "ordering_cycles": [],
        }
        golden = json.dumps(expected, ensure_ascii=True, indent=2, sort_keys=True) + "\n"
        self.assertEqual(render_json(plan), golden)
        self.assertEqual(render_json(plan), render_json(plan))
        self.assertNotIn("git_head", render_json(plan))

    def test_human_golden(self) -> None:
        plan = make_plan(decode_document(pure_document([]), "pure"))
        self.assertEqual(
            render_human(plan),
            "Repository: acme/widgets\n"
            "Pull requests: 0\n"
            "Held pull requests:\n"
            "  (none)\n"
            "Ordering cycles:\n"
            "  (none)\n"
            "Suggested landing batches:\n"
            "  (none)\n"
            "Ready landing batches:\n"
            "  (none)\n"
            "Ready now: (none)\n"
            "Suggested rebase plan:\n"
            "  (none)\n",
        )

    def test_cli_reports_validation_error_and_exit_code(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.json"
            path.write_text('{"schema_version": 1}', encoding="utf-8")
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                status = run(["pure", "--input", str(path)])
        self.assertEqual(status, 1)
        self.assertIn("pr-plan: error: $: missing field", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
