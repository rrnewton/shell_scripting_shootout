from __future__ import annotations

from pr_plan.model import (
    AnalysisInput,
    ConflictEdge,
    HeldPullRequest,
    OrderingEdge,
    Plan,
    PrNumber,
    PullRequest,
    RebaseEntry,
    RebaseReason,
)


def _ordering_edges(data: AnalysisInput) -> tuple[OrderingEdge, ...]:
    edges: dict[tuple[PrNumber, PrNumber], OrderingEdge] = {}
    by_head = {pr.head_ref: pr.number for pr in data.prs}
    for pr in data.prs:
        parent = by_head.get(pr.base_ref)
        if parent is not None and parent != pr.number:
            edges[(parent, pr.number)] = OrderingEdge(parent, pr.number, "base-ref")
    for before, after in data.ancestry_edges:
        edges.setdefault(
            (before, after), OrderingEdge(before, after, "ancestry")
        )
    return tuple(edge for _, edge in sorted(edges.items()))


def _file_overlaps(prs: tuple[PullRequest, ...]) -> tuple[ConflictEdge, ...]:
    file_sets = {pr.number: set(pr.files) for pr in prs}
    overlaps: list[ConflictEdge] = []
    for left_index, left in enumerate(prs):
        for right in prs[left_index + 1 :]:
            shared = tuple(sorted(file_sets[left.number] & file_sets[right.number]))
            if shared:
                overlaps.append(ConflictEdge(left.number, right.number, shared))
    return tuple(overlaps)


def _has_path(
    adjacency: dict[PrNumber, set[PrNumber]],
    start: PrNumber,
    target: PrNumber,
    skip: tuple[PrNumber, PrNumber],
) -> bool:
    pending = [start]
    seen: set[PrNumber] = set()
    while pending:
        current = pending.pop()
        if current in seen:
            continue
        seen.add(current)
        for child in adjacency.get(current, set()):
            if (current, child) == skip:
                continue
            if child == target:
                return True
            pending.append(child)
    return False


def _stacks(edges: tuple[OrderingEdge, ...]) -> tuple[tuple[PrNumber, ...], ...]:
    adjacency: dict[PrNumber, set[PrNumber]] = {}
    for edge in edges:
        adjacency.setdefault(edge.before, set()).add(edge.after)
    reduced = tuple(
        edge
        for edge in edges
        if not _has_path(
            adjacency, edge.before, edge.after, (edge.before, edge.after)
        )
    )
    children: dict[PrNumber, set[PrNumber]] = {}
    parents: dict[PrNumber, set[PrNumber]] = {}
    involved: set[PrNumber] = set()
    for edge in reduced:
        children.setdefault(edge.before, set()).add(edge.after)
        parents.setdefault(edge.after, set()).add(edge.before)
        involved.update((edge.before, edge.after))

    stacks: list[tuple[PrNumber, ...]] = []
    roots = sorted(number for number in involved if not parents.get(number))
    for root in roots:
        pending: list[tuple[PrNumber, tuple[PrNumber, ...]]] = [(root, (root,))]
        while pending:
            node, path = pending.pop()
            descendants = sorted(children.get(node, set()))
            if not descendants:
                if len(path) > 1:
                    stacks.append(path)
                continue
            for child in reversed(descendants):
                if child not in path:
                    pending.append((child, (*path, child)))
    return tuple(stacks)


def _held_prs(
    prs: tuple[PullRequest, ...], ordering: tuple[OrderingEdge, ...]
) -> tuple[HeldPullRequest, ...]:
    reasons: dict[PrNumber, list[str]] = {pr.number: [] for pr in prs}
    for pr in prs:
        if pr.draft:
            reasons[pr.number].append("draft")
        if pr.base_conflict_paths:
            reasons[pr.number].append("local-base-conflict")
        if pr.mergeable == "CONFLICTING":
            reasons[pr.number].append("github-base-conflicting")

    changed = True
    while changed:
        changed = False
        for edge in ordering:
            if reasons[edge.before] and not reasons[edge.after]:
                reasons[edge.after] = [f"depends-on-held:#{edge.before}"]
                changed = True
    return tuple(
        HeldPullRequest(number, tuple(pr_reasons))
        for number, pr_reasons in sorted(reasons.items())
        if pr_reasons
    )


def _landing_batches(
    prs: tuple[PullRequest, ...],
    ordering: tuple[OrderingEdge, ...],
    conflicts: tuple[ConflictEdge, ...],
) -> tuple[tuple[tuple[PrNumber, ...], ...], tuple[PrNumber, ...]]:
    remaining = {pr.number for pr in prs}
    if not remaining:
        return (), ()
    by_number = {pr.number: pr for pr in prs}
    conflicts_by_pr: dict[PrNumber, set[PrNumber]] = {
        number: set() for number in remaining
    }
    predecessors: dict[PrNumber, set[PrNumber]] = {
        number: set() for number in remaining
    }
    children: dict[PrNumber, set[PrNumber]] = {
        number: set() for number in remaining
    }
    for conflict_edge in conflicts:
        if conflict_edge.a in remaining and conflict_edge.b in remaining:
            conflicts_by_pr[conflict_edge.a].add(conflict_edge.b)
            conflicts_by_pr[conflict_edge.b].add(conflict_edge.a)
    for ordering_edge in ordering:
        if ordering_edge.before in remaining and ordering_edge.after in remaining:
            predecessors[ordering_edge.after].add(ordering_edge.before)
            children[ordering_edge.before].add(ordering_edge.after)

    descendant_cache: dict[PrNumber, int] = {}

    def descendant_count(number: PrNumber) -> int:
        cached = descendant_cache.get(number)
        if cached is not None:
            return cached
        reachable: set[PrNumber] = set()
        pending = list(children[number])
        while pending:
            child = pending.pop()
            if child not in reachable:
                reachable.add(child)
                pending.extend(children[child])
        result = len(reachable)
        descendant_cache[number] = result
        return result

    batches: list[tuple[PrNumber, ...]] = []
    placed: set[PrNumber] = set()
    cycle_nodes: tuple[PrNumber, ...] = ()
    while remaining:
        available = [
            number for number in remaining if predecessors[number].issubset(placed)
        ]
        if not available:
            cycle_nodes = tuple(sorted(remaining))
            batches.extend((number,) for number in cycle_nodes)
            break
        available.sort(
            key=lambda number: (
                -descendant_count(number),
                len(conflicts_by_pr[number] & remaining),
                by_number[number].additions + by_number[number].deletions,
                by_number[number].created_at,
                number,
            )
        )
        batch: list[PrNumber] = []
        for candidate in available:
            if all(selected not in conflicts_by_pr[candidate] for selected in batch):
                batch.append(candidate)
        batches.append(tuple(batch))
        remaining.difference_update(batch)
        placed.update(batch)
    return tuple(batches), cycle_nodes


def _rebase_plan(
    batches: tuple[tuple[PrNumber, ...], ...],
    ordering: tuple[OrderingEdge, ...],
    conflicts: tuple[ConflictEdge, ...],
) -> tuple[RebaseEntry, ...]:
    batch_of = {
        number: batch_index
        for batch_index, batch in enumerate(batches)
        for number in batch
    }
    dependencies: dict[PrNumber, set[PrNumber]] = {}
    reasons: dict[PrNumber, set[RebaseReason]] = {}
    for ordering_edge in ordering:
        if batch_of.get(ordering_edge.before, -1) < batch_of.get(
            ordering_edge.after, -1
        ):
            dependencies.setdefault(ordering_edge.after, set()).add(
                ordering_edge.before
            )
            reasons.setdefault(ordering_edge.after, set()).add("stack-dependency")
    for conflict_edge in conflicts:
        a_batch = batch_of.get(conflict_edge.a)
        b_batch = batch_of.get(conflict_edge.b)
        if a_batch is None or b_batch is None or a_batch == b_batch:
            continue
        earlier, later = (
            (conflict_edge.a, conflict_edge.b)
            if a_batch < b_batch
            else (conflict_edge.b, conflict_edge.a)
        )
        dependencies.setdefault(later, set()).add(earlier)
        reasons.setdefault(later, set()).add("pair-conflict")

    reason_order: dict[RebaseReason, int] = {
        "pair-conflict": 0,
        "stack-dependency": 1,
    }
    return tuple(
        RebaseEntry(
            pr=number,
            after=tuple(sorted(after)),
            reasons=tuple(sorted(reasons[number], key=reason_order.__getitem__)),
        )
        for number, after in sorted(
            dependencies.items(), key=lambda item: (batch_of[item[0]], item[0])
        )
    )


def make_plan(data: AnalysisInput) -> Plan:
    ordering = _ordering_edges(data)
    conflicts = tuple(
        sorted(data.conflict_edges, key=lambda edge: (edge.a, edge.b, edge.paths))
    )
    held = _held_prs(data.prs, ordering)
    held_numbers = {item.pr for item in held}
    suggested_batches, ordering_cycles = _landing_batches(data.prs, ordering, conflicts)
    ready_prs = tuple(pr for pr in data.prs if pr.number not in held_numbers)
    ready_batches, _ = _landing_batches(ready_prs, ordering, conflicts)
    return Plan(
        repository=data.repository,
        nodes=data.prs,
        conflict_edges=conflicts,
        file_overlap_edges=_file_overlaps(data.prs),
        ordering_edges=ordering,
        stacks=_stacks(ordering),
        suggested_landing_batches=suggested_batches,
        suggested_rebase_plan=_rebase_plan(suggested_batches, ordering, conflicts),
        ready_landing_batches=ready_batches,
        ready_now=ready_batches[0] if ready_batches else (),
        held_prs=held,
        ordering_cycles=ordering_cycles,
    )
