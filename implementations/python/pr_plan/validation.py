from __future__ import annotations

import json
import re
from datetime import datetime
from pathlib import Path
from typing import NoReturn

from pr_plan.model import (
    AnalysisInput,
    ConflictEdge,
    GitRevision,
    Mergeable,
    PrNumber,
    PullRequest,
    ReviewDecision,
)


class InputError(ValueError):
    """The input is not valid pr-plan JSON."""


_PURE_ROOT_KEYS = frozenset(
    {"schema_version", "repository", "prs", "conflict_edges", "ancestry_edges"}
)
_GIT_ROOT_KEYS = frozenset({"schema_version", "repository", "prs"})
_COMMON_PR_KEYS = frozenset(
    {
        "number",
        "title",
        "author",
        "head_ref",
        "base_ref",
        "draft",
        "mergeable",
        "review_decision",
        "created_at",
        "updated_at",
        "additions",
        "deletions",
    }
)
_PURE_PR_KEYS = _COMMON_PR_KEYS | {"files", "base_conflict_paths"}
_GIT_PR_KEYS = _COMMON_PR_KEYS | {"git_head", "git_base"}
_MERGEABLE = frozenset({"MERGEABLE", "CONFLICTING", "UNKNOWN"})
_REVIEW_DECISIONS = frozenset(
    {"APPROVED", "CHANGES_REQUESTED", "REVIEW_REQUIRED", "NONE"}
)
_CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]")


def _fail(path: str, message: str) -> NoReturn:
    raise InputError(f"{path}: {message}")


def _object(value: object, path: str) -> dict[str, object]:
    if not isinstance(value, dict):
        _fail(path, "expected an object")
    result: dict[str, object] = {}
    for key, item in value.items():
        if not isinstance(key, str):
            _fail(path, "object keys must be strings")
        result[key] = item
    return result


def _array(value: object, path: str) -> list[object]:
    if not isinstance(value, list):
        _fail(path, "expected an array")
    return value


def _exact_keys(value: dict[str, object], expected: frozenset[str], path: str) -> None:
    missing = sorted(expected - value.keys())
    unknown = sorted(value.keys() - expected)
    if missing:
        _fail(path, f"missing field(s): {', '.join(missing)}")
    if unknown:
        _fail(path, f"unknown field(s): {', '.join(unknown)}")


def _string(value: object, path: str, *, nonempty: bool = True) -> str:
    if not isinstance(value, str):
        _fail(path, "expected a string")
    if nonempty and not value:
        _fail(path, "must not be empty")
    if "\x00" in value:
        _fail(path, "must not contain NUL")
    return value


def _optional_string(value: object, path: str) -> str | None:
    if value is None:
        return None
    return _string(value, path)


def _integer(value: object, path: str, *, positive: bool = False) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        _fail(path, "expected an integer")
    if positive and value <= 0:
        _fail(path, "must be positive")
    if not positive and value < 0:
        _fail(path, "must not be negative")
    return value


def _boolean(value: object, path: str) -> bool:
    if not isinstance(value, bool):
        _fail(path, "expected a boolean")
    return value


def _timestamp(value: object, path: str) -> str:
    timestamp = _string(value, path)
    try:
        parsed = datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
    except ValueError:
        _fail(path, "expected an RFC 3339 timestamp")
    if parsed.tzinfo is None:
        _fail(path, "timestamp must include a UTC offset")
    return timestamp


def _enum_string(value: object, allowed: frozenset[str], path: str) -> str:
    item = _string(value, path)
    if item not in allowed:
        _fail(path, f"expected one of: {', '.join(sorted(allowed))}")
    return item


def _paths(value: object, path: str) -> tuple[str, ...]:
    result: list[str] = []
    for index, item in enumerate(_array(value, path)):
        file_path = _string(item, f"{path}[{index}]")
        if file_path.startswith("/"):
            _fail(f"{path}[{index}]", "expected a repository-relative path")
        result.append(file_path)
    if len(result) != len(set(result)):
        _fail(path, "paths must be unique")
    return tuple(sorted(result))


def _revision(value: object, path: str) -> GitRevision:
    revision = _string(value, path)
    if revision.startswith("-"):
        _fail(path, "revision must not start with '-'")
    if _CONTROL_RE.search(revision):
        _fail(path, "revision must not contain control characters")
    return GitRevision(revision)


def _pull_request(value: object, index: int, mode: str) -> PullRequest:
    path = f"$.prs[{index}]"
    item = _object(value, path)
    _exact_keys(item, _PURE_PR_KEYS if mode == "pure" else _GIT_PR_KEYS, path)
    number = PrNumber(_integer(item["number"], f"{path}.number", positive=True))
    mergeable_value = _enum_string(item["mergeable"], _MERGEABLE, f"{path}.mergeable")
    mergeable: Mergeable
    if mergeable_value == "MERGEABLE":
        mergeable = "MERGEABLE"
    elif mergeable_value == "CONFLICTING":
        mergeable = "CONFLICTING"
    else:
        mergeable = "UNKNOWN"

    decoded_review = _enum_string(
        item["review_decision"], _REVIEW_DECISIONS, f"{path}.review_decision"
    )
    review: ReviewDecision
    if decoded_review == "APPROVED":
        review = "APPROVED"
    elif decoded_review == "CHANGES_REQUESTED":
        review = "CHANGES_REQUESTED"
    elif decoded_review == "REVIEW_REQUIRED":
        review = "REVIEW_REQUIRED"
    else:
        review = "NONE"

    if mode == "pure":
        files = _paths(item["files"], f"{path}.files")
        base_conflicts = _paths(
            item["base_conflict_paths"], f"{path}.base_conflict_paths"
        )
        git_head = None
        git_base = None
    else:
        files = ()
        base_conflicts = ()
        git_head = _revision(item["git_head"], f"{path}.git_head")
        git_base = _revision(item["git_base"], f"{path}.git_base")

    return PullRequest(
        number=number,
        title=_string(item["title"], f"{path}.title"),
        author=_optional_string(item["author"], f"{path}.author"),
        head_ref=_string(item["head_ref"], f"{path}.head_ref"),
        base_ref=_string(item["base_ref"], f"{path}.base_ref"),
        draft=_boolean(item["draft"], f"{path}.draft"),
        mergeable=mergeable,
        review_decision=review,
        created_at=_timestamp(item["created_at"], f"{path}.created_at"),
        updated_at=_timestamp(item["updated_at"], f"{path}.updated_at"),
        additions=_integer(item["additions"], f"{path}.additions"),
        deletions=_integer(item["deletions"], f"{path}.deletions"),
        files=files,
        base_conflict_paths=base_conflicts,
        git_head=git_head,
        git_base=git_base,
    )


def _pr_number(value: object, path: str, known: set[PrNumber]) -> PrNumber:
    number = PrNumber(_integer(value, path, positive=True))
    if number not in known:
        _fail(path, f"unknown pull request #{number}")
    return number


def _conflict_edges(value: object, known: set[PrNumber]) -> tuple[ConflictEdge, ...]:
    edges: list[ConflictEdge] = []
    pairs: set[tuple[PrNumber, PrNumber]] = set()
    for index, raw_edge in enumerate(_array(value, "$.conflict_edges")):
        path = f"$.conflict_edges[{index}]"
        edge = _object(raw_edge, path)
        _exact_keys(edge, frozenset({"a", "b", "paths"}), path)
        a = _pr_number(edge["a"], f"{path}.a", known)
        b = _pr_number(edge["b"], f"{path}.b", known)
        if a == b:
            _fail(path, "a conflict edge must join two different pull requests")
        if b < a:
            a, b = b, a
        if (a, b) in pairs:
            _fail(path, f"duplicate conflict edge #{a}/#{b}")
        pairs.add((a, b))
        edges.append(ConflictEdge(a, b, _paths(edge["paths"], f"{path}.paths")))
    return tuple(sorted(edges, key=lambda edge: (edge.a, edge.b)))


def _ancestry_edges(
    value: object, known: set[PrNumber]
) -> tuple[tuple[PrNumber, PrNumber], ...]:
    edges: list[tuple[PrNumber, PrNumber]] = []
    seen: set[tuple[PrNumber, PrNumber]] = set()
    for index, raw_edge in enumerate(_array(value, "$.ancestry_edges")):
        path = f"$.ancestry_edges[{index}]"
        edge = _object(raw_edge, path)
        _exact_keys(edge, frozenset({"before", "after"}), path)
        before = _pr_number(edge["before"], f"{path}.before", known)
        after = _pr_number(edge["after"], f"{path}.after", known)
        if before == after:
            _fail(path, "an ancestry edge must join two different pull requests")
        if (before, after) in seen:
            _fail(path, f"duplicate ancestry edge #{before} -> #{after}")
        seen.add((before, after))
        edges.append((before, after))
    return tuple(sorted(edges))


def decode_document(value: object, mode: str) -> AnalysisInput:
    if mode not in {"pure", "git"}:
        raise ValueError(f"unsupported mode: {mode}")
    root = _object(value, "$")
    _exact_keys(root, _PURE_ROOT_KEYS if mode == "pure" else _GIT_ROOT_KEYS, "$")
    version = _integer(root["schema_version"], "$.schema_version", positive=True)
    if version != 1:
        _fail("$.schema_version", "only schema version 1 is supported")
    repository = _string(root["repository"], "$.repository")
    prs = tuple(
        _pull_request(item, index, mode)
        for index, item in enumerate(_array(root["prs"], "$.prs"))
    )
    numbers = [pr.number for pr in prs]
    if len(numbers) != len(set(numbers)):
        _fail("$.prs", "pull request numbers must be unique")
    head_refs = [pr.head_ref for pr in prs]
    if len(head_refs) != len(set(head_refs)):
        _fail("$.prs", "head_ref values must be unique")
    known = set(numbers)
    if mode == "pure":
        conflicts = _conflict_edges(root["conflict_edges"], known)
        ancestry = _ancestry_edges(root["ancestry_edges"], known)
    else:
        conflicts = ()
        ancestry = ()
    return AnalysisInput(
        repository=repository,
        prs=tuple(sorted(prs, key=lambda pr: pr.number)),
        conflict_edges=conflicts,
        ancestry_edges=ancestry,
    )


def load_document(path: Path, mode: str) -> AnalysisInput:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        raise InputError(f"{path}: {error.strerror or error}") from error
    try:
        value: object = json.loads(text)
    except json.JSONDecodeError as error:
        raise InputError(
            f"{path}:{error.lineno}:{error.colno}: invalid JSON: {error.msg}"
        ) from error
    return decode_document(value, mode)
