from __future__ import annotations

import unittest

from pr_plan.validation import InputError, decode_document
from tests.helpers import git_pr, pure_document, pure_pr


class ValidationTests(unittest.TestCase):
    def test_accepts_missing_optional_author(self) -> None:
        document = pure_document([pure_pr(2)])
        data = decode_document(document, "pure")
        self.assertIsNone(data.prs[0].author)

    def test_rejects_string_pr_number(self) -> None:
        pr = pure_pr(1)
        pr["number"] = "1"
        with self.assertRaisesRegex(InputError, r"prs\[0\]\.number: expected an integer"):
            decode_document(pure_document([pr]), "pure")

    def test_rejects_boolean_as_integer(self) -> None:
        pr = pure_pr(1)
        pr["additions"] = True
        with self.assertRaisesRegex(InputError, "additions: expected an integer"):
            decode_document(pure_document([pr]), "pure")

    def test_rejects_wrong_optional_author_type(self) -> None:
        pr = pure_pr(1)
        pr["author"] = {"login": "alice"}
        with self.assertRaisesRegex(InputError, "author: expected a string"):
            decode_document(pure_document([pr]), "pure")

    def test_rejects_null_review_decision(self) -> None:
        pr = pure_pr(1)
        pr["review_decision"] = None
        with self.assertRaisesRegex(InputError, "review_decision: expected a string"):
            decode_document(pure_document([pr]), "pure")

    def test_rejects_unknown_fields(self) -> None:
        document = pure_document([])
        document["extra"] = True
        with self.assertRaisesRegex(InputError, "unknown field.*extra"):
            decode_document(document, "pure")

    def test_rejects_invalid_enum_and_timestamp(self) -> None:
        pr = pure_pr(1)
        pr["mergeable"] = "YES"
        with self.assertRaisesRegex(InputError, "expected one of"):
            decode_document(pure_document([pr]), "pure")
        pr = pure_pr(1)
        pr["created_at"] = "yesterday"
        with self.assertRaisesRegex(InputError, "RFC 3339"):
            decode_document(pure_document([pr]), "pure")

    def test_rejects_unsafe_git_revision(self) -> None:
        document: dict[str, object] = {
            "schema_version": 1,
            "repository": "acme/widgets",
            "prs": [git_pr(1, "--upload-pack=bad", "main")],
        }
        with self.assertRaisesRegex(InputError, "must not start"):
            decode_document(document, "git")

    def test_rejects_duplicate_paths_and_edges(self) -> None:
        first = pure_pr(1, files=["same", "same"])
        with self.assertRaisesRegex(InputError, "paths must be unique"):
            decode_document(pure_document([first]), "pure")


if __name__ == "__main__":
    unittest.main()
