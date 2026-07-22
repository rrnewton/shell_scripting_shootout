from __future__ import annotations

from dataclasses import dataclass
from typing import Literal, NewType, TypeAlias

PrNumber = NewType("PrNumber", int)
GitRevision = NewType("GitRevision", str)

Mergeable: TypeAlias = Literal["MERGEABLE", "CONFLICTING", "UNKNOWN"]
ReviewDecision: TypeAlias = Literal[
    "APPROVED", "CHANGES_REQUESTED", "REVIEW_REQUIRED", "NONE"
]
OrderReason: TypeAlias = Literal["base-ref", "ancestry"]
HoldReason: TypeAlias = str
RebaseReason: TypeAlias = Literal["pair-conflict", "stack-dependency"]

JsonScalar: TypeAlias = None | bool | int | float | str
JsonValue: TypeAlias = JsonScalar | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]


@dataclass(frozen=True, slots=True)
class PullRequest:
    number: PrNumber
    title: str
    author: str | None
    head_ref: str
    base_ref: str
    draft: bool
    mergeable: Mergeable
    review_decision: ReviewDecision
    created_at: str
    updated_at: str
    additions: int
    deletions: int
    files: tuple[str, ...]
    base_conflict_paths: tuple[str, ...]
    git_head: GitRevision | None = None
    git_base: GitRevision | None = None


@dataclass(frozen=True, slots=True)
class ConflictEdge:
    a: PrNumber
    b: PrNumber
    paths: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class OrderingEdge:
    before: PrNumber
    after: PrNumber
    reason: OrderReason


@dataclass(frozen=True, slots=True)
class HeldPullRequest:
    pr: PrNumber
    reasons: tuple[HoldReason, ...]


@dataclass(frozen=True, slots=True)
class RebaseEntry:
    pr: PrNumber
    after: tuple[PrNumber, ...]
    reasons: tuple[RebaseReason, ...]


@dataclass(frozen=True, slots=True)
class AnalysisInput:
    repository: str
    prs: tuple[PullRequest, ...]
    conflict_edges: tuple[ConflictEdge, ...]
    ancestry_edges: tuple[tuple[PrNumber, PrNumber], ...]


@dataclass(frozen=True, slots=True)
class Plan:
    repository: str
    nodes: tuple[PullRequest, ...]
    conflict_edges: tuple[ConflictEdge, ...]
    file_overlap_edges: tuple[ConflictEdge, ...]
    ordering_edges: tuple[OrderingEdge, ...]
    stacks: tuple[tuple[PrNumber, ...], ...]
    suggested_landing_batches: tuple[tuple[PrNumber, ...], ...]
    suggested_rebase_plan: tuple[RebaseEntry, ...]
    ready_landing_batches: tuple[tuple[PrNumber, ...], ...]
    ready_now: tuple[PrNumber, ...]
    held_prs: tuple[HeldPullRequest, ...]
    ordering_cycles: tuple[PrNumber, ...]
