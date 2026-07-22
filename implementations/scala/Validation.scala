import java.nio.charset.StandardCharsets
import java.nio.file.{Files, Path}
import java.time.Instant
import scala.collection.mutable
import scala.util.{Failure, Success, Try}

final class InputError(message: String) extends RuntimeException(message)

object Validation:
  private val commonPrKeys = Set(
    "additions",
    "author",
    "base_ref",
    "created_at",
    "deletions",
    "draft",
    "head_ref",
    "mergeable",
    "number",
    "review_decision",
    "title",
    "updated_at"
  )
  private val pureRootKeys = Set("schema_version", "repository", "prs", "conflict_edges", "ancestry_edges")
  private val gitRootKeys = Set("schema_version", "repository", "prs")
  private val purePrKeys = commonPrKeys ++ Set("files", "base_conflict_paths")
  private val gitPrKeys = commonPrKeys ++ Set("git_head", "git_base")

  private def fail(path: String, message: String): Nothing =
    throw InputError(s"$path: $message")

  private def asObject(value: ujson.Value, path: String): collection.Map[String, ujson.Value] = value match
    case item: ujson.Obj => item.value
    case _               => fail(path, "expected an object")

  private def asArray(value: ujson.Value, path: String): Vector[ujson.Value] = value match
    case item: ujson.Arr => item.value.toVector
    case _               => fail(path, "expected an array")

  private def exactKeys(item: collection.Map[String, ujson.Value], expected: Set[String], path: String): Unit =
    val missing = (expected -- item.keySet).toVector.sorted
    val unknown = (item.keySet.toSet -- expected).toVector.sorted
    if missing.nonEmpty then fail(path, s"missing field(s): ${missing.mkString(", ")}")
    if unknown.nonEmpty then fail(path, s"unknown field(s): ${unknown.mkString(", ")}")

  private def field(item: collection.Map[String, ujson.Value], name: String, path: String): ujson.Value =
    item.getOrElse(name, fail(path, s"missing field: $name"))

  private def asString(value: ujson.Value, path: String, nonEmpty: Boolean = true): String = value match
    case ujson.Str(result) =>
      if nonEmpty && result.isEmpty then fail(path, "must not be empty")
      if result.indexOf('\u0000') >= 0 then fail(path, "must not contain NUL")
      result
    case _ => fail(path, "expected a string")

  private def asOptionalString(value: ujson.Value, path: String): Option[String] = value match
    case ujson.Null => None
    case other      => Some(asString(other, path))

  private def asInteger(value: ujson.Value, path: String, positive: Boolean): Int = value match
    case ujson.Num(number) if number.isWhole && number >= Int.MinValue && number <= Int.MaxValue =>
      val result = number.toInt
      if positive && result <= 0 then fail(path, "must be positive")
      if !positive && result < 0 then fail(path, "must not be negative")
      result
    case _ => fail(path, "expected an integer")

  private def asBoolean(value: ujson.Value, path: String): Boolean = value match
    case ujson.Bool(result) => result
    case _                  => fail(path, "expected a boolean")

  private def asTimestamp(value: ujson.Value, path: String): String =
    val result = asString(value, path)
    Try(Instant.parse(result)) match
      case Success(_) => result
      case Failure(_) => fail(path, "expected an RFC 3339 timestamp")

  private def asPaths(value: ujson.Value, path: String): Vector[String] =
    val paths = asArray(value, path).zipWithIndex.map { (item, index) =>
      val itemPath = s"$path[$index]"
      val result = asString(item, itemPath)
      if Path.of(result).isAbsolute then fail(itemPath, "expected a repository-relative path")
      result
    }
    if paths.distinct.size != paths.size then fail(path, "paths must be unique")
    paths.sorted

  private def asRevision(value: ujson.Value, path: String): GitRevision =
    val result = asString(value, path)
    if result.startsWith("-") then fail(path, "revision must not start with '-'")
    if result.exists(character => character < ' ' || character == 0x7f.toChar) then
      fail(path, "revision must not contain control characters")
    GitRevision(result)

  private def decodePullRequest(value: ujson.Value, index: Int, mode: String): PullRequest =
    val path = s"$$.prs[$index]"
    val item = asObject(value, path)
    exactKeys(item, if mode == "pure" then purePrKeys else gitPrKeys, path)
    val number = PrNumber(asInteger(field(item, "number", path), s"$path.number", positive = true))
    val mergeableText = asString(field(item, "mergeable", path), s"$path.mergeable")
    val mergeable = Mergeability.parse(mergeableText).getOrElse {
      fail(s"$path.mergeable", "expected one of: CONFLICTING, MERGEABLE, UNKNOWN")
    }
    val reviewText = asString(field(item, "review_decision", path), s"$path.review_decision")
    val review = ReviewDecision.parse(reviewText).getOrElse {
      fail(s"$path.review_decision", "expected one of: APPROVED, CHANGES_REQUESTED, NONE, REVIEW_REQUIRED")
    }
    PullRequest(
      number = number,
      title = asString(field(item, "title", path), s"$path.title"),
      author = asOptionalString(field(item, "author", path), s"$path.author"),
      headRef = asString(field(item, "head_ref", path), s"$path.head_ref"),
      baseRef = asString(field(item, "base_ref", path), s"$path.base_ref"),
      draft = asBoolean(field(item, "draft", path), s"$path.draft"),
      mergeable = mergeable,
      reviewDecision = review,
      createdAt = asTimestamp(field(item, "created_at", path), s"$path.created_at"),
      updatedAt = asTimestamp(field(item, "updated_at", path), s"$path.updated_at"),
      additions = asInteger(field(item, "additions", path), s"$path.additions", positive = false),
      deletions = asInteger(field(item, "deletions", path), s"$path.deletions", positive = false),
      files = if mode == "pure" then asPaths(field(item, "files", path), s"$path.files") else Vector.empty,
      baseConflictPaths =
        if mode == "pure" then asPaths(field(item, "base_conflict_paths", path), s"$path.base_conflict_paths")
        else Vector.empty,
      gitHead = if mode == "git" then Some(asRevision(field(item, "git_head", path), s"$path.git_head")) else None,
      gitBase = if mode == "git" then Some(asRevision(field(item, "git_base", path), s"$path.git_base")) else None
    )

  private def knownNumber(
      value: ujson.Value,
      path: String,
      known: Set[PrNumber]
  ): PrNumber =
    val result = PrNumber(asInteger(value, path, positive = true))
    if !known.contains(result) then fail(path, s"unknown pull request ${result.label}")
    result

  private def decodeConflicts(value: ujson.Value, known: Set[PrNumber]): Vector[ConflictEdge] =
    val seen = mutable.Set.empty[(PrNumber, PrNumber)]
    asArray(value, "$.conflict_edges").zipWithIndex.map { (raw, index) =>
      val path = s"$$.conflict_edges[$index]"
      val item = asObject(raw, path)
      exactKeys(item, Set("a", "b", "paths"), path)
      val rawA = knownNumber(field(item, "a", path), s"$path.a", known)
      val rawB = knownNumber(field(item, "b", path), s"$path.b", known)
      if rawA == rawB then fail(path, "a conflict edge must join two different pull requests")
      val (a, b) = if rawA.value < rawB.value then (rawA, rawB) else (rawB, rawA)
      if !seen.add((a, b)) then fail(path, s"duplicate conflict edge ${a.label}/${b.label}")
      ConflictEdge(a, b, asPaths(field(item, "paths", path), s"$path.paths"))
    }.sortBy(edge => (edge.a.value, edge.b.value))

  private def decodeAncestry(value: ujson.Value, known: Set[PrNumber]): Vector[AncestryEdge] =
    val seen = mutable.Set.empty[(PrNumber, PrNumber)]
    asArray(value, "$.ancestry_edges").zipWithIndex.map { (raw, index) =>
      val path = s"$$.ancestry_edges[$index]"
      val item = asObject(raw, path)
      exactKeys(item, Set("before", "after"), path)
      val before = knownNumber(field(item, "before", path), s"$path.before", known)
      val after = knownNumber(field(item, "after", path), s"$path.after", known)
      if before == after then fail(path, "an ancestry edge must join two different pull requests")
      if !seen.add((before, after)) then fail(path, s"duplicate ancestry edge ${before.label} -> ${after.label}")
      AncestryEdge(before, after)
    }.sortBy(edge => (edge.before.value, edge.after.value))

  def decode(source: String, mode: String): AnalysisInput =
    if mode != "pure" && mode != "git" then throw IllegalArgumentException(s"unsupported mode: $mode")
    val value = Try(ujson.read(source)) match
      case Success(parsed) => parsed
      case Failure(error)  => fail("$", s"invalid JSON: ${error.getMessage}")
    val root = asObject(value, "$")
    exactKeys(root, if mode == "pure" then pureRootKeys else gitRootKeys, "$")
    val version = asInteger(field(root, "schema_version", "$"), "$.schema_version", positive = true)
    if version != 1 then fail("$.schema_version", "only schema version 1 is supported")
    val repository = asString(field(root, "repository", "$"), "$.repository")
    val prs = asArray(field(root, "prs", "$"), "$.prs").zipWithIndex
      .map((raw, index) => decodePullRequest(raw, index, mode))
      .sortBy(_.number.value)
    if prs.map(_.number).distinct.size != prs.size then fail("$.prs", "pull request numbers must be unique")
    if prs.map(_.headRef).distinct.size != prs.size then fail("$.prs", "head_ref values must be unique")
    val known = prs.map(_.number).toSet
    AnalysisInput(
      repository,
      prs,
      if mode == "pure" then decodeConflicts(field(root, "conflict_edges", "$"), known) else Vector.empty,
      if mode == "pure" then decodeAncestry(field(root, "ancestry_edges", "$"), known) else Vector.empty
    )

  def load(path: Path, mode: String): AnalysisInput =
    val source = Try(Files.readString(path, StandardCharsets.UTF_8)) match
      case Success(value) => value
      case Failure(error) => throw InputError(s"$path: ${error.getMessage}")
    try decode(source, mode)
    catch case error: InputError => throw InputError(s"$path: ${error.getMessage}")
