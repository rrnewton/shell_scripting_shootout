#!/usr/bin/env python3
"""Language-neutral executable oracle for the PR planning contract."""

from __future__ import annotations

import argparse
import json
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Sequence


@dataclass(frozen=True)
class Ordering:
    before: int
    after: int
    reason: str


def command(args: Sequence[str], cwd: Path, allowed: tuple[int, ...] = (0,)) -> subprocess.CompletedProcess[str]:
    process = subprocess.run(args, cwd=cwd, capture_output=True, text=True, check=False)
    if process.returncode not in allowed:
        detail = process.stderr.strip() or process.stdout.strip()
        raise RuntimeError(f"command failed ({process.returncode}): {' '.join(args)}\n{detail}")
    return process


def merge_tree_paths(repo: Path, left: str, right: str) -> list[str]:
    process = command(
        ["git", "merge-tree", "--write-tree", "--name-only", "--messages", left, right],
        repo,
        (0, 1),
    )
    if process.returncode == 0:
        return []
    lines = process.stdout.splitlines()[1:]
    paths: list[str] = []
    for line in lines:
        path = line.strip()
        if not path:
            break
        paths.append(path)
    return sorted(set(paths))


def is_ancestor(repo: Path, before: str, after: str) -> bool:
    return command(
        ["git", "merge-base", "--is-ancestor", before, after], repo, (0, 1)
    ).returncode == 0


def collect_git(data: dict[str, Any], repo: Path) -> dict[str, Any]:
    analyzed: list[dict[str, Any]] = []
    revisions: dict[int, str] = {}
    for raw in data["prs"]:
        item = dict(raw)
        head = command(["git", "rev-parse", item.pop("git_head")], repo).stdout.strip()
        base = command(["git", "rev-parse", item.pop("git_base")], repo).stdout.strip()
        merge_base = command(["git", "merge-base", base, head], repo).stdout.strip()
        files = command(
            ["git", "diff", "--name-only", f"{merge_base}...{head}"], repo
        ).stdout.splitlines()
        item["files"] = sorted(path for path in files if path)
        item["base_conflict_paths"] = merge_tree_paths(repo, base, head)
        analyzed.append(item)
        revisions[int(item["number"])] = head

    conflicts: list[dict[str, Any]] = []
    ancestry: list[dict[str, int]] = []
    for index, left in enumerate(analyzed):
        for right in analyzed[index + 1 :]:
            left_number = int(left["number"])
            right_number = int(right["number"])
            left_head = revisions[left_number]
            right_head = revisions[right_number]
            paths = merge_tree_paths(repo, left_head, right_head)
            if paths:
                conflicts.append({"a": left_number, "b": right_number, "paths": paths})
            if left_head != right_head and is_ancestor(repo, left_head, right_head):
                ancestry.append({"before": left_number, "after": right_number})
            elif left_head != right_head and is_ancestor(repo, right_head, left_head):
                ancestry.append({"before": right_number, "after": left_number})

    return {
        "schema_version": data["schema_version"],
        "repository": data["repository"],
        "prs": analyzed,
        "conflict_edges": conflicts,
        "ancestry_edges": ancestry,
    }


def has_path(adjacency: dict[int, set[int]], start: int, target: int, skip: tuple[int, int]) -> bool:
    pending = [start]
    seen: set[int] = set()
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


def build_stacks(edges: list[Ordering]) -> list[list[int]]:
    adjacency: dict[int, set[int]] = {}
    for edge in edges:
        adjacency.setdefault(edge.before, set()).add(edge.after)
    reduced = [
        edge
        for edge in edges
        if not has_path(adjacency, edge.before, edge.after, (edge.before, edge.after))
    ]
    children: dict[int, set[int]] = {}
    parents: dict[int, set[int]] = {}
    involved: set[int] = set()
    for edge in reduced:
        children.setdefault(edge.before, set()).add(edge.after)
        parents.setdefault(edge.after, set()).add(edge.before)
        involved.update((edge.before, edge.after))
    stacks: list[list[int]] = []

    def visit(node: int, path: list[int]) -> None:
        descendants = sorted(children.get(node, set()))
        if not descendants:
            if len(path) > 1:
                stacks.append(path)
            return
        for child in descendants:
            if child not in path:
                visit(child, [*path, child])

    for root in sorted(node for node in involved if not parents.get(node)):
        visit(root, [root])
    return stacks


def plan(
    nodes: list[dict[str, Any]],
    conflict_edges: list[dict[str, Any]],
    ordering_edges: list[Ordering],
) -> tuple[list[list[int]], list[dict[str, Any]], list[int]]:
    numbers = {int(node["number"]) for node in nodes}
    by_number = {int(node["number"]): node for node in nodes}
    conflicts = {number: set() for number in numbers}
    predecessors = {number: set() for number in numbers}
    children = {number: set() for number in numbers}
    for edge in conflict_edges:
        a, b = int(edge["a"]), int(edge["b"])
        if a in numbers and b in numbers:
            conflicts[a].add(b)
            conflicts[b].add(a)
    for edge in ordering_edges:
        if edge.before in numbers and edge.after in numbers:
            predecessors[edge.after].add(edge.before)
            children[edge.before].add(edge.after)

    descendant_cache: dict[int, int] = {}

    def descendant_count(number: int) -> int:
        if number in descendant_cache:
            return descendant_cache[number]
        reachable: set[int] = set()
        pending = list(children[number])
        while pending:
            child = pending.pop()
            if child not in reachable:
                reachable.add(child)
                pending.extend(children[child])
        descendant_cache[number] = len(reachable)
        return len(reachable)

    remaining = set(numbers)
    placed: set[int] = set()
    batches: list[list[int]] = []
    cycle_nodes: list[int] = []
    while remaining:
        ready = [number for number in remaining if predecessors[number].issubset(placed)]
        if not ready:
            cycle_nodes = sorted(remaining)
            batches.extend([[number] for number in cycle_nodes])
            break
        ready.sort(
            key=lambda number: (
                -descendant_count(number),
                len(conflicts[number] & remaining),
                int(by_number[number]["additions"]) + int(by_number[number]["deletions"]),
                str(by_number[number]["created_at"]),
                number,
            )
        )
        batch: list[int] = []
        for number in ready:
            if all(peer not in conflicts[number] for peer in batch):
                batch.append(number)
        batches.append(batch)
        remaining.difference_update(batch)
        placed.update(batch)

    batch_of = {number: index for index, batch in enumerate(batches) for number in batch}
    rebases: list[dict[str, Any]] = []
    for number in sorted(numbers, key=lambda item: (batch_of.get(item, 0), item)):
        earlier_conflicts = sorted(
            peer for peer in conflicts[number] if batch_of.get(peer, 0) < batch_of.get(number, 0)
        )
        earlier_dependencies = sorted(
            peer for peer in predecessors[number] if batch_of.get(peer, 0) < batch_of.get(number, 0)
        )
        after = sorted(set(earlier_conflicts + earlier_dependencies))
        reasons: list[str] = []
        if earlier_conflicts:
            reasons.append("pair-conflict")
        if earlier_dependencies:
            reasons.append("stack-dependency")
        if after:
            rebases.append({"pr": number, "after": after, "reasons": reasons})
    return batches, rebases, cycle_nodes


def build_graph(data: dict[str, Any]) -> dict[str, Any]:
    nodes = sorted(data["prs"], key=lambda item: int(item["number"]))
    conflicts = sorted(
        (
            {"a": int(edge["a"]), "b": int(edge["b"]), "paths": sorted(set(edge["paths"]))}
            for edge in data["conflict_edges"]
        ),
        key=lambda edge: (edge["a"], edge["b"]),
    )
    overlaps: list[dict[str, Any]] = []
    for index, left in enumerate(nodes):
        for right in nodes[index + 1 :]:
            paths = sorted(set(left["files"]) & set(right["files"]))
            if paths:
                overlaps.append({"a": int(left["number"]), "b": int(right["number"]), "paths": paths})

    ordering_by_pair: dict[tuple[int, int], Ordering] = {}
    by_head = {str(node["head_ref"]): node for node in nodes}
    for node in nodes:
        predecessor = by_head.get(str(node["base_ref"]))
        if predecessor is not None and predecessor["number"] != node["number"]:
            edge = Ordering(int(predecessor["number"]), int(node["number"]), "base-ref")
            ordering_by_pair[(edge.before, edge.after)] = edge
    for raw in data["ancestry_edges"]:
        edge = Ordering(int(raw["before"]), int(raw["after"]), "ancestry")
        ordering_by_pair.setdefault((edge.before, edge.after), edge)
    ordering = sorted(ordering_by_pair.values(), key=lambda edge: (edge.before, edge.after))

    eventual_batches, eventual_rebases, cycles = plan(nodes, conflicts, ordering)

    held: dict[int, list[str]] = {}
    for node in nodes:
        reasons: list[str] = []
        if node["draft"]:
            reasons.append("draft")
        if node["base_conflict_paths"]:
            reasons.append("local-base-conflict")
        if node["mergeable"] == "CONFLICTING":
            reasons.append("github-base-conflicting")
        if reasons:
            held[int(node["number"])] = reasons
    changed = True
    while changed:
        changed = False
        for edge in ordering:
            if edge.before in held and edge.after not in held:
                held[edge.after] = [f"depends-on-held:#{edge.before}"]
                changed = True

    eligible = [node for node in nodes if int(node["number"]) not in held]
    eligible_numbers = {int(node["number"]) for node in eligible}
    ready_conflicts = [
        edge for edge in conflicts if edge["a"] in eligible_numbers and edge["b"] in eligible_numbers
    ]
    ready_ordering = [
        edge for edge in ordering if edge.before in eligible_numbers and edge.after in eligible_numbers
    ]
    ready_batches, _, _ = plan(eligible, ready_conflicts, ready_ordering)

    normalized_nodes = [
        {
            "pr": int(node["number"]),
            "title": node["title"],
            "author": node["author"] or "unknown",
            "head_ref": node["head_ref"],
            "base_ref": node["base_ref"],
            "draft": bool(node["draft"]),
            "mergeable": node["mergeable"],
            "review_decision": node["review_decision"],
            "additions": int(node["additions"]),
            "deletions": int(node["deletions"]),
            "files_count": len(set(node["files"])),
            "base_conflict_paths": sorted(set(node["base_conflict_paths"])),
        }
        for node in nodes
    ]
    return {
        "repository": data["repository"],
        "nodes": normalized_nodes,
        "conflict_edges": conflicts,
        "file_overlap_edges": overlaps,
        "ordering_edges": [
            {"before": edge.before, "after": edge.after, "reason": edge.reason}
            for edge in ordering
        ],
        "stacks": build_stacks(ordering),
        "suggested_landing_batches": eventual_batches,
        "suggested_rebase_plan": eventual_rebases,
        "ready_landing_batches": ready_batches,
        "ready_now": ready_batches[0] if ready_batches else [],
        "held_prs": [{"pr": number, "reasons": held[number]} for number in sorted(held)],
        "ordering_cycles": cycles,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="mode", required=True)
    for mode in ("pure", "git"):
        subparser = subparsers.add_parser(mode)
        subparser.add_argument("--input", type=Path, required=True)
        subparser.add_argument("--human", action="store_true")
        if mode == "git":
            subparser.add_argument("--git-dir", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    data = json.loads(args.input.read_text(encoding="utf-8"))
    if args.mode == "git":
        data = collect_git(data, args.git_dir)
    graph = build_graph(data)
    if args.human:
        print(
            f"{graph['repository']}: {len(graph['nodes'])} PRs, "
            f"{len(graph['conflict_edges'])} conflicts, ready "
            + ", ".join(f"#{number}" for number in graph["ready_now"])
        )
    else:
        print(json.dumps(graph, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
