from __future__ import annotations

from typing import Literal


def pure_pr(
    number: int,
    *,
    head_ref: str | None = None,
    base_ref: str = "main",
    draft: bool = False,
    mergeable: str = "MERGEABLE",
    files: list[str] | None = None,
    base_conflict_paths: list[str] | None = None,
) -> dict[str, object]:
    return {
        "number": number,
        "title": f"PR {number}",
        "author": None if number % 2 == 0 else "alice",
        "head_ref": head_ref or f"feature/{number}",
        "base_ref": base_ref,
        "draft": draft,
        "mergeable": mergeable,
        "review_decision": "APPROVED",
        "created_at": "2025-01-01T00:00:00Z",
        "updated_at": "2025-01-02T00:00:00Z",
        "additions": number,
        "deletions": 0,
        "files": files or [],
        "base_conflict_paths": base_conflict_paths or [],
    }


def pure_document(prs: list[dict[str, object]]) -> dict[str, object]:
    return {
        "schema_version": 1,
        "repository": "acme/widgets",
        "prs": prs,
        "conflict_edges": [],
        "ancestry_edges": [],
    }


def git_pr(number: int, head: str, base: str) -> dict[str, object]:
    item = pure_pr(number)
    del item["files"]
    del item["base_conflict_paths"]
    item["git_head"] = head
    item["git_base"] = base
    return item
