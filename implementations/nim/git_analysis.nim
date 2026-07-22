import std/[algorithm, monotimes, os, osproc, posix, sets, strtabs,
  strutils, times, unicode, tables]

import model

type
  GitError* = object of CatchableError

  CommandResult = object
    status: int
    stdout: string
    stderr: string

  GitRepository = object
    path: string
    executable: string

const blockedGitEnvironment = [
  "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_COMMON_DIR", "GIT_CONFIG_COUNT",
  "GIT_CONFIG_PARAMETERS", "GIT_DIR", "GIT_EDITOR", "GIT_EXEC_PATH",
  "GIT_EXTERNAL_DIFF", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_PAGER",
  "GIT_SEQUENCE_EDITOR", "GIT_SSH", "GIT_SSH_COMMAND", "GIT_WORK_TREE"
]

proc gitError(message: string): ref GitError =
  newException(GitError, message)

proc gitEnvironment(): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  let blocked = blockedGitEnvironment.toHashSet()
  for name, value in envPairs():
    if name notin blocked:
      result[name] = value
  result["GIT_CONFIG_NOSYSTEM"] = "1"
  result["GIT_CONFIG_GLOBAL"] = "/dev/null"
  result["GIT_CONFIG_COUNT"] = "0"
  result["GIT_OPTIONAL_LOCKS"] = "0"
  result["GIT_TERMINAL_PROMPT"] = "0"
  result["LC_ALL"] = "C"

proc readAvailable(handle: FileHandle, destination: var string): bool =
  var buffer: array[8192, char]
  while true:
    let count = posix.read(cint(handle), addr buffer[0], buffer.len)
    if count > 0:
      let previousLength = destination.len
      destination.setLen(previousLength + int(count))
      copyMem(addr destination[previousLength], addr buffer[0], int(count))
      return true
    if count == 0:
      return false
    if errno == EINTR:
      continue
    if errno == EAGAIN or errno == EWOULDBLOCK:
      return true
    raiseOSError(osLastError())

proc capture(command: string, arguments: seq[string],
    environment: StringTableRef): CommandResult =
  var process: Process
  try:
    process = startProcess(command, args = arguments, env = environment,
      options = {})
  except OSError, IOError:
    raise gitError("could not run git: " & getCurrentExceptionMsg())
  defer: process.close()

  var stdoutOpen = true
  var stderrOpen = true
  let deadline = getMonoTime() + initDuration(seconds = 30)
  while stdoutOpen or stderrOpen:
    if getMonoTime() >= deadline:
      process.terminate()
      discard process.waitForExit(500)
      raise gitError("git command timed out after 30 seconds")
    var descriptors = [
      TPollfd(fd: if stdoutOpen: cint(process.outputHandle()) else: -1,
        events: POLLIN),
      TPollfd(fd: if stderrOpen: cint(process.errorHandle()) else: -1,
        events: POLLIN)
    ]
    let ready = posix.poll(addr descriptors[0], Tnfds(descriptors.len), 100)
    if ready < 0:
      if errno == EINTR:
        continue
      raiseOSError(osLastError())
    if stdoutOpen and
        (descriptors[0].revents and (POLLIN or POLLHUP or POLLERR)) != 0:
      stdoutOpen = readAvailable(process.outputHandle(), result.stdout)
    if stderrOpen and
        (descriptors[1].revents and (POLLIN or POLLHUP or POLLERR)) != 0:
      stderrOpen = readAvailable(process.errorHandle(), result.stderr)
  result.status = process.waitForExit()

proc run(repository: GitRepository, arguments: seq[string],
    allowed: openArray[int] = [0]): CommandResult =
  if arguments.len == 0:
    raise gitError("internal error: empty Git command")
  result = capture(repository.executable, @["-C", repository.path] & arguments,
    gitEnvironment())
  if result.status notin allowed:
    var detail = result.stderr.strip()
    if detail.len == 0:
      detail = result.stdout.strip()
    let suffix = if detail.len == 0: "" else: ": " & detail
    raise gitError("git " & arguments[0] & " exited with status " &
      $result.status & suffix)

proc openGitRepository(path: string): GitRepository =
  try:
    result.path = expandFilename(path)
  except OSError:
    raise gitError(path & ": " & getCurrentExceptionMsg())
  if not dirExists(result.path):
    raise gitError(path & ": Git directory must be a directory")
  result.executable = findExe("git")
  if result.executable.len == 0:
    raise gitError("could not find git on PATH")
  discard result.run(@["rev-parse", "--git-dir"])

proc validObjectId(value: string): bool =
  if value.len notin [40, 64]:
    return false
  for character in value:
    if character notin {'0'..'9', 'a'..'f', 'A'..'F'}:
      return false
  true

proc resolveCommit(repository: GitRepository, revision: string): string =
  let command = repository.run(@["rev-parse", "--verify", revision & "^{commit}"])
  result = command.stdout.strip().toLowerAscii()
  if not validObjectId(result):
    raise gitError("git rev-parse returned an invalid commit ID")

proc mergeBase(repository: GitRepository, left, right: string): string =
  let command = repository.run(@["merge-base", left, right])
  result = command.stdout.strip().toLowerAscii()
  if not validObjectId(result):
    raise gitError("git merge-base returned an invalid commit ID")

proc nulPaths(output: string): seq[string] =
  var seen = initHashSet[string]()
  for path in output.split('\0'):
    if path.len == 0:
      continue
    if validateUtf8(path) != -1:
      raise gitError("git returned a path that is not valid UTF-8")
    if path notin seen:
      seen.incl(path)
      result.add(path)
  result.sort()

proc changedFiles(repository: GitRepository, base, head: string): seq[string] =
  let common = repository.mergeBase(base, head)
  let command = repository.run(@[
    "diff", "--no-ext-diff", "--name-only", "-z", common, head, "--"])
  nulPaths(command.stdout)

proc conflictPaths(repository: GitRepository, left, right: string): seq[string] =
  let command = repository.run(@[
    "merge-tree", "--write-tree", "--name-only", "--no-messages", "-z",
    left, right], [0, 1])
  if command.status == 0:
    return @[]
  let records = command.stdout.split('\0')
  if records.len < 2 or not validObjectId(records[0]):
    raise gitError("git merge-tree returned malformed conflict output")
  nulPaths(records[1 .. ^1].join("\0"))

proc isAncestor(repository: GitRepository, before, after: string): bool =
  repository.run(@["merge-base", "--is-ancestor", before, after], [0, 1]).status == 0

proc analyzeRepository*(data: AnalysisInput, path: string): AnalysisInput =
  let repository = openGitRepository(path)
  var resolvedHeads = initTable[PrNumber, string]()
  result.repository = data.repository
  for inputPr in data.prs:
    var pr = inputPr
    if pr.gitHead.len == 0 or pr.gitBase.len == 0:
      raise gitError("internal error: missing Git revisions for PR #" & $pr.number)
    let head = repository.resolveCommit(pr.gitHead)
    let base = repository.resolveCommit(pr.gitBase)
    pr.files = repository.changedFiles(base, head)
    pr.baseConflictPaths = repository.conflictPaths(base, head)
    resolvedHeads[pr.number] = head
    result.prs.add(pr)

  for leftIndex in 0 ..< result.prs.len:
    let left = result.prs[leftIndex]
    let leftHead = resolvedHeads[left.number]
    for rightIndex in leftIndex + 1 ..< result.prs.len:
      let right = result.prs[rightIndex]
      let rightHead = resolvedHeads[right.number]
      let paths = repository.conflictPaths(leftHead, rightHead)
      if paths.len > 0:
        result.conflictEdges.add(PathEdge(
          a: left.number, b: right.number, paths: paths))
      if leftHead == rightHead:
        continue
      if repository.isAncestor(leftHead, rightHead):
        result.ancestryEdges.add(AncestryEdge(
          before: left.number, after: right.number))
      elif repository.isAncestor(rightHead, leftHead):
        result.ancestryEdges.add(AncestryEdge(
          before: right.number, after: left.number))
