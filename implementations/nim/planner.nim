import std/[algorithm, sets, tables]

import model

type
  NumberSet = HashSet[PrNumber]
  PrPair = tuple[first: PrNumber, second: PrNumber]

proc sortedNumbers(numbers: NumberSet): seq[PrNumber] =
  for number in numbers:
    result.add(number)
  result.sort()

proc orderingEdges(data: AnalysisInput): seq[OrderingEdge] =
  var byHead = initTable[string, PrNumber]()
  var edges = initTable[PrPair, OrderingEdge]()
  for pr in data.prs:
    byHead[pr.headRef] = pr.number
  for pr in data.prs:
    if byHead.hasKey(pr.baseRef):
      let parent = byHead[pr.baseRef]
      if parent != pr.number:
        edges[(parent, pr.number)] = OrderingEdge(
          before: parent, after: pr.number, reason: "base-ref")
  for edge in data.ancestryEdges:
    let pair = (edge.before, edge.after)
    if not edges.hasKey(pair):
      edges[pair] = OrderingEdge(
        before: edge.before, after: edge.after, reason: "ancestry")
  for _, edge in edges:
    result.add(edge)
  result.sort(proc(left, right: OrderingEdge): int =
    result = cmp(left.before, right.before)
    if result == 0: result = cmp(left.after, right.after))

proc fileOverlaps(prs: openArray[PullRequest]): seq[PathEdge] =
  var fileSets = initTable[PrNumber, HashSet[string]]()
  for pr in prs:
    fileSets[pr.number] = pr.files.toHashSet()
  for leftIndex in 0 ..< prs.len:
    for rightIndex in leftIndex + 1 ..< prs.len:
      let left = prs[leftIndex]
      let right = prs[rightIndex]
      var paths: seq[string]
      for path in fileSets[left.number]:
        if path in fileSets[right.number]:
          paths.add(path)
      if paths.len > 0:
        paths.sort()
        result.add(PathEdge(a: left.number, b: right.number, paths: paths))

proc getSet(table: var Table[PrNumber, NumberSet], number: PrNumber): var NumberSet =
  table.mgetOrPut(number, initHashSet[PrNumber]())

proc hasPath(adjacency: Table[PrNumber, NumberSet], start, target: PrNumber,
    skip: PrPair): bool =
  var pending = @[start]
  var seen = initHashSet[PrNumber]()
  while pending.len > 0:
    let current = pending.pop()
    if current in seen:
      continue
    seen.incl(current)
    if adjacency.hasKey(current):
      for child in adjacency[current]:
        if current == skip.first and child == skip.second:
          continue
        if child == target:
          return true
        pending.add(child)

proc buildStacks(edges: openArray[OrderingEdge]): seq[seq[PrNumber]] =
  var stacks: seq[seq[PrNumber]]
  var adjacency = initTable[PrNumber, NumberSet]()
  for edge in edges:
    adjacency.getSet(edge.before).incl(edge.after)

  var reduced: seq[OrderingEdge]
  for edge in edges:
    if not hasPath(adjacency, edge.before, edge.after, (edge.before, edge.after)):
      reduced.add(edge)

  var children = initTable[PrNumber, NumberSet]()
  var parents = initTable[PrNumber, NumberSet]()
  var involved = initHashSet[PrNumber]()
  for edge in reduced:
    children.getSet(edge.before).incl(edge.after)
    parents.getSet(edge.after).incl(edge.before)
    involved.incl(edge.before)
    involved.incl(edge.after)

  proc visit(node: PrNumber, path: seq[PrNumber]) =
    let descendants = if children.hasKey(node):
        sortedNumbers(children[node])
      else:
        newSeq[PrNumber]()
    if descendants.len == 0:
      if path.len > 1:
        stacks.add(path)
      return
    for child in descendants:
      if child notin path:
        visit(child, path & child)

  for root in sortedNumbers(involved):
    if not parents.hasKey(root) or parents[root].len == 0:
      visit(root, @[root])
  result = stacks

proc heldPullRequests(prs: openArray[PullRequest],
    ordering: openArray[OrderingEdge]): seq[HeldPullRequest] =
  var reasons = initTable[PrNumber, seq[string]]()
  for pr in prs:
    var prReasons: seq[string]
    if pr.draft:
      prReasons.add("draft")
    if pr.baseConflictPaths.len > 0:
      prReasons.add("local-base-conflict")
    if pr.mergeability == conflicting:
      prReasons.add("github-base-conflicting")
    reasons[pr.number] = prReasons

  var changed = true
  while changed:
    changed = false
    for edge in ordering:
      if reasons[edge.before].len > 0 and reasons[edge.after].len == 0:
        reasons[edge.after] = @["depends-on-held:#" & $edge.before]
        changed = true
  for pr in prs:
    if reasons[pr.number].len > 0:
      result.add(HeldPullRequest(pr: pr.number, reasons: reasons[pr.number]))

proc landingBatches(prs: openArray[PullRequest], ordering: openArray[OrderingEdge],
    conflicts: openArray[PathEdge]): tuple[batches: seq[seq[PrNumber]],
      cycles: seq[PrNumber]] =
  var remaining = initHashSet[PrNumber]()
  var placed = initHashSet[PrNumber]()
  var byNumber = initTable[PrNumber, PullRequest]()
  var conflictsByPr = initTable[PrNumber, NumberSet]()
  var predecessors = initTable[PrNumber, NumberSet]()
  var children = initTable[PrNumber, NumberSet]()
  for pr in prs:
    remaining.incl(pr.number)
    byNumber[pr.number] = pr
    conflictsByPr[pr.number] = initHashSet[PrNumber]()
    predecessors[pr.number] = initHashSet[PrNumber]()
    children[pr.number] = initHashSet[PrNumber]()
  for edge in conflicts:
    if edge.a in remaining and edge.b in remaining:
      conflictsByPr[edge.a].incl(edge.b)
      conflictsByPr[edge.b].incl(edge.a)
  for edge in ordering:
    if edge.before in remaining and edge.after in remaining:
      predecessors[edge.after].incl(edge.before)
      children[edge.before].incl(edge.after)

  var descendantCache = initTable[PrNumber, int]()
  proc descendantCount(number: PrNumber): int =
    if descendantCache.hasKey(number):
      return descendantCache[number]
    var reachable = initHashSet[PrNumber]()
    var pending = sortedNumbers(children[number])
    while pending.len > 0:
      let child = pending.pop()
      if child notin reachable:
        reachable.incl(child)
        pending.add(sortedNumbers(children[child]))
    descendantCache[number] = reachable.len
    reachable.len

  while remaining.len > 0:
    var available: seq[PrNumber]
    for number in remaining:
      var ready = true
      for predecessor in predecessors[number]:
        if predecessor notin placed:
          ready = false
          break
      if ready:
        available.add(number)
    if available.len == 0:
      result.cycles = sortedNumbers(remaining)
      for number in result.cycles:
        result.batches.add(@[number])
      break

    available.sort(proc(left, right: PrNumber): int =
      result = cmp(descendantCount(right), descendantCount(left))
      if result != 0: return
      var leftConflicts = 0
      var rightConflicts = 0
      for peer in conflictsByPr[left]:
        if peer in remaining: inc(leftConflicts)
      for peer in conflictsByPr[right]:
        if peer in remaining: inc(rightConflicts)
      result = cmp(leftConflicts, rightConflicts)
      if result != 0: return
      let leftSize = uint64(byNumber[left].additions) + uint64(byNumber[left].deletions)
      let rightSize = uint64(byNumber[right].additions) + uint64(byNumber[right].deletions)
      result = cmp(leftSize, rightSize)
      if result != 0: return
      result = cmp(byNumber[left].createdAt, byNumber[right].createdAt)
      if result != 0: return
      result = cmp(left, right))

    var batch: seq[PrNumber]
    for candidate in available:
      var compatible = true
      for selected in batch:
        if selected in conflictsByPr[candidate]:
          compatible = false
          break
      if compatible:
        batch.add(candidate)
    result.batches.add(batch)
    for number in batch:
      remaining.excl(number)
      placed.incl(number)

proc rebasePlan(batches: openArray[seq[PrNumber]],
    ordering: openArray[OrderingEdge],
    conflicts: openArray[PathEdge]): seq[RebaseEntry] =
  var batchOf = initTable[PrNumber, int]()
  var dependencies = initTable[PrNumber, NumberSet]()
  var reasons = initTable[PrNumber, HashSet[string]]()
  for index, batch in batches:
    for number in batch:
      batchOf[number] = index

  proc add(pr, after: PrNumber, reason: string) =
    dependencies.mgetOrPut(pr, initHashSet[PrNumber]()).incl(after)
    reasons.mgetOrPut(pr, initHashSet[string]()).incl(reason)

  for edge in ordering:
    if batchOf.hasKey(edge.before) and batchOf.hasKey(edge.after) and
        batchOf[edge.before] < batchOf[edge.after]:
      add(edge.after, edge.before, "stack-dependency")
  for edge in conflicts:
    if not batchOf.hasKey(edge.a) or not batchOf.hasKey(edge.b) or
        batchOf[edge.a] == batchOf[edge.b]:
      continue
    if batchOf[edge.a] < batchOf[edge.b]:
      add(edge.b, edge.a, "pair-conflict")
    else:
      add(edge.a, edge.b, "pair-conflict")

  var numbers: seq[PrNumber]
  for number, _ in dependencies:
    numbers.add(number)
  numbers.sort(proc(left, right: PrNumber): int =
    result = cmp(batchOf[left], batchOf[right])
    if result == 0: result = cmp(left, right))
  for number in numbers:
    var entryReasons: seq[string]
    if "pair-conflict" in reasons[number]:
      entryReasons.add("pair-conflict")
    if "stack-dependency" in reasons[number]:
      entryReasons.add("stack-dependency")
    result.add(RebaseEntry(pr: number,
      after: sortedNumbers(dependencies[number]), reasons: entryReasons))

proc makePlan*(data: AnalysisInput): Plan =
  result.repository = data.repository
  result.orderingEdges = orderingEdges(data)
  result.conflictEdges = data.conflictEdges
  result.conflictEdges.sort(proc(left, right: PathEdge): int =
    result = cmp(left.a, right.a)
    if result == 0: result = cmp(left.b, right.b))
  result.fileOverlapEdges = fileOverlaps(data.prs)
  result.heldPrs = heldPullRequests(data.prs, result.orderingEdges)

  var held = initHashSet[PrNumber]()
  for item in result.heldPrs:
    held.incl(item.pr)
  var readyPrs: seq[PullRequest]
  for pr in data.prs:
    let author = if pr.hasAuthor: pr.author else: "unknown"
    result.nodes.add(NormalizedNode(
      pr: pr.number, title: pr.title, author: author, headRef: pr.headRef,
      baseRef: pr.baseRef, draft: pr.draft, mergeability: pr.mergeability,
      reviewDecision: pr.reviewDecision, additions: pr.additions,
      deletions: pr.deletions, filesCount: pr.files.len,
      baseConflictPaths: pr.baseConflictPaths))
    if pr.number notin held:
      readyPrs.add(pr)

  let suggested = landingBatches(data.prs, result.orderingEdges,
    result.conflictEdges)
  result.suggestedLandingBatches = suggested.batches
  result.orderingCycles = suggested.cycles
  result.suggestedRebasePlan = rebasePlan(result.suggestedLandingBatches,
    result.orderingEdges, result.conflictEdges)
  result.stacks = buildStacks(result.orderingEdges)

  let ready = landingBatches(readyPrs, result.orderingEdges, result.conflictEdges)
  result.readyLandingBatches = ready.batches
  if result.readyLandingBatches.len > 0:
    result.readyNow = result.readyLandingBatches[0]
