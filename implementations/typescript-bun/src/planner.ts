import { normalizeConflictEdge, normalizeNode } from "./schema.ts";
import type {
  ConflictEdge,
  HeldPr,
  NormalizedPrNode,
  OrderingEdge,
  Plan,
  PlanningInput,
  PrNode,
  PrNumber,
  RebaseStep,
} from "./types.ts";

interface BatchPlan {
  readonly batches: readonly (readonly PrNumber[])[];
  readonly rebases: readonly RebaseStep[];
  readonly cycles: readonly PrNumber[];
}

const byNumber = (a: PrNode, b: PrNode): number => a.number - b.number;
const byEdge = (a: ConflictEdge, b: ConflictEdge): number => a.a - b.a || a.b - b.b;
const byOrdering = (a: OrderingEdge, b: OrderingEdge): number =>
  a.before - b.before || a.after - b.after;

export function buildPlan(input: PlanningInput): Plan {
  const nodes = input.nodes.map(normalizeNode).sort(byNumber);
  const conflicts = input.conflictEdges.map(normalizeConflictEdge).sort(byEdge);
  const ordering = buildOrdering(nodes, input.ancestryEdges);
  const eventual = planBatches(nodes, conflicts, ordering);
  const held = findHeld(nodes, ordering);
  const heldNumbers = new Set(held.map((entry) => entry.pr));
  const eligible = nodes.filter((node) => !heldNumbers.has(node.number));
  const eligibleNumbers = new Set(eligible.map((node) => node.number));
  const ready = planBatches(
    eligible,
    conflicts.filter((edge) => eligibleNumbers.has(edge.a) && eligibleNumbers.has(edge.b)),
    ordering.filter((edge) => eligibleNumbers.has(edge.before) && eligibleNumbers.has(edge.after)),
  );

  return {
    repository: input.repository,
    nodes: nodes.map(normalizeOutputNode),
    conflict_edges: conflicts,
    file_overlap_edges: findOverlaps(nodes),
    ordering_edges: ordering,
    stacks: buildStacks(ordering),
    suggested_landing_batches: eventual.batches,
    suggested_rebase_plan: eventual.rebases,
    ready_landing_batches: ready.batches,
    ready_now: ready.batches[0] ?? [],
    held_prs: held,
    ordering_cycles: eventual.cycles,
  };
}

function normalizeOutputNode(node: PrNode): NormalizedPrNode {
  return {
    pr: node.number,
    title: node.title,
    author: node.author ?? "unknown",
    head_ref: node.head_ref,
    base_ref: node.base_ref,
    draft: node.draft,
    mergeable: node.mergeable,
    review_decision: node.review_decision,
    additions: node.additions,
    deletions: node.deletions,
    files_count: new Set(node.files).size,
    base_conflict_paths: node.base_conflict_paths,
  };
}

function findOverlaps(nodes: readonly PrNode[]): ConflictEdge[] {
  const result: ConflictEdge[] = [];
  for (let leftIndex = 0; leftIndex < nodes.length; leftIndex += 1) {
    const left = nodes[leftIndex];
    if (left === undefined) continue;
    const leftFiles = new Set(left.files);
    for (let rightIndex = leftIndex + 1; rightIndex < nodes.length; rightIndex += 1) {
      const right = nodes[rightIndex];
      if (right === undefined) continue;
      const paths = right.files.filter((path) => leftFiles.has(path));
      if (paths.length > 0) result.push({ a: left.number, b: right.number, paths });
    }
  }
  return result;
}

function buildOrdering(
  nodes: readonly PrNode[],
  ancestryEdges: PlanningInput["ancestryEdges"],
): OrderingEdge[] {
  const byHead = new Map(nodes.map((node) => [node.head_ref, node] as const));
  const byPair = new Map<string, OrderingEdge>();
  for (const node of nodes) {
    const predecessor = byHead.get(node.base_ref);
    if (predecessor !== undefined && predecessor.number !== node.number) {
      const edge: OrderingEdge = {
        before: predecessor.number,
        after: node.number,
        reason: "base-ref",
      };
      byPair.set(`${edge.before}>${edge.after}`, edge);
    }
  }
  for (const edge of ancestryEdges) {
    const key = `${edge.before}>${edge.after}`;
    if (!byPair.has(key)) byPair.set(key, { ...edge, reason: "ancestry" });
  }
  return [...byPair.values()].sort(byOrdering);
}

function planBatches(
  nodes: readonly PrNode[],
  conflictEdges: readonly ConflictEdge[],
  orderingEdges: readonly OrderingEdge[],
): BatchPlan {
  const numbers = new Set(nodes.map((node) => node.number));
  const nodeByNumber = new Map(nodes.map((node) => [node.number, node] as const));
  const conflicts = setMap(numbers);
  const predecessors = setMap(numbers);
  const children = setMap(numbers);
  for (const edge of conflictEdges) {
    if (numbers.has(edge.a) && numbers.has(edge.b)) {
      required(conflicts, edge.a).add(edge.b);
      required(conflicts, edge.b).add(edge.a);
    }
  }
  for (const edge of orderingEdges) {
    if (numbers.has(edge.before) && numbers.has(edge.after)) {
      required(predecessors, edge.after).add(edge.before);
      required(children, edge.before).add(edge.after);
    }
  }

  const descendantCounts = new Map<PrNumber, number>();
  const descendantCount = (number: PrNumber): number => {
    const cached = descendantCounts.get(number);
    if (cached !== undefined) return cached;
    const reachable = new Set<PrNumber>();
    const pending = [...required(children, number)];
    while (pending.length > 0) {
      const child = pending.pop();
      if (child !== undefined && !reachable.has(child)) {
        reachable.add(child);
        pending.push(...required(children, child));
      }
    }
    descendantCounts.set(number, reachable.size);
    return reachable.size;
  };

  const remaining = new Set(numbers);
  const placed = new Set<PrNumber>();
  const batches: PrNumber[][] = [];
  let cycles: PrNumber[] = [];
  while (remaining.size > 0) {
    const ready = [...remaining].filter((number) => isSubset(required(predecessors, number), placed));
    if (ready.length === 0) {
      cycles = [...remaining].sort((a, b) => a - b);
      batches.push(...cycles.map((number) => [number]));
      break;
    }
    ready.sort((left, right) => {
      const leftNode = required(nodeByNumber, left);
      const rightNode = required(nodeByNumber, right);
      return (
        descendantCount(right) - descendantCount(left) ||
        countIntersection(required(conflicts, left), remaining) -
          countIntersection(required(conflicts, right), remaining) ||
        leftNode.additions + leftNode.deletions - (rightNode.additions + rightNode.deletions) ||
        compareText(leftNode.created_at, rightNode.created_at) ||
        left - right
      );
    });
    const batch: PrNumber[] = [];
    for (const number of ready) {
      if (batch.every((peer) => !required(conflicts, number).has(peer))) batch.push(number);
    }
    for (const number of batch) {
      remaining.delete(number);
      placed.add(number);
    }
    batches.push(batch);
  }

  const batchOf = new Map<PrNumber, number>();
  for (const [index, batch] of batches.entries()) {
    for (const number of batch) batchOf.set(number, index);
  }
  const rebases: RebaseStep[] = [];
  const rebaseOrder = [...numbers].sort(
    (left, right) => (batchOf.get(left) ?? 0) - (batchOf.get(right) ?? 0) || left - right,
  );
  for (const number of rebaseOrder) {
    const currentBatch = batchOf.get(number) ?? 0;
    const earlierConflicts = [...required(conflicts, number)]
      .filter((peer) => (batchOf.get(peer) ?? 0) < currentBatch)
      .sort((a, b) => a - b);
    const earlierDependencies = [...required(predecessors, number)]
      .filter((peer) => (batchOf.get(peer) ?? 0) < currentBatch)
      .sort((a, b) => a - b);
    const after = [...new Set([...earlierConflicts, ...earlierDependencies])].sort((a, b) => a - b);
    const reasons: RebaseStep["reasons"][number][] = [];
    if (earlierConflicts.length > 0) reasons.push("pair-conflict");
    if (earlierDependencies.length > 0) reasons.push("stack-dependency");
    if (after.length > 0) rebases.push({ pr: number, after, reasons });
  }
  return { batches, rebases, cycles };
}

function buildStacks(edges: readonly OrderingEdge[]): PrNumber[][] {
  const adjacency = new Map<PrNumber, Set<PrNumber>>();
  for (const edge of edges) addToSet(adjacency, edge.before, edge.after);
  const reduced = edges.filter(
    (edge) => !hasPath(adjacency, edge.before, edge.after, `${edge.before}>${edge.after}`),
  );
  const children = new Map<PrNumber, Set<PrNumber>>();
  const parents = new Map<PrNumber, Set<PrNumber>>();
  const involved = new Set<PrNumber>();
  for (const edge of reduced) {
    addToSet(children, edge.before, edge.after);
    addToSet(parents, edge.after, edge.before);
    involved.add(edge.before);
    involved.add(edge.after);
  }
  const stacks: PrNumber[][] = [];
  const visit = (node: PrNumber, path: readonly PrNumber[]): void => {
    const descendants = [...(children.get(node) ?? [])].sort((a, b) => a - b);
    if (descendants.length === 0) {
      if (path.length > 1) stacks.push([...path]);
      return;
    }
    for (const child of descendants) {
      if (!path.includes(child)) visit(child, [...path, child]);
    }
  };
  const roots = [...involved]
    .filter((number) => (parents.get(number)?.size ?? 0) === 0)
    .sort((a, b) => a - b);
  for (const root of roots) visit(root, [root]);
  return stacks;
}

function hasPath(
  adjacency: ReadonlyMap<PrNumber, ReadonlySet<PrNumber>>,
  start: PrNumber,
  target: PrNumber,
  skippedEdge: string,
): boolean {
  const pending = [start];
  const seen = new Set<PrNumber>();
  while (pending.length > 0) {
    const current = pending.pop();
    if (current === undefined || seen.has(current)) continue;
    seen.add(current);
    for (const child of adjacency.get(current) ?? []) {
      if (`${current}>${child}` === skippedEdge) continue;
      if (child === target) return true;
      pending.push(child);
    }
  }
  return false;
}

function findHeld(nodes: readonly PrNode[], ordering: readonly OrderingEdge[]): HeldPr[] {
  const held = new Map<PrNumber, string[]>();
  for (const node of nodes) {
    const reasons: string[] = [];
    if (node.draft) reasons.push("draft");
    if (node.base_conflict_paths.length > 0) reasons.push("local-base-conflict");
    if (node.mergeable === "CONFLICTING") reasons.push("github-base-conflicting");
    if (reasons.length > 0) held.set(node.number, reasons);
  }
  let changed = true;
  while (changed) {
    changed = false;
    for (const edge of ordering) {
      if (held.has(edge.before) && !held.has(edge.after)) {
        held.set(edge.after, [`depends-on-held:#${edge.before}`]);
        changed = true;
      }
    }
  }
  return [...held]
    .sort(([left], [right]) => left - right)
    .map(([pr, reasons]) => ({ pr, reasons }));
}

function setMap(numbers: ReadonlySet<PrNumber>): Map<PrNumber, Set<PrNumber>> {
  return new Map([...numbers].map((number): [PrNumber, Set<PrNumber>] => [number, new Set()]));
}

function addToSet<K, V>(map: Map<K, Set<V>>, key: K, value: V): void {
  const existing = map.get(key);
  if (existing === undefined) map.set(key, new Set([value]));
  else existing.add(value);
}

function countIntersection<T>(left: ReadonlySet<T>, right: ReadonlySet<T>): number {
  let count = 0;
  for (const value of left) if (right.has(value)) count += 1;
  return count;
}

function isSubset<T>(subset: ReadonlySet<T>, superset: ReadonlySet<T>): boolean {
  for (const value of subset) if (!superset.has(value)) return false;
  return true;
}

function required<K, V>(map: ReadonlyMap<K, V>, key: K): V {
  const value = map.get(key);
  if (value === undefined) throw new Error("internal planner invariant failed");
  return value;
}

function compareText(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0;
}
