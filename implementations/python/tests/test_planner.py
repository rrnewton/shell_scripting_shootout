from __future__ import annotations

import unittest

from pr_plan.planner import make_plan
from pr_plan.validation import decode_document
from tests.helpers import pure_document, pure_pr


class PlannerTests(unittest.TestCase):
    def test_empty_and_single_pr(self) -> None:
        empty = make_plan(decode_document(pure_document([]), "pure"))
        self.assertEqual(empty.suggested_landing_batches, ())
        self.assertEqual(empty.ready_now, ())

        single = make_plan(
            decode_document(pure_document([pure_pr(1, files=["one.txt"])]), "pure")
        )
        self.assertEqual(single.suggested_landing_batches, ((1,),))
        self.assertEqual(single.ready_now, (1,))

    def test_holds_batches_overlaps_and_rebase_plan(self) -> None:
        first = pure_pr(1, files=["common.txt", "first.txt"])
        second = pure_pr(
            2,
            head_ref="feature/2",
            base_ref="feature/1",
            draft=True,
            files=["common.txt"],
        )
        third = pure_pr(3, base_ref="feature/2", files=["third.txt"])
        document = pure_document([third, first, second])
        document["conflict_edges"] = [
            {"a": 3, "b": 1, "paths": ["conflict.txt"]}
        ]
        plan = make_plan(decode_document(document, "pure"))

        self.assertEqual(
            tuple((edge.before, edge.after, edge.reason) for edge in plan.ordering_edges),
            ((1, 2, "base-ref"), (2, 3, "base-ref")),
        )
        self.assertEqual(plan.stacks, ((1, 2, 3),))
        self.assertEqual(plan.suggested_landing_batches, ((1,), (2,), (3,)))
        self.assertEqual(
            tuple((held.pr, held.reasons) for held in plan.held_prs),
            ((2, ("draft",)), (3, ("depends-on-held:#2",))),
        )
        self.assertEqual(plan.ready_landing_batches, ((1,),))
        self.assertEqual(plan.ready_now, (1,))
        self.assertEqual(
            tuple((item.pr, item.after, item.reasons) for item in plan.suggested_rebase_plan),
            (
                (2, (1,), ("stack-dependency",)),
                (3, (1, 2), ("pair-conflict", "stack-dependency")),
            ),
        )
        self.assertEqual(
            tuple((edge.a, edge.b, edge.paths) for edge in plan.file_overlap_edges),
            ((1, 2, ("common.txt",)),),
        )

    def test_hold_reason_order_and_review_does_not_hold(self) -> None:
        pr = pure_pr(
            1,
            draft=True,
            mergeable="CONFLICTING",
            base_conflict_paths=["broken.txt"],
        )
        pr["review_decision"] = "CHANGES_REQUESTED"
        plan = make_plan(decode_document(pure_document([pr]), "pure"))
        self.assertEqual(
            plan.held_prs[0].reasons,
            ("draft", "local-base-conflict", "github-base-conflicting"),
        )

    def test_cycle_is_reported_without_stalling(self) -> None:
        first = pure_pr(1, base_ref="feature/2")
        second = pure_pr(2)
        document = pure_document([first, second])
        document["ancestry_edges"] = [{"before": 1, "after": 2}]
        plan = make_plan(decode_document(document, "pure"))
        self.assertEqual(plan.ordering_cycles, (1, 2))
        self.assertEqual(plan.suggested_landing_batches, ((1,), (2,)))


if __name__ == "__main__":
    unittest.main()
