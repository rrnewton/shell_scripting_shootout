import scala.collection.mutable

object Planner:
  private def sortedNumbers(numbers: Iterable[PrNumber]): Vector[PrNumber] =
    numbers.toVector.sortBy(_.value)

  private def orderingEdges(input: AnalysisInput): Vector[OrderingEdge] =
    val byHead = input.prs.map(pr => pr.headRef -> pr.number).toMap
    val edges = mutable.Map.empty[(PrNumber, PrNumber), OrderingEdge]
    input.prs.foreach { pr =>
      byHead.get(pr.baseRef).filter(_ != pr.number).foreach { before =>
        edges((before, pr.number)) = OrderingEdge(before, pr.number, "base-ref")
      }
    }
    input.ancestryEdges.foreach { edge =>
      edges.getOrElseUpdate((edge.before, edge.after), OrderingEdge(edge.before, edge.after, "ancestry"))
    }
    edges.values.toVector.sortBy(edge => (edge.before.value, edge.after.value))

  private def fileOverlaps(prs: Vector[PullRequest]): Vector[ConflictEdge] =
    val result = mutable.ArrayBuffer.empty[ConflictEdge]
    for
      leftIndex <- prs.indices
      rightIndex <- (leftIndex + 1) until prs.size
    do
      val left = prs(leftIndex)
      val right = prs(rightIndex)
      val paths = (left.files.toSet intersect right.files.toSet).toVector.sorted
      if paths.nonEmpty then result += ConflictEdge(left.number, right.number, paths)
    result.toVector

  private def hasPath(
      adjacency: Map[PrNumber, Set[PrNumber]],
      start: PrNumber,
      target: PrNumber,
      skip: (PrNumber, PrNumber)
  ): Boolean =
    val pending = mutable.Stack(start)
    val seen = mutable.Set.empty[PrNumber]
    var found = false
    while pending.nonEmpty && !found do
      val current = pending.pop()
      if seen.add(current) then
        adjacency.getOrElse(current, Set.empty).foreach { child =>
          if (current, child) != skip then
            if child == target then found = true
            else pending.push(child)
        }
    found

  private def buildStacks(edges: Vector[OrderingEdge]): Vector[Vector[PrNumber]] =
    val adjacency = edges.groupMap(_.before)(_.after).view.mapValues(_.toSet).toMap
    val reduced = edges.filterNot(edge => hasPath(adjacency, edge.before, edge.after, (edge.before, edge.after)))
    val children = reduced.groupMap(_.before)(_.after).view.mapValues(_.toSet).toMap
    val parents = reduced.groupMap(_.after)(_.before).view.mapValues(_.toSet).toMap
    val involved = reduced.iterator.flatMap(edge => Iterator(edge.before, edge.after)).toSet
    val stacks = mutable.ArrayBuffer.empty[Vector[PrNumber]]
    def visit(node: PrNumber, path: Vector[PrNumber]): Unit =
      val descendants = sortedNumbers(children.getOrElse(node, Set.empty))
      if descendants.isEmpty && path.size > 1 then stacks += path
      else descendants.filterNot(path.contains).foreach(child => visit(child, path :+ child))
    sortedNumbers(involved.filterNot(parents.contains)).foreach(root => visit(root, Vector(root)))
    stacks.toVector

  private def landingBatches(
      prs: Vector[PullRequest],
      ordering: Vector[OrderingEdge],
      conflicts: Vector[ConflictEdge]
  ): (Vector[Vector[PrNumber]], Vector[PrNumber]) =
    val numbers = prs.map(_.number).toSet
    val byNumber = prs.map(pr => pr.number -> pr).toMap
    val conflictsByPr = mutable.Map.from(numbers.map(_ -> mutable.Set.empty[PrNumber]))
    val predecessors = mutable.Map.from(numbers.map(_ -> mutable.Set.empty[PrNumber]))
    val children = mutable.Map.from(numbers.map(_ -> mutable.Set.empty[PrNumber]))
    conflicts.foreach { edge =>
      if numbers.contains(edge.a) && numbers.contains(edge.b) then
        conflictsByPr(edge.a) += edge.b
        conflictsByPr(edge.b) += edge.a
    }
    ordering.foreach { edge =>
      if numbers.contains(edge.before) && numbers.contains(edge.after) then
        predecessors(edge.after) += edge.before
        children(edge.before) += edge.after
    }
    val descendantCache = mutable.Map.empty[PrNumber, Int]
    def descendantCount(number: PrNumber): Int = descendantCache.getOrElseUpdate(
      number, {
        val reachable = mutable.Set.empty[PrNumber]
        val pending = mutable.Stack.from(children(number))
        while pending.nonEmpty do
          val child = pending.pop()
          if reachable.add(child) then pending.pushAll(children(child))
        reachable.size
      }
    )

    val remaining = mutable.Set.from(numbers)
    val placed = mutable.Set.empty[PrNumber]
    val batches = mutable.ArrayBuffer.empty[Vector[PrNumber]]
    var cycles = Vector.empty[PrNumber]
    while remaining.nonEmpty do
      val available = remaining.filter(number => predecessors(number).subsetOf(placed)).toVector
      if available.isEmpty then
        cycles = sortedNumbers(remaining)
        cycles.foreach(number => batches += Vector(number))
        remaining.clear()
      else
        val sorted = available.sortBy { number =>
          val pr = byNumber(number)
          (
            -descendantCount(number),
            conflictsByPr(number).count(remaining.contains),
            pr.additions.toLong + pr.deletions.toLong,
            pr.createdAt,
            number.value
          )
        }
        val batch = mutable.ArrayBuffer.empty[PrNumber]
        sorted.foreach { number =>
          if batch.forall(peer => !conflictsByPr(number).contains(peer)) then batch += number
        }
        batches += batch.toVector
        remaining --= batch
        placed ++= batch
    (batches.toVector, cycles)

  private def rebasePlan(
      batches: Vector[Vector[PrNumber]],
      ordering: Vector[OrderingEdge],
      conflicts: Vector[ConflictEdge]
  ): Vector[RebaseEntry] =
    val batchOf = batches.zipWithIndex.flatMap((batch, index) => batch.map(_ -> index)).toMap
    val dependencies = mutable.Map.empty[PrNumber, mutable.Set[PrNumber]]
    val reasons = mutable.Map.empty[PrNumber, mutable.Set[String]]
    def add(pr: PrNumber, after: PrNumber, reason: String): Unit =
      dependencies.getOrElseUpdate(pr, mutable.Set.empty) += after
      reasons.getOrElseUpdate(pr, mutable.Set.empty) += reason
    ordering.foreach { edge =>
      for
        beforeBatch <- batchOf.get(edge.before)
        afterBatch <- batchOf.get(edge.after)
        if beforeBatch < afterBatch
      do add(edge.after, edge.before, "stack-dependency")
    }
    conflicts.foreach { edge =>
      for
        aBatch <- batchOf.get(edge.a)
        bBatch <- batchOf.get(edge.b)
        if aBatch != bBatch
      do
        if aBatch < bBatch then add(edge.b, edge.a, "pair-conflict")
        else add(edge.a, edge.b, "pair-conflict")
    }
    dependencies.keys.toVector.sortBy(number => (batchOf.getOrElse(number, 0), number.value)).map { number =>
      val numberReasons = reasons(number)
      RebaseEntry(
        number,
        sortedNumbers(dependencies(number)),
        Vector("pair-conflict", "stack-dependency").filter(numberReasons.contains)
      )
    }

  private def heldPullRequests(
      prs: Vector[PullRequest],
      ordering: Vector[OrderingEdge]
  ): Vector[HeldPullRequest] =
    val reasons = mutable.Map.from(prs.map { pr =>
      val values = Vector.newBuilder[String]
      if pr.draft then values += "draft"
      if pr.baseConflictPaths.nonEmpty then values += "local-base-conflict"
      if pr.mergeable == Mergeability.Conflicting then values += "github-base-conflicting"
      pr.number -> values.result()
    })
    var changed = true
    while changed do
      changed = false
      ordering.foreach { edge =>
        if reasons.getOrElse(edge.before, Vector.empty).nonEmpty && reasons.getOrElse(edge.after, Vector.empty).isEmpty then
          reasons(edge.after) = Vector(s"depends-on-held:${edge.before.label}")
          changed = true
      }
    prs.flatMap(pr => reasons(pr.number) match
      case Vector() => None
      case values   => Some(HeldPullRequest(pr.number, values))
    )

  def build(input: AnalysisInput): Plan =
    val prs = input.prs.sortBy(_.number.value)
    val conflicts = input.conflictEdges.sortBy(edge => (edge.a.value, edge.b.value))
    val ordering = orderingEdges(input)
    val held = heldPullRequests(prs, ordering)
    val heldNumbers = held.map(_.pr).toSet
    val (suggested, cycles) = landingBatches(prs, ordering, conflicts)
    val eligible = prs.filterNot(pr => heldNumbers.contains(pr.number))
    val eligibleNumbers = eligible.map(_.number).toSet
    val readyConflicts = conflicts.filter(edge => eligibleNumbers.contains(edge.a) && eligibleNumbers.contains(edge.b))
    val readyOrdering = ordering.filter(edge => eligibleNumbers.contains(edge.before) && eligibleNumbers.contains(edge.after))
    val (ready, _) = landingBatches(eligible, readyOrdering, readyConflicts)
    val nodes = prs.map { pr =>
      NormalizedNode(
        pr.number,
        pr.title,
        pr.author.getOrElse("unknown"),
        pr.headRef,
        pr.baseRef,
        pr.draft,
        pr.mergeable,
        pr.reviewDecision,
        pr.additions,
        pr.deletions,
        pr.files.distinct.size,
        pr.baseConflictPaths.distinct.sorted
      )
    }
    Plan(
      input.repository,
      nodes,
      conflicts,
      fileOverlaps(prs),
      ordering,
      buildStacks(ordering),
      suggested,
      rebasePlan(suggested, ordering, conflicts),
      ready,
      ready.headOption.getOrElse(Vector.empty),
      held,
      cycles
    )
