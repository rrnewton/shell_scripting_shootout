import std/[hashes, json]

type
  PrNumber* = distinct int64

  Mergeability* = enum
    mergeable, conflicting, unknown

  ReviewDecision* = enum
    approved, changesRequested, reviewRequired, noReview

  PullRequest* = object
    number*: PrNumber
    title*: string
    author*: string
    hasAuthor*: bool
    headRef*: string
    baseRef*: string
    draft*: bool
    mergeability*: Mergeability
    reviewDecision*: ReviewDecision
    createdAt*: string
    updatedAt*: string
    additions*: int64
    deletions*: int64
    files*: seq[string]
    baseConflictPaths*: seq[string]
    gitHead*: string
    gitBase*: string

  PathEdge* = object
    a*: PrNumber
    b*: PrNumber
    paths*: seq[string]

  AncestryEdge* = object
    before*: PrNumber
    after*: PrNumber

  OrderingEdge* = object
    before*: PrNumber
    after*: PrNumber
    reason*: string

  AnalysisInput* = object
    repository*: string
    prs*: seq[PullRequest]
    conflictEdges*: seq[PathEdge]
    ancestryEdges*: seq[AncestryEdge]

  NormalizedNode* = object
    pr*: PrNumber
    title*: string
    author*: string
    headRef*: string
    baseRef*: string
    draft*: bool
    mergeability*: Mergeability
    reviewDecision*: ReviewDecision
    additions*: int64
    deletions*: int64
    filesCount*: int
    baseConflictPaths*: seq[string]

  HeldPullRequest* = object
    pr*: PrNumber
    reasons*: seq[string]

  RebaseEntry* = object
    pr*: PrNumber
    after*: seq[PrNumber]
    reasons*: seq[string]

  Plan* = object
    repository*: string
    nodes*: seq[NormalizedNode]
    conflictEdges*: seq[PathEdge]
    fileOverlapEdges*: seq[PathEdge]
    orderingEdges*: seq[OrderingEdge]
    stacks*: seq[seq[PrNumber]]
    suggestedLandingBatches*: seq[seq[PrNumber]]
    suggestedRebasePlan*: seq[RebaseEntry]
    readyLandingBatches*: seq[seq[PrNumber]]
    readyNow*: seq[PrNumber]
    heldPrs*: seq[HeldPullRequest]
    orderingCycles*: seq[PrNumber]

proc `==`*(left, right: PrNumber): bool {.borrow.}
proc `<`*(left, right: PrNumber): bool {.borrow.}
proc hash*(number: PrNumber): Hash {.borrow.}
proc `$`*(number: PrNumber): string = $int64(number)

proc mergeabilityText*(value: Mergeability): string =
  case value
  of mergeable: "MERGEABLE"
  of conflicting: "CONFLICTING"
  of unknown: "UNKNOWN"

proc reviewDecisionText*(value: ReviewDecision): string =
  case value
  of approved: "APPROVED"
  of changesRequested: "CHANGES_REQUESTED"
  of reviewRequired: "REVIEW_REQUIRED"
  of noReview: "NONE"

proc jsonNumber(number: PrNumber): JsonNode = %int64(number)

proc jsonNumbers(numbers: openArray[PrNumber]): JsonNode =
  result = newJArray()
  for number in numbers:
    result.add(jsonNumber(number))

proc jsonStrings(values: openArray[string]): JsonNode =
  result = newJArray()
  for value in values:
    result.add(%value)

proc toJson*(edge: PathEdge): JsonNode =
  result = newJObject()
  result["a"] = jsonNumber(edge.a)
  result["b"] = jsonNumber(edge.b)
  result["paths"] = jsonStrings(edge.paths)

proc toJson*(edge: OrderingEdge): JsonNode =
  result = newJObject()
  result["before"] = jsonNumber(edge.before)
  result["after"] = jsonNumber(edge.after)
  result["reason"] = %edge.reason

proc toJson(node: NormalizedNode): JsonNode =
  result = newJObject()
  result["pr"] = jsonNumber(node.pr)
  result["title"] = %node.title
  result["author"] = %node.author
  result["head_ref"] = %node.headRef
  result["base_ref"] = %node.baseRef
  result["draft"] = %node.draft
  result["mergeable"] = %mergeabilityText(node.mergeability)
  result["review_decision"] = %reviewDecisionText(node.reviewDecision)
  result["additions"] = %node.additions
  result["deletions"] = %node.deletions
  result["files_count"] = %node.filesCount
  result["base_conflict_paths"] = jsonStrings(node.baseConflictPaths)

proc toJson(held: HeldPullRequest): JsonNode =
  result = newJObject()
  result["pr"] = jsonNumber(held.pr)
  result["reasons"] = jsonStrings(held.reasons)

proc toJson(entry: RebaseEntry): JsonNode =
  result = newJObject()
  result["pr"] = jsonNumber(entry.pr)
  result["after"] = jsonNumbers(entry.after)
  result["reasons"] = jsonStrings(entry.reasons)

proc toJson*(plan: Plan): JsonNode =
  result = newJObject()
  result["repository"] = %plan.repository

  result["nodes"] = newJArray()
  for node in plan.nodes:
    result["nodes"].add(toJson(node))

  result["conflict_edges"] = newJArray()
  for edge in plan.conflictEdges:
    result["conflict_edges"].add(toJson(edge))

  result["file_overlap_edges"] = newJArray()
  for edge in plan.fileOverlapEdges:
    result["file_overlap_edges"].add(toJson(edge))

  result["ordering_edges"] = newJArray()
  for edge in plan.orderingEdges:
    result["ordering_edges"].add(toJson(edge))

  result["stacks"] = newJArray()
  for stack in plan.stacks:
    result["stacks"].add(jsonNumbers(stack))

  result["suggested_landing_batches"] = newJArray()
  for batch in plan.suggestedLandingBatches:
    result["suggested_landing_batches"].add(jsonNumbers(batch))

  result["suggested_rebase_plan"] = newJArray()
  for entry in plan.suggestedRebasePlan:
    result["suggested_rebase_plan"].add(toJson(entry))

  result["ready_landing_batches"] = newJArray()
  for batch in plan.readyLandingBatches:
    result["ready_landing_batches"].add(jsonNumbers(batch))

  result["ready_now"] = jsonNumbers(plan.readyNow)

  result["held_prs"] = newJArray()
  for held in plan.heldPrs:
    result["held_prs"].add(toJson(held))

  result["ordering_cycles"] = jsonNumbers(plan.orderingCycles)
