import java.io.{ByteArrayOutputStream, InputStream}
import java.nio.ByteBuffer
import java.nio.charset.{CodingErrorAction, StandardCharsets}
import java.nio.file.{Files, Path}
import java.util.concurrent.TimeUnit
import scala.collection.mutable
import scala.util.{Failure, Success, Try}

final case class CommandResult(status: Int, stdout: Array[Byte], stderr: Array[Byte])
final class GitError(message: String) extends RuntimeException(message)

final class GitRepository private (val path: Path, timeoutSeconds: Long = 30):
  private val blockedEnvironment = Set(
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_COMMON_DIR",
    "GIT_CONFIG_COUNT",
    "GIT_CONFIG_PARAMETERS",
    "GIT_DIR",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_WORK_TREE"
  )

  private def capture(stream: InputStream): (Thread, ByteArrayOutputStream) =
    val output = ByteArrayOutputStream()
    val thread = Thread(
      () => {
        stream.transferTo(output)
        ()
      },
      "pr-plan-git-capture"
    )
    thread.setDaemon(true)
    thread.start()
    (thread, output)

  private def decode(bytes: Array[Byte], description: String): String =
    val decoder = StandardCharsets.UTF_8.newDecoder()
      .onMalformedInput(CodingErrorAction.REPORT)
      .onUnmappableCharacter(CodingErrorAction.REPORT)
    Try(decoder.decode(ByteBuffer.wrap(bytes)).toString) match
      case Success(value) => value
      case Failure(_)     => throw GitError(s"git returned $description that is not valid UTF-8")

  def run(arguments: Seq[String], allowed: Set[Int] = Set(0)): CommandResult =
    if arguments.isEmpty then throw GitError("internal error: empty Git command")
    val command = Seq("git", "-C", path.toString) ++ arguments
    val builder = ProcessBuilder(command*)
    val environment = builder.environment()
    blockedEnvironment.foreach(environment.remove)
    environment.put("GIT_CONFIG_NOSYSTEM", "1")
    environment.put("GIT_CONFIG_GLOBAL", "/dev/null")
    environment.put("GIT_OPTIONAL_LOCKS", "0")
    environment.put("GIT_TERMINAL_PROMPT", "0")
    environment.put("LC_ALL", "C")
    val process = Try(builder.start()) match
      case Success(value) => value
      case Failure(error) => throw GitError(s"could not run git ${arguments.head}: ${error.getMessage}")
    val (stdoutThread, stdout) = capture(process.getInputStream)
    val (stderrThread, stderr) = capture(process.getErrorStream)
    if !process.waitFor(timeoutSeconds, TimeUnit.SECONDS) then
      process.destroyForcibly()
      process.waitFor()
      stdoutThread.join()
      stderrThread.join()
      throw GitError(s"git ${arguments.head} timed out after $timeoutSeconds seconds")
    stdoutThread.join()
    stderrThread.join()
    val result = CommandResult(process.exitValue(), stdout.toByteArray, stderr.toByteArray)
    if !allowed.contains(result.status) then
      val stderrText = decode(result.stderr, "stderr").trim
      val stdoutText = decode(result.stdout, "stdout").trim
      val detail = if stderrText.nonEmpty then stderrText else stdoutText
      val suffix = if detail.nonEmpty then s": $detail" else ""
      throw GitError(s"git ${arguments.head} exited with status ${result.status}$suffix")
    result

  private def commitId(result: CommandResult, command: String): String =
    val value = decode(result.stdout, "stdout").trim.toLowerCase
    if !value.matches("[0-9a-f]{40}|[0-9a-f]{64}") then
      throw GitError(s"git $command returned an invalid commit ID")
    value

  def resolveCommit(revision: GitRevision): String =
    commitId(run(Seq("rev-parse", "--verify", s"${revision.value}^{commit}")), "rev-parse")

  def mergeBase(left: String, right: String): String =
    commitId(run(Seq("merge-base", left, right)), "merge-base")

  private def nulPaths(bytes: Array[Byte]): Vector[String] =
    val paths = mutable.ArrayBuffer.empty[String]
    var start = 0
    var index = 0
    while index <= bytes.length do
      if index == bytes.length || bytes(index) == 0 then
        if index > start then
          val record = java.util.Arrays.copyOfRange(bytes, start, index)
          paths += decode(record, "a path")
        start = index + 1
      index += 1
    paths.distinct.sorted.toVector

  def changedFiles(base: String, head: String): Vector[String] =
    val common = mergeBase(base, head)
    nulPaths(run(Seq("diff", "--name-only", "-z", common, head, "--")).stdout)

  def conflictPaths(left: String, right: String): Vector[String] =
    val result = run(
      Seq("merge-tree", "--write-tree", "--name-only", "--no-messages", "-z", left, right),
      Set(0, 1)
    )
    if result.status == 0 then Vector.empty
    else
      val separator = result.stdout.indexOf(0.toByte)
      if separator < 0 then throw GitError("git merge-tree returned malformed conflict output")
      nulPaths(java.util.Arrays.copyOfRange(result.stdout, separator + 1, result.stdout.length))

  def isAncestor(before: String, after: String): Boolean =
    run(Seq("merge-base", "--is-ancestor", before, after), Set(0, 1)).status == 0

object GitRepository:
  def open(rawPath: Path): GitRepository =
    val path = Try(rawPath.toAbsolutePath.toRealPath()) match
      case Success(value) => value
      case Failure(error) => throw GitError(s"$rawPath: ${error.getMessage}")
    if !Files.isDirectory(path) then throw GitError(s"$rawPath: Git directory must be a directory")
    val repository = GitRepository(path)
    repository.run(Seq("rev-parse", "--git-dir"))
    repository

object GitAnalysis:
  def analyze(input: AnalysisInput, rawPath: Path): AnalysisInput =
    val repository = GitRepository.open(rawPath)
    val heads = mutable.Map.empty[PrNumber, String]
    val analyzed = input.prs.map { pr =>
      val headRevision = pr.gitHead.getOrElse(throw GitError(s"internal error: missing Git head for ${pr.number.label}"))
      val baseRevision = pr.gitBase.getOrElse(throw GitError(s"internal error: missing Git base for ${pr.number.label}"))
      val head = repository.resolveCommit(headRevision)
      val base = repository.resolveCommit(baseRevision)
      heads(pr.number) = head
      pr.copy(
        files = repository.changedFiles(base, head),
        baseConflictPaths = repository.conflictPaths(base, head)
      )
    }
    val conflicts = mutable.ArrayBuffer.empty[ConflictEdge]
    val ancestry = mutable.ArrayBuffer.empty[AncestryEdge]
    for
      leftIndex <- analyzed.indices
      rightIndex <- (leftIndex + 1) until analyzed.size
    do
      val left = analyzed(leftIndex)
      val right = analyzed(rightIndex)
      val leftHead = heads(left.number)
      val rightHead = heads(right.number)
      val paths = repository.conflictPaths(leftHead, rightHead)
      if paths.nonEmpty then conflicts += ConflictEdge(left.number, right.number, paths)
      if leftHead != rightHead then
        if repository.isAncestor(leftHead, rightHead) then ancestry += AncestryEdge(left.number, right.number)
        else if repository.isAncestor(rightHead, leftHead) then ancestry += AncestryEdge(right.number, left.number)
    input.copy(prs = analyzed, conflictEdges = conflicts.toVector, ancestryEdges = ancestry.toVector)
