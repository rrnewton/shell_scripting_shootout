from __future__ import annotations

import json

from pr_plan.model import (
    ConflictEdge,
    HeldPullRequest,
    JsonObject,
    JsonValue,
    OrderingEdge,
    Plan,
    PrNumber,
    PullRequest,
    RebaseEntry,
)


def _numbers(values: tuple[PrNumber, ...]) -> list[JsonValue]:
    return [int(value) for value in values]


def _node(pr: PullRequest) -> JsonObject:
    return {
        "additions": pr.additions,
        "author": pr.author or "unknown",
        "base_conflict_paths": list(pr.base_conflict_paths),
        "base_ref": pr.base_ref,
        "deletions": pr.deletions,
        "draft": pr.draft,
        "files_count": len(pr.files),
        "head_ref": pr.head_ref,
        "mergeable": pr.mergeable,
        "pr": int(pr.number),
        "review_decision": pr.review_decision,
        "title": pr.title,
    }


def _conflict(edge: ConflictEdge) -> JsonObject:
    return {"a": int(edge.a), "b": int(edge.b), "paths": list(edge.paths)}


def _ordering(edge: OrderingEdge) -> JsonObject:
    return {
        "after": int(edge.after),
        "before": int(edge.before),
        "reason": edge.reason,
    }


def _held(item: HeldPullRequest) -> JsonObject:
    return {"pr": int(item.pr), "reasons": list(item.reasons)}


def _rebase(item: RebaseEntry) -> JsonObject:
    return {
        "after": _numbers(item.after),
        "pr": int(item.pr),
        "reasons": list(item.reasons),
    }


def plan_object(plan: Plan) -> JsonObject:
    return {
        "conflict_edges": [_conflict(edge) for edge in plan.conflict_edges],
        "file_overlap_edges": [_conflict(edge) for edge in plan.file_overlap_edges],
        "held_prs": [_held(item) for item in plan.held_prs],
        "nodes": [_node(pr) for pr in plan.nodes],
        "ordering_cycles": _numbers(plan.ordering_cycles),
        "ordering_edges": [_ordering(edge) for edge in plan.ordering_edges],
        "ready_landing_batches": [
            _numbers(batch) for batch in plan.ready_landing_batches
        ],
        "ready_now": _numbers(plan.ready_now),
        "repository": plan.repository,
        "stacks": [_numbers(stack) for stack in plan.stacks],
        "suggested_landing_batches": [
            _numbers(batch) for batch in plan.suggested_landing_batches
        ],
        "suggested_rebase_plan": [
            _rebase(item) for item in plan.suggested_rebase_plan
        ],
    }


def render_json(plan: Plan) -> str:
    return json.dumps(
        plan_object(plan), ensure_ascii=True, indent=2, sort_keys=True
    ) + "\n"


def _pr_list(numbers: tuple[PrNumber, ...]) -> str:
    return ", ".join(f"#{number}" for number in numbers) if numbers else "(none)"


def render_human(plan: Plan) -> str:
    lines = [f"Repository: {plan.repository}", f"Pull requests: {len(plan.nodes)}"]
    lines.append("Held pull requests:")
    if plan.held_prs:
        lines.extend(
            f"  #{item.pr}: {', '.join(item.reasons)}" for item in plan.held_prs
        )
    else:
        lines.append("  (none)")
    lines.append("Ordering cycles:")
    if plan.ordering_cycles:
        lines.append(f"  {_pr_list(plan.ordering_cycles)}")
    else:
        lines.append("  (none)")
    lines.append("Suggested landing batches:")
    if plan.suggested_landing_batches:
        lines.extend(
            f"  {index}: {_pr_list(batch)}"
            for index, batch in enumerate(plan.suggested_landing_batches, start=1)
        )
    else:
        lines.append("  (none)")
    lines.append("Ready landing batches:")
    if plan.ready_landing_batches:
        lines.extend(
            f"  {index}: {_pr_list(batch)}"
            for index, batch in enumerate(plan.ready_landing_batches, start=1)
        )
    else:
        lines.append("  (none)")
    lines.append(f"Ready now: {_pr_list(plan.ready_now)}")
    lines.append("Suggested rebase plan:")
    if plan.suggested_rebase_plan:
        lines.extend(
            f"  #{item.pr} after {_pr_list(item.after)}: {', '.join(item.reasons)}"
            for item in plan.suggested_rebase_plan
        )
    else:
        lines.append("  (none)")
    return "\n".join(lines) + "\n"
