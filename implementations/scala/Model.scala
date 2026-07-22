opaque type PrNumber = Int

object PrNumber:
  def apply(value: Int): PrNumber = value
  extension (number: PrNumber)
    def value: Int = number
    def label: String = s"#$number"

opaque type GitRevision = String

object GitRevision:
  def apply(value: String): GitRevision = value
  extension (revision: GitRevision) def value: String = revision

enum Mergeability(val wire: String):
  case Mergeable extends Mergeability("MERGEABLE")
  case Conflicting extends Mergeability("CONFLICTING")
  case Unknown extends Mergeability("UNKNOWN")

object Mergeability:
  def parse(value: String): Option[Mergeability] = values.find(_.wire == value)

enum ReviewDecision(val wire: String):
  case Approved extends ReviewDecision("APPROVED")
  case ChangesRequested extends ReviewDecision("CHANGES_REQUESTED")
  case ReviewRequired extends ReviewDecision("REVIEW_REQUIRED")
  case None extends ReviewDecision("NONE")

object ReviewDecision:
  def parse(value: String): Option[ReviewDecision] = values.find(_.wire == value)

final case class PullRequest(
    number: PrNumber,
    title: String,
    author: Option[String],
    headRef: String,
    baseRef: String,
    draft: Boolean,
    mergeable: Mergeability,
    reviewDecision: ReviewDecision,
    createdAt: String,
    updatedAt: String,
    additions: Int,
    deletions: Int,
    files: Vector[String],
    baseConflictPaths: Vector[String],
    gitHead: Option[GitRevision],
    gitBase: Option[GitRevision]
)

final case class ConflictEdge(a: PrNumber, b: PrNumber, paths: Vector[String])
final case class AncestryEdge(before: PrNumber, after: PrNumber)
final case class OrderingEdge(before: PrNumber, after: PrNumber, reason: String)

final case class AnalysisInput(
    repository: String,
    prs: Vector[PullRequest],
    conflictEdges: Vector[ConflictEdge],
    ancestryEdges: Vector[AncestryEdge]
)

final case class NormalizedNode(
    pr: PrNumber,
    title: String,
    author: String,
    headRef: String,
    baseRef: String,
    draft: Boolean,
    mergeable: Mergeability,
    reviewDecision: ReviewDecision,
    additions: Int,
    deletions: Int,
    filesCount: Int,
    baseConflictPaths: Vector[String]
)

final case class HeldPullRequest(pr: PrNumber, reasons: Vector[String])
final case class RebaseEntry(pr: PrNumber, after: Vector[PrNumber], reasons: Vector[String])

final case class Plan(
    repository: String,
    nodes: Vector[NormalizedNode],
    conflictEdges: Vector[ConflictEdge],
    fileOverlapEdges: Vector[ConflictEdge],
    orderingEdges: Vector[OrderingEdge],
    stacks: Vector[Vector[PrNumber]],
    suggestedLandingBatches: Vector[Vector[PrNumber]],
    suggestedRebasePlan: Vector[RebaseEntry],
    readyLandingBatches: Vector[Vector[PrNumber]],
    readyNow: Vector[PrNumber],
    heldPrs: Vector[HeldPullRequest],
    orderingCycles: Vector[PrNumber]
)
