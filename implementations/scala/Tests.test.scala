//> using test.dep "org.scalameta::munit:1.3.4"

import java.nio.charset.StandardCharsets
import java.nio.file.{Files, Path}
import scala.jdk.CollectionConverters.*
import scala.util.Using

final class PrPlanTests extends munit.FunSuite:
  private val validPure =
    """{
      |  "schema_version": 1,
      |  "repository": "acme/widgets",
      |  "prs": [{
      |    "number": 1,
      |    "title": "First",
      |    "author": null,
      |    "head_ref": "feature/one",
      |    "base_ref": "main",
      |    "draft": false,
      |    "mergeable": "MERGEABLE",
      |    "review_decision": "APPROVED",
      |    "created_at": "2026-01-01T00:00:00Z",
      |    "updated_at": "2026-01-02T00:00:00Z",
      |    "additions": 1,
      |    "deletions": 0,
      |    "files": [],
      |    "base_conflict_paths": []
      |  }],
      |  "conflict_edges": [],
      |  "ancestry_edges": []
      |}""".stripMargin

  private val emptyPure =
    """{
      |  "schema_version": 1,
      |  "repository": "acme/empty",
      |  "prs": [],
      |  "conflict_edges": [],
      |  "ancestry_edges": []
      |}""".stripMargin

  private def invalid(source: String, expected: String): Unit =
    val error = intercept[InputError](Validation.decode(source, "pure"))
    assert(error.getMessage.contains(expected), error.getMessage)

  private def deleteTree(path: Path): Unit =
    if Files.isDirectory(path) then
      Using.resource(Files.list(path))(_.iterator().asScala.foreach(deleteTree))
    Files.deleteIfExists(path)

  test("strict input validation accepts a nullable author") {
    val input = Validation.decode(validPure, "pure")
    assertEquals(input.prs.head.author, None)
  }

  test("strict input validation rejects incorrectly typed fields") {
    invalid(validPure.replace("\"number\": 1", "\"number\": \"1\""), "number: expected an integer")
    invalid(validPure.replace("\"additions\": 1", "\"additions\": true"), "additions: expected an integer")
    invalid(validPure.replace("\"author\": null", "\"author\": {\"login\":\"alice\"}"), "author: expected a string")
    invalid(validPure.replace("\"mergeable\": \"MERGEABLE\"", "\"mergeable\": \"YES\""), "mergeable: expected one of")
    invalid(validPure.replace("\"repository\": \"acme/widgets\"", "\"repository\": 7"), "repository: expected a string")
  }

  test("strict input validation rejects unknown fields and unsafe revisions") {
    invalid(validPure.replace("\"schema_version\": 1,", "\"schema_version\": 1, \"extra\": true,"), "unknown field(s): extra")
    val gitSource = validPure
      .replace("\"files\": []", "\"git_head\": \"--upload-pack=bad\"")
      .replace("\"base_conflict_paths\": []", "\"git_base\": \"main\"")
      .replace(",\n  \"conflict_edges\": [],\n  \"ancestry_edges\": []", "")
    val error = intercept[InputError](Validation.decode(gitSource, "git"))
    assert(error.getMessage.contains("revision must not start with '-'"), error.getMessage)
  }

  test("empty and single-PR plans render deterministically") {
    val empty = Planner.build(Validation.decode(emptyPure, "pure"))
    assertEquals(empty.readyNow, Vector.empty)
    assertEquals(empty.suggestedLandingBatches, Vector.empty)
    val plan = Planner.build(Validation.decode(validPure, "pure"))
    assertEquals(plan.readyNow, Vector(PrNumber(1)))
    assertEquals(Render.json(plan), Render.json(plan))
  }

  test("expected and unexpected Git statuses remain distinct") {
    val repositoryPath = Files.createTempDirectory("pr-plan-git")
    val left = Files.createTempFile("pr-plan-left", ".txt")
    val right = Files.createTempFile("pr-plan-right", ".txt")
    try
      val initialization = ProcessBuilder("git", "init", repositoryPath.toString).redirectErrorStream(true).start()
      assertEquals(initialization.waitFor(), 0, new String(initialization.getInputStream.readAllBytes(), StandardCharsets.UTF_8))
      val repository = GitRepository.open(repositoryPath)
      Files.writeString(left, "left\n", StandardCharsets.UTF_8)
      Files.writeString(right, "right\n", StandardCharsets.UTF_8)
      val arguments = Seq("diff", "--quiet", "--no-index", left.toString, right.toString)
      assertEquals(repository.run(arguments, Set(0, 1)).status, 1)
      val error = intercept[GitError](repository.run(arguments))
      assert(error.getMessage.contains("status 1"), error.getMessage)
    finally
      Files.deleteIfExists(left)
      Files.deleteIfExists(right)
      deleteTree(repositoryPath)
  }
