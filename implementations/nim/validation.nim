import std/[algorithm, json, parsejson, sets, streams, strutils, unicode]

import model

type
  InputError* = object of CatchableError

  InputMode* = enum
    pureMode, gitMode

proc inputError(path, message: string): ref InputError =
  newException(InputError, path & ": " & message)

proc childPath(path, field: string): string =
  if field.len > 0 and (field[0] in {'a'..'z', 'A'..'Z', '_'}) and
      field.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '_'}):
    path & "." & field
  else:
    path & "[\"" & field & "\"]"

proc parseValue(parser: var JsonParser, path: string): JsonNode =
  case parser.kind
  of jsonObjectStart:
    result = newJObject()
    var seen = initHashSet[string]()
    parser.next()
    while parser.kind != jsonObjectEnd:
      if parser.kind == jsonError:
        raise inputError(path, parser.errorMsg())
      if parser.kind != jsonString:
        raise inputError(path, "invalid JSON object")
      let key = parser.str
      let fieldPath = childPath(path, key)
      if key in seen:
        raise inputError(fieldPath, "duplicate field")
      seen.incl(key)
      parser.next()
      result[key] = parseValue(parser, fieldPath)
    parser.next()
  of jsonArrayStart:
    result = newJArray()
    var index = 0
    parser.next()
    while parser.kind != jsonArrayEnd:
      if parser.kind == jsonError:
        raise inputError(path, parser.errorMsg())
      result.add(parseValue(parser, path & "[" & $index & "]"))
      inc(index)
    parser.next()
  of jsonString:
    result = newJString(parser.str)
    parser.next()
  of jsonInt:
    try:
      result = newJInt(parser.getInt())
    except ValueError:
      raise inputError(path, "integer is outside the supported range")
    parser.next()
  of jsonFloat:
    result = newJFloat(parser.getFloat())
    parser.next()
  of jsonTrue:
    result = newJBool(true)
    parser.next()
  of jsonFalse:
    result = newJBool(false)
    parser.next()
  of jsonNull:
    result = newJNull()
    parser.next()
  of jsonError:
    raise inputError(path, parser.errorMsg())
  else:
    raise inputError(path, "expected a JSON value")

proc decodeJsonDocument*(source, filename: string): JsonNode =
  var parser: JsonParser
  parser.open(newStringStream(source), filename)
  defer: parser.close()
  parser.next()
  result = parseValue(parser, "$" )
  if parser.kind == jsonError:
    raise inputError("$", parser.errorMsg())
  if parser.kind != jsonEof:
    raise inputError("$", "unexpected data after the JSON document")

proc requireObject(value: JsonNode, path: string): JsonNode =
  if value.kind != JObject:
    raise inputError(path, "expected an object")
  value

proc requireArray(value: JsonNode, path: string): JsonNode =
  if value.kind != JArray:
    raise inputError(path, "expected an array")
  value

proc exactKeys(value: JsonNode, expected: openArray[string], path: string) =
  var expectedSet = expected.toHashSet()
  var missing: seq[string]
  var extra: seq[string]
  for field in expected:
    if not value.hasKey(field):
      missing.add(field)
  for field, _ in value.pairs:
    if field notin expectedSet:
      extra.add(field)
  missing.sort()
  extra.sort()
  if missing.len > 0:
    raise inputError(path, "missing field(s): " & missing.join(", "))
  if extra.len > 0:
    raise inputError(path, "unknown field(s): " & extra.join(", "))

proc asString(value: JsonNode, path: string, nonempty = true): string =
  if value.kind != JString:
    raise inputError(path, "expected a string")
  result = value.getStr()
  if nonempty and result.len == 0:
    raise inputError(path, "must not be empty")
  if '\0' in result:
    raise inputError(path, "must not contain NUL")
  if validateUtf8(result) != -1:
    raise inputError(path, "must be valid UTF-8")

proc asNonnegativeInteger(value: JsonNode, path: string): int64 =
  if value.kind != JInt:
    raise inputError(path, "expected an integer")
  let number = value.getBiggestInt()
  if number < 0:
    raise inputError(path, "must not be negative")
  int64(number)

proc asPrNumber(value: JsonNode, path: string): PrNumber =
  let number = asNonnegativeInteger(value, path)
  if number == 0:
    raise inputError(path, "must be positive")
  PrNumber(number)

proc asBool(value: JsonNode, path: string): bool =
  if value.kind != JBool:
    raise inputError(path, "expected a boolean")
  value.getBool()

proc digitValue(character: char): int =
  if character notin {'0'..'9'}: -1 else: ord(character) - ord('0')

proc decimalAt(value: string, start, count: int): int =
  result = 0
  for index in start ..< start + count:
    let digit = digitValue(value[index])
    if digit < 0:
      return -1
    result = result * 10 + digit

proc leapYear(year: int): bool =
  year mod 4 == 0 and (year mod 100 != 0 or year mod 400 == 0)

proc validTimestamp(value: string): bool =
  if value.len < 20 or value[4] != '-' or value[7] != '-' or
      value[10] != 'T' or value[13] != ':' or value[16] != ':':
    return false
  let year = decimalAt(value, 0, 4)
  let month = decimalAt(value, 5, 2)
  let day = decimalAt(value, 8, 2)
  let hour = decimalAt(value, 11, 2)
  let minute = decimalAt(value, 14, 2)
  let second = decimalAt(value, 17, 2)
  if year < 0 or month notin 1..12 or hour notin 0..23 or
      minute notin 0..59 or second notin 0..60:
    return false
  var days = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
  if leapYear(year):
    days[1] = 29
  if day < 1 or day > days[month - 1]:
    return false

  var index = 19
  if index < value.len and value[index] == '.':
    inc(index)
    let fractionStart = index
    while index < value.len and value[index] in {'0'..'9'}:
      inc(index)
    if index == fractionStart:
      return false
  if index == value.len - 1 and value[index] == 'Z':
    return true
  if index + 6 != value.len or value[index] notin {'+', '-'} or
      value[index + 3] != ':':
    return false
  let offsetHour = decimalAt(value, index + 1, 2)
  let offsetMinute = decimalAt(value, index + 4, 2)
  offsetHour in 0..23 and offsetMinute in 0..59

proc asTimestamp(value: JsonNode, path: string): string =
  result = asString(value, path)
  if not validTimestamp(result):
    raise inputError(path, "expected an RFC 3339 timestamp")

proc asMergeability(value: JsonNode, path: string): Mergeability =
  case asString(value, path)
  of "MERGEABLE": mergeable
  of "CONFLICTING": conflicting
  of "UNKNOWN": unknown
  else: raise inputError(path, "expected one of: CONFLICTING, MERGEABLE, UNKNOWN")

proc asReviewDecision(value: JsonNode, path: string): ReviewDecision =
  case asString(value, path)
  of "APPROVED": approved
  of "CHANGES_REQUESTED": changesRequested
  of "REVIEW_REQUIRED": reviewRequired
  of "NONE": noReview
  else:
    raise inputError(path,
      "expected one of: APPROVED, CHANGES_REQUESTED, NONE, REVIEW_REQUIRED")

proc asPaths(value: JsonNode, path: string): seq[string] =
  let items = requireArray(value, path)
  var seen = initHashSet[string]()
  for index in 0 ..< items.len:
    let item = items[index]
    let itemPath = path & "[" & $index & "]"
    let filePath = asString(item, itemPath)
    let components = filePath.split('/')
    if filePath[0] in {'/', '\\'} or
        (filePath.len >= 2 and filePath[1] == ':') or ".." in components:
      raise inputError(itemPath, "expected a repository-relative path")
    if filePath in seen:
      raise inputError(path, "paths must be unique")
    seen.incl(filePath)
    result.add(filePath)
  result.sort()

proc asRevision(value: JsonNode, path: string): string =
  result = asString(value, path)
  if result[0] == '-':
    raise inputError(path, "revision must not start with '-'")
  for character in result:
    if ord(character) < 0x20 or ord(character) == 0x7f:
      raise inputError(path, "revision must not contain control characters")

const commonPrKeys = [
  "number", "title", "author", "head_ref", "base_ref", "draft",
  "mergeable", "review_decision", "created_at", "updated_at", "additions",
  "deletions"
]

proc decodePullRequest(value: JsonNode, index: int, mode: InputMode): PullRequest =
  let path = "$.prs[" & $index & "]"
  let item = requireObject(value, path)
  if mode == pureMode:
    exactKeys(item, @commonPrKeys & @["files", "base_conflict_paths"], path)
  else:
    exactKeys(item, @commonPrKeys & @["git_head", "git_base"], path)

  result.number = asPrNumber(item["number"], path & ".number")
  result.title = asString(item["title"], path & ".title")
  if item["author"].kind == JNull:
    result.hasAuthor = false
  else:
    result.author = asString(item["author"], path & ".author")
    result.hasAuthor = true
  result.headRef = asString(item["head_ref"], path & ".head_ref")
  result.baseRef = asString(item["base_ref"], path & ".base_ref")
  result.draft = asBool(item["draft"], path & ".draft")
  result.mergeability = asMergeability(item["mergeable"], path & ".mergeable")
  result.reviewDecision =
    asReviewDecision(item["review_decision"], path & ".review_decision")
  result.createdAt = asTimestamp(item["created_at"], path & ".created_at")
  result.updatedAt = asTimestamp(item["updated_at"], path & ".updated_at")
  result.additions = asNonnegativeInteger(item["additions"], path & ".additions")
  result.deletions = asNonnegativeInteger(item["deletions"], path & ".deletions")
  if mode == pureMode:
    result.files = asPaths(item["files"], path & ".files")
    result.baseConflictPaths =
      asPaths(item["base_conflict_paths"], path & ".base_conflict_paths")
  else:
    result.gitHead = asRevision(item["git_head"], path & ".git_head")
    result.gitBase = asRevision(item["git_base"], path & ".git_base")

proc knownPr(value: JsonNode, path: string,
    known: HashSet[PrNumber]): PrNumber =
  result = asPrNumber(value, path)
  if result notin known:
    raise inputError(path, "unknown pull request #" & $result)

proc decodeConflictEdges(value: JsonNode,
    known: HashSet[PrNumber]): seq[PathEdge] =
  let items = requireArray(value, "$.conflict_edges")
  var seen = initHashSet[(PrNumber, PrNumber)]()
  for index in 0 ..< items.len:
    let value = items[index]
    let path = "$.conflict_edges[" & $index & "]"
    let item = requireObject(value, path)
    exactKeys(item, ["a", "b", "paths"], path)
    var a = knownPr(item["a"], path & ".a", known)
    var b = knownPr(item["b"], path & ".b", known)
    if a == b:
      raise inputError(path, "a conflict edge must join two different pull requests")
    if b < a:
      swap(a, b)
    if (a, b) in seen:
      raise inputError(path, "duplicate conflict edge #" & $a & "/#" & $b)
    seen.incl((a, b))
    result.add(PathEdge(a: a, b: b,
      paths: asPaths(item["paths"], path & ".paths")))
  result.sort(proc(left, right: PathEdge): int =
    result = cmp(left.a, right.a)
    if result == 0: result = cmp(left.b, right.b))

proc decodeAncestryEdges(value: JsonNode,
    known: HashSet[PrNumber]): seq[AncestryEdge] =
  let items = requireArray(value, "$.ancestry_edges")
  var seen = initHashSet[(PrNumber, PrNumber)]()
  for index in 0 ..< items.len:
    let value = items[index]
    let path = "$.ancestry_edges[" & $index & "]"
    let item = requireObject(value, path)
    exactKeys(item, ["before", "after"], path)
    let before = knownPr(item["before"], path & ".before", known)
    let after = knownPr(item["after"], path & ".after", known)
    if before == after:
      raise inputError(path, "an ancestry edge must join two different pull requests")
    if (before, after) in seen:
      raise inputError(path, "duplicate ancestry edge #" & $before & " -> #" & $after)
    seen.incl((before, after))
    result.add(AncestryEdge(before: before, after: after))
  result.sort(proc(left, right: AncestryEdge): int =
    result = cmp(left.before, right.before)
    if result == 0: result = cmp(left.after, right.after))

proc decodeDocument*(value: JsonNode, mode: InputMode): AnalysisInput =
  let root = requireObject(value, "$" )
  if mode == pureMode:
    exactKeys(root,
      ["schema_version", "repository", "prs", "conflict_edges", "ancestry_edges"],
      "$" )
  else:
    exactKeys(root, ["schema_version", "repository", "prs"], "$" )
  if asNonnegativeInteger(root["schema_version"], "$.schema_version") != 1:
    raise inputError("$.schema_version", "only schema version 1 is supported")
  result.repository = asString(root["repository"], "$.repository")

  let items = requireArray(root["prs"], "$.prs")
  var numbers = initHashSet[PrNumber]()
  var headRefs = initHashSet[string]()
  for index in 0 ..< items.len:
    let value = items[index]
    let pr = decodePullRequest(value, index, mode)
    if pr.number in numbers:
      raise inputError("$.prs", "pull request numbers must be unique")
    if pr.headRef in headRefs:
      raise inputError("$.prs", "head_ref values must be unique")
    numbers.incl(pr.number)
    headRefs.incl(pr.headRef)
    result.prs.add(pr)
  result.prs.sort(proc(left, right: PullRequest): int = cmp(left.number, right.number))
  if mode == pureMode:
    result.conflictEdges = decodeConflictEdges(root["conflict_edges"], numbers)
    result.ancestryEdges = decodeAncestryEdges(root["ancestry_edges"], numbers)

proc loadDocument*(path: string, mode: InputMode): AnalysisInput =
  var source: string
  try:
    source = readFile(path)
  except IOError, OSError:
    raise inputError(path, getCurrentExceptionMsg())
  try:
    decodeDocument(decodeJsonDocument(source, path), mode)
  except InputError as error:
    raise inputError(path, error.msg)
