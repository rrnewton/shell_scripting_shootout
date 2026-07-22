#!/usr/bin/env python3
"""Collect live GitHub PR metadata and local refs for offline analysis."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Literal, NoReturn, Sequence, TypeAlias


JsonScalar: TypeAlias = None | bool | int | float | str
JsonValue: TypeAlias = JsonScalar | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]
Mergeable: TypeAlias = Literal["MERGEABLE", "CONFLICTING", "UNKNOWN"]
ReviewDecision: TypeAlias = Literal[
    "APPROVED", "CHANGES_REQUESTED", "REVIEW_REQUIRED", "NONE"
]

GH_FIELDS = (
    "number",
    "title",
    "author",
    "headRefName",
    "baseRefName",
    "headRefOid",
    "isDraft",
    "mergeable",
    "reviewDecision",
    "createdAt",
    "updatedAt",
    "additions",
    "deletions",
)
_PR_KEYS = frozenset(GH_FIELDS)
_AUTHOR_KEYS = frozenset({"id", "is_bot", "login", "name"})
_MERGEABLE = frozenset({"MERGEABLE", "CONFLICTING", "UNKNOWN"})
_REVIEW_DECISIONS = frozenset(
    {"APPROVED", "CHANGES_REQUESTED", "REVIEW_REQUIRED", ""}
)
_OID_RE = re.compile(r"(?:[0-9a-f]{40}|[0-9a-f]{64})\Z")
_RFC3339_RE = re.compile(
    r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})\Z"
)
_CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]")


class CollectionError(RuntimeError):
    """Live metadata or repository state failed validation."""


@dataclass(frozen=True, slots=True)
class PullRequest:
    number: int
    title: str
    author: str | None
    head_ref: str
    base_ref: str
    head_oid: str
    draft: bool
    mergeable: Mergeable
    review_decision: ReviewDecision
    created_at: str
    updated_at: str
    additions: int
    deletions: int


def _fail(path: str, message: str) -> NoReturn:
    raise CollectionError(f"{path}: {message}")


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
    if _CONTROL_RE.search(value):
        _fail(path, "must not contain control characters")
    return value


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
    if _RFC3339_RE.fullmatch(timestamp) is None:
        _fail(path, "expected an RFC 3339 timestamp")
    try:
        parsed = datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
    except ValueError:
        _fail(path, "expected an RFC 3339 timestamp")
    if parsed.tzinfo is None:
        _fail(path, "timestamp must include a UTC offset")
    return timestamp


def _oid(value: object, path: str) -> str:
    oid = _string(value, path)
    if _OID_RE.fullmatch(oid) is None:
        _fail(path, "expected a lowercase 40- or 64-digit hexadecimal Git OID")
    return oid


def _author(value: object, path: str) -> str | None:
    if value is None:
        return None
    author = _object(value, path)
    _exact_keys(author, _AUTHOR_KEYS, path)
    _string(author["id"], f"{path}.id", nonempty=False)
    _boolean(author["is_bot"], f"{path}.is_bot")
    login = _string(author["login"], f"{path}.login")
    _string(author["name"], f"{path}.name", nonempty=False)
    return login


def _mergeable(value: object, path: str) -> Mergeable:
    item = _string(value, path)
    if item not in _MERGEABLE:
        _fail(path, f"expected one of: {', '.join(sorted(_MERGEABLE))}")
    if item == "MERGEABLE":
        return "MERGEABLE"
    if item == "CONFLICTING":
        return "CONFLICTING"
    return "UNKNOWN"


def _review_decision(value: object, path: str) -> ReviewDecision:
    item = _string(value, path, nonempty=False)
    if item not in _REVIEW_DECISIONS:
        shown = sorted(decision or "<empty>" for decision in _REVIEW_DECISIONS)
        _fail(path, f"expected one of: {', '.join(shown)}")
    if item == "APPROVED":
        return "APPROVED"
    if item == "CHANGES_REQUESTED":
        return "CHANGES_REQUESTED"
    if item == "REVIEW_REQUIRED":
        return "REVIEW_REQUIRED"
    return "NONE"


def decode_gh_output(text: str) -> tuple[PullRequest, ...]:
    """Strictly decode the selected fields emitted by ``gh pr list``."""
    try:
        raw: object = json.loads(text)
    except json.JSONDecodeError as error:
        raise CollectionError(
            f"gh output:{error.lineno}:{error.colno}: invalid JSON: {error.msg}"
        ) from error

    prs: list[PullRequest] = []
    for index, value in enumerate(_array(raw, "$")):
        path = f"$[{index}]"
        item = _object(value, path)
        _exact_keys(item, _PR_KEYS, path)
        prs.append(
            PullRequest(
                number=_integer(item["number"], f"{path}.number", positive=True),
                title=_string(item["title"], f"{path}.title"),
                author=_author(item["author"], f"{path}.author"),
                head_ref=_string(item["headRefName"], f"{path}.headRefName"),
                base_ref=_string(item["baseRefName"], f"{path}.baseRefName"),
                head_oid=_oid(item["headRefOid"], f"{path}.headRefOid"),
                draft=_boolean(item["isDraft"], f"{path}.isDraft"),
                mergeable=_mergeable(item["mergeable"], f"{path}.mergeable"),
                review_decision=_review_decision(
                    item["reviewDecision"], f"{path}.reviewDecision"
                ),
                created_at=_timestamp(item["createdAt"], f"{path}.createdAt"),
                updated_at=_timestamp(item["updatedAt"], f"{path}.updatedAt"),
                additions=_integer(item["additions"], f"{path}.additions"),
                deletions=_integer(item["deletions"], f"{path}.deletions"),
            )
        )

    numbers = [pr.number for pr in prs]
    if len(numbers) != len(set(numbers)):
        _fail("$", "pull request numbers must be unique")
    head_refs = [pr.head_ref for pr in prs]
    if len(head_refs) != len(set(head_refs)):
        _fail("$", "headRefName values must be unique")
    return tuple(sorted(prs, key=lambda pr: pr.number))


def _run(args: Sequence[str], *, cwd: Path | None = None) -> str:
    try:
        result = subprocess.run(
            args,
            cwd=cwd,
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError as error:
        raise CollectionError(f"cannot run {args[0]}: {error}") from error
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "no diagnostic output"
        raise CollectionError(f"{args[0]} exited {result.returncode}: {detail}")
    return result.stdout


def _check_ref_name(git_bin: str, repository: Path, ref_name: str, path: str) -> None:
    try:
        _run([git_bin, "check-ref-format", f"refs/heads/{ref_name}"], cwd=repository)
    except CollectionError as error:
        raise CollectionError(f"{path}: invalid Git branch name {ref_name!r}") from error


def _fetch_refs(
    git_bin: str, repository: Path, remote: str, prs: tuple[PullRequest, ...]
) -> None:
    if remote.startswith("-") or _CONTROL_RE.search(remote):
        _fail("--remote", "must not start with '-' or contain control characters")
    _run([git_bin, "rev-parse", "--is-inside-work-tree"], cwd=repository)
    refspecs: list[str] = []
    for pr in prs:
        _check_ref_name(git_bin, repository, pr.head_ref, f"PR #{pr.number} headRefName")
        _check_ref_name(git_bin, repository, pr.base_ref, f"PR #{pr.number} baseRefName")
        refspecs.extend(
            (
                f"+refs/heads/{pr.base_ref}:refs/pr-plan/base/{pr.number}",
                f"+refs/pull/{pr.number}/head:refs/pr-plan/head/{pr.number}",
            )
        )
    if refspecs:
        _run(
            [git_bin, "fetch", "--force", "--no-tags", "--", remote, *refspecs],
            cwd=repository,
        )


def _verify_heads(
    git_bin: str, repository: Path, prs: tuple[PullRequest, ...]
) -> None:
    for pr in prs:
        ref = f"refs/pr-plan/head/{pr.number}"
        actual = _run([git_bin, "rev-parse", "--verify", f"{ref}^{{commit}}"], cwd=repository)
        actual_oid = actual.strip()
        if actual_oid != pr.head_oid:
            raise CollectionError(
                f"PR #{pr.number}: GitHub head OID {pr.head_oid} does not match "
                f"fetched {ref} OID {actual_oid}"
            )


def _document(repository_name: str, prs: tuple[PullRequest, ...]) -> JsonObject:
    encoded_prs: list[JsonValue] = []
    for pr in prs:
        encoded_prs.append(
            {
                "number": pr.number,
                "title": pr.title,
                "author": pr.author,
                "head_ref": pr.head_ref,
                "base_ref": pr.base_ref,
                "git_head": f"refs/pr-plan/head/{pr.number}",
                "git_base": f"refs/pr-plan/base/{pr.number}",
                "draft": pr.draft,
                "mergeable": pr.mergeable,
                "review_decision": pr.review_decision,
                "created_at": pr.created_at,
                "updated_at": pr.updated_at,
                "additions": pr.additions,
                "deletions": pr.deletions,
            }
        )
    return {"schema_version": 1, "repository": repository_name, "prs": encoded_prs}


def collect(
    repository_name: str,
    local_repository: Path,
    *,
    remote: str = "origin",
    limit: int = 1000,
    gh_bin: str | None = None,
    git_bin: str | None = None,
) -> JsonObject:
    """Collect, fetch, verify, and return a candidate Git-mode document."""
    if not repository_name or _CONTROL_RE.search(repository_name):
        _fail("--repo", "must not be empty or contain control characters")
    if limit <= 0:
        _fail("--limit", "must be positive")
    resolved_gh = gh_bin if gh_bin is not None else os.environ.get("GH_BIN", "gh")
    resolved_git = git_bin if git_bin is not None else os.environ.get("GIT_BIN", "git")
    output = _run(
        [
            resolved_gh,
            "pr",
            "list",
            "--repo",
            repository_name,
            "--state",
            "open",
            "--limit",
            str(limit),
            "--json",
            ",".join(GH_FIELDS),
        ]
    )
    prs = decode_gh_output(output)
    _fetch_refs(resolved_git, local_repository, remote, prs)
    _verify_heads(resolved_git, local_repository, prs)
    return _document(repository_name, prs)


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, help="GitHub OWNER/REPOSITORY")
    parser.add_argument("--git-dir", required=True, type=Path, help="local Git worktree")
    parser.add_argument("--remote", default="origin", help="Git remote to fetch")
    parser.add_argument("--limit", default=1000, type=int, help="maximum open PRs")
    parser.add_argument("--output", type=Path, help="write JSON here (default: stdout)")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        document = collect(
            args.repo,
            args.git_dir,
            remote=args.remote,
            limit=args.limit,
        )
        rendered = json.dumps(document, indent=2, sort_keys=True) + "\n"
        if args.output is None:
            sys.stdout.write(rendered)
        else:
            args.output.write_text(rendered, encoding="utf-8")
    except (CollectionError, OSError) as error:
        print(f"collect-github: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
