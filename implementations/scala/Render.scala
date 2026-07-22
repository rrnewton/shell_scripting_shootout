object Render:
  private def number(value: PrNumber): ujson.Value = ujson.Num(value.value)
  private def numbers(values: Vector[PrNumber]): ujson.Value = ujson.Arr.from(values.map(number))
  private def strings(values: Vector[String]): ujson.Value = ujson.Arr.from(values.map(ujson.Str(_)))

  private def conflict(edge: ConflictEdge): ujson.Value = ujson.Obj(
    "a" -> number(edge.a),
    "b" -> number(edge.b),
    "paths" -> strings(edge.paths)
  )

  private def node(value: NormalizedNode): ujson.Value = ujson.Obj(
    "pr" -> number(value.pr),
    "title" -> ujson.Str(value.title),
    "author" -> ujson.Str(value.author),
    "head_ref" -> ujson.Str(value.headRef),
    "base_ref" -> ujson.Str(value.baseRef),
    "draft" -> ujson.Bool(value.draft),
    "mergeable" -> ujson.Str(value.mergeable.wire),
    "review_decision" -> ujson.Str(value.reviewDecision.wire),
    "additions" -> ujson.Num(value.additions),
    "deletions" -> ujson.Num(value.deletions),
    "files_count" -> ujson.Num(value.filesCount),
    "base_conflict_paths" -> strings(value.baseConflictPaths)
  )

  def jsonValue(plan: Plan): ujson.Value = ujson.Obj(
    "repository" -> ujson.Str(plan.repository),
    "nodes" -> ujson.Arr.from(plan.nodes.map(node)),
    "conflict_edges" -> ujson.Arr.from(plan.conflictEdges.map(conflict)),
    "file_overlap_edges" -> ujson.Arr.from(plan.fileOverlapEdges.map(conflict)),
    "ordering_edges" -> ujson.Arr.from(plan.orderingEdges.map { edge =>
      ujson.Obj(
        "before" -> number(edge.before),
        "after" -> number(edge.after),
        "reason" -> ujson.Str(edge.reason)
      )
    }),
    "stacks" -> ujson.Arr.from(plan.stacks.map(numbers)),
    "suggested_landing_batches" -> ujson.Arr.from(plan.suggestedLandingBatches.map(numbers)),
    "suggested_rebase_plan" -> ujson.Arr.from(plan.suggestedRebasePlan.map { entry =>
      ujson.Obj(
        "pr" -> number(entry.pr),
        "after" -> numbers(entry.after),
        "reasons" -> strings(entry.reasons)
      )
    }),
    "ready_landing_batches" -> ujson.Arr.from(plan.readyLandingBatches.map(numbers)),
    "ready_now" -> numbers(plan.readyNow),
    "held_prs" -> ujson.Arr.from(plan.heldPrs.map { entry =>
      ujson.Obj("pr" -> number(entry.pr), "reasons" -> strings(entry.reasons))
    }),
    "ordering_cycles" -> numbers(plan.orderingCycles)
  )

  def json(plan: Plan): String = ujson.write(jsonValue(plan), indent = 2) + "\n"

  private def prList(numbers: Vector[PrNumber]): String =
    if numbers.isEmpty then "(none)" else numbers.map(_.label).mkString(", ")

  def human(plan: Plan): String =
    val output = StringBuilder()
    output.append(s"Repository: ${plan.repository}\n")
    output.append(s"Pull requests: ${plan.nodes.size}\n")
    output.append("Held pull requests:\n")
    if plan.heldPrs.isEmpty then output.append("  (none)\n")
    else plan.heldPrs.foreach(item => output.append(s"  ${item.pr.label}: ${item.reasons.mkString(", ")}\n"))
    output.append("Ordering cycles:\n")
    output.append(s"  ${prList(plan.orderingCycles)}\n")
    output.append("Suggested landing batches:\n")
    if plan.suggestedLandingBatches.isEmpty then output.append("  (none)\n")
    else plan.suggestedLandingBatches.zipWithIndex.foreach { (batch, index) =>
      output.append(s"  ${index + 1}: ${prList(batch)}\n")
    }
    output.append("Ready landing batches:\n")
    if plan.readyLandingBatches.isEmpty then output.append("  (none)\n")
    else plan.readyLandingBatches.zipWithIndex.foreach { (batch, index) =>
      output.append(s"  ${index + 1}: ${prList(batch)}\n")
    }
    output.append(s"Ready now: ${prList(plan.readyNow)}\n")
    output.append("Suggested rebase plan:\n")
    if plan.suggestedRebasePlan.isEmpty then output.append("  (none)\n")
    else plan.suggestedRebasePlan.foreach { item =>
      output.append(s"  ${item.pr.label} after ${prList(item.after)}: ${item.reasons.mkString(", ")}\n")
    }
    output.result()
