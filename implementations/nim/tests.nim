import std/[json, os, osproc, strutils, unittest]

import git_analysis, model, planner, render, validation

const emptyPure = """{
  "schema_version": 1,
  "repository": "acme/widgets",
  "prs": [],
  "conflict_edges": [],
  "ancestry_edges": []
}"""

proc prJson(number: int, head = "feature", base = "main"): string =
  """{
    "number": $1,
    "title": "PR $1",
    "author": null,
    "head_ref": "$2",
    "base_ref": "$3",
    "draft": false,
    "mergeable": "MERGEABLE",
    "review_decision": "APPROVED",
    "created_at": "2026-01-01T00:00:00Z",
    "updated_at": "2026-01-02T00:00:00Z",
    "additions": 1,
    "deletions": 0,
    "files": ["src/shared.rs", "src/$1.rs"],
    "base_conflict_paths": []
  }""" % [$number, head, base]

proc pureDocument(prs: string; conflicts = "", ancestry = ""): string =
  """{
    "schema_version": 1,
    "repository": "acme/widgets",
    "prs": [$1],
    "conflict_edges": [$2],
    "ancestry_edges": [$3]
  }""" % [prs, conflicts, ancestry]

proc parsePure(source: string): AnalysisInput =
  decodeDocument(decodeJsonDocument(source, "test.json"), pureMode)

proc testPr(number: int, head = "feature", base = "main"): PullRequest =
  PullRequest(
    number: PrNumber(number), title: "PR " & $number, headRef: head,
    baseRef: base, mergeability: mergeable, reviewDecision: approved,
    createdAt: "2026-01-01T00:00:00Z",
    updatedAt: "2026-01-02T00:00:00Z", additions: 1,
    files: @["src/shared.rs"])

suite "JSON validation and planning":
  test "rejects wrong types, duplicate fields, unknown fields, and references":
    expect InputError:
      discard parsePure(pureDocument(
        prJson(1).replace("\"number\": 1", "\"number\": \"1\"")))
    expect InputError:
      discard parsePure(emptyPure.replace(
        "\"schema_version\": 1,", "\"schema_version\": 1, \"schema_version\": 1,"))
    expect InputError:
      discard parsePure(pureDocument(
        prJson(1).replace("\"title\":", "\"surprise\": true, \"title\":")))
    expect InputError:
      discard parsePure(pureDocument(prJson(1),
        "{\"a\":1,\"b\":2,\"paths\":[\"src/shared.rs\"]}"))

  test "rejects unsafe Git revisions before execution":
    let source = pureDocument(prJson(1))
      .replace("\"files\": [\"src/shared.rs\", \"src/1.rs\"],\n    \"base_conflict_paths\": []",
        "\"git_head\": \"--help\",\n    \"git_base\": \"main\"")
      .replace(",\n    \"conflict_edges\": [],\n    \"ancestry_edges\": []", "")
    expect InputError:
      discard decodeDocument(decodeJsonDocument(source, "git.json"), gitMode)

  test "handles empty and single inputs":
    let empty = makePlan(parsePure(emptyPure))
    check empty.nodes.len == 0
    check empty.readyNow.len == 0
    let single = makePlan(parsePure(pureDocument(prJson(7))))
    check single.readyNow == @[PrNumber(7)]
    check single.nodes[0].author == "unknown"

  test "detects cycles, conflicts, and held dependencies":
    var first = testPr(1, "parent", "child")
    var second = testPr(2, "child", "parent")
    second.draft = true
    let plan = makePlan(AnalysisInput(
      repository: "acme/widgets", prs: @[first, second],
      conflictEdges: @[PathEdge(
        a: PrNumber(2), b: PrNumber(1), paths: @["src/shared.rs"])]))
    check plan.orderingCycles == @[PrNumber(1), PrNumber(2)]
    check plan.suggestedLandingBatches == @[@[PrNumber(1)], @[PrNumber(2)]]
    check plan.readyLandingBatches.len == 0
    check plan.heldPrs.len == 2

  test "normalizes deterministically":
    let source = pureDocument(prJson(2, "two") & "," & prJson(1, "one"),
      "{\"a\":2,\"b\":1,\"paths\":[\"z\",\"a\"]}")
    let first = renderJson(makePlan(parsePure(source)))
    let second = renderJson(makePlan(parsePure(source)))
    check first == second
    let output = parseJson(first)
    check output["conflict_edges"][0]["a"].getInt() == 1
    check output["conflict_edges"][0]["paths"][0].getStr() == "a"

proc runGit(directory: string, arguments: varargs[string]) =
  let process = startProcess("git", args = @["-C", directory] & @arguments,
    options = {poUsePath, poParentStreams})
  defer: process.close()
  check process.waitForExit() == 0

suite "Git analysis":
  test "handles conflict status one and hard failures":
    let directory = getTempDir() / ("pr-plan-nim-" & $getCurrentProcessId())
    if dirExists(directory):
      removeDir(directory)
    createDir(directory)
    defer: removeDir(directory)

    runGit(directory, "init", "-q")
    runGit(directory, "config", "user.name", "Test")
    runGit(directory, "config", "user.email", "test@example.invalid")
    writeFile(directory / "shared.txt", "base\n")
    runGit(directory, "add", "shared.txt")
    runGit(directory, "commit", "-qm", "base")
    runGit(directory, "branch", "base")
    runGit(directory, "switch", "-qc", "left")
    writeFile(directory / "shared.txt", "left\n")
    runGit(directory, "commit", "-qam", "left")
    runGit(directory, "switch", "-qc", "right", "base")
    writeFile(directory / "shared.txt", "right\n")
    runGit(directory, "commit", "-qam", "right")

    var left = testPr(1, "left")
    left.gitHead = "left"
    left.gitBase = "base"
    var right = testPr(2, "right")
    right.gitHead = "right"
    right.gitBase = "base"
    let input = AnalysisInput(repository: "acme/git", prs: @[left, right])
    let analyzed = analyzeRepository(input, directory)
    check analyzed.conflictEdges.len == 1
    check analyzed.conflictEdges[0].paths == @["shared.txt"]
    check makePlan(analyzed).fileOverlapEdges.len == 1

    left.gitHead = "missing"
    expect GitError:
      discard analyzeRepository(
        AnalysisInput(repository: "acme/git", prs: @[left]), directory)
