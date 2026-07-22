import { analyzeGit, GitCommandError, runGit } from "../src/git.ts";
import { buildPlan } from "../src/planner.ts";
import { parseGitInput } from "../src/schema.ts";
import type { GitInput } from "../src/types.ts";
import { assert, assertEquals } from "./assert.ts";

Deno.test("Git analysis uses real diffs, conflicts, and ancestry", async () => {
  const fixture = await createGitFixture();
  try {
    const input = parseGitInput({
      schema_version: 1,
      repository: "acme/git-fixture",
      prs: [
        gitPr(10, "feature/left", "main", fixture.left, fixture.base),
        gitPr(11, "feature/right", "main", fixture.right, fixture.base),
        gitPr(12, "feature/stack", "feature/left", fixture.stack, fixture.left),
      ],
    });
    const analysis = await analyzeGit(input, fixture.directory);
    assertEquals(analysis.nodes.map((node) => [node.number, node.files]), [
      [10, ["left.txt", "shared.txt"]],
      [11, ["right.txt", "shared.txt"]],
      [12, ["stack.txt"]],
    ]);
    const plan = buildPlan(analysis);
    assertEquals(plan.conflict_edges, [
      { a: 10, b: 11, paths: ["shared.txt"] },
      { a: 11, b: 12, paths: ["shared.txt"] },
    ]);
    assertEquals(plan.ordering_edges, [{
      before: 10,
      after: 12,
      reason: "base-ref",
    }]);
  } finally {
    await Deno.remove(fixture.directory, { recursive: true });
  }
});

Deno.test("Git runner distinguishes expected status 1 from failures", async () => {
  const fixture = await createGitFixture();
  try {
    const expected = await runGit(
      `${fixture.directory}/.git`,
      ["merge-base", "--is-ancestor", fixture.left, fixture.right],
      [0, 1],
    );
    assertEquals(expected.exitCode, 1);
    try {
      await runGit(`${fixture.directory}/.git`, ["not-a-command"], [0]);
      throw new Error("expected invalid Git command to fail");
    } catch (error) {
      assert(error instanceof GitCommandError);
    }
  } finally {
    await Deno.remove(fixture.directory, { recursive: true });
  }
});

Deno.test("Git analysis accepts linked worktree roots and bare repositories", async () => {
  const fixture = await createGitFixture();
  const linkedDirectory = `${fixture.directory}-linked`;
  const bareDirectory = `${fixture.directory}-bare`;
  try {
    await command([
      "git",
      "-C",
      fixture.directory,
      "worktree",
      "add",
      "-q",
      "--detach",
      linkedDirectory,
      fixture.left,
    ]);
    await command([
      "git",
      "clone",
      "-q",
      "--bare",
      fixture.directory,
      bareDirectory,
    ]);
    assert((await Deno.stat(`${linkedDirectory}/.git`)).isFile);

    const input = parseGitInput({
      schema_version: 1,
      repository: "acme/git-layouts",
      prs: [gitPr(10, "feature/left", "main", fixture.left, fixture.base)],
    });
    for (const directory of [linkedDirectory, bareDirectory]) {
      const analysis = await analyzeGit(input, directory);
      assertEquals(analysis.nodes.map((node) => node.files), [
        ["left.txt", "shared.txt"],
      ]);
    }
  } finally {
    await removeIfPresent(linkedDirectory);
    await removeIfPresent(bareDirectory);
    await Deno.remove(fixture.directory, { recursive: true });
  }
});

interface GitFixture {
  readonly directory: string;
  readonly base: string;
  readonly left: string;
  readonly right: string;
  readonly stack: string;
}

async function createGitFixture(): Promise<GitFixture> {
  const directory = await Deno.makeTempDir({ prefix: "pr-plan-deno-git-" });
  try {
    await command(["git", "init", "-q", "-b", "main", directory]);
    await command(["git", "-C", directory, "config", "user.name", "Fixture"]);
    await command([
      "git",
      "-C",
      directory,
      "config",
      "user.email",
      "fixture@example.com",
    ]);
    await Deno.writeTextFile(`${directory}/shared.txt`, "base\n");
    await command(["git", "-C", directory, "add", "shared.txt"]);
    await command(["git", "-C", directory, "commit", "-qm", "base"]);
    const base = await revision(directory);

    await command(["git", "-C", directory, "switch", "-qc", "feature/left"]);
    await Deno.writeTextFile(`${directory}/shared.txt`, "left\n");
    await Deno.writeTextFile(`${directory}/left.txt`, "left\n");
    await command(["git", "-C", directory, "add", "."]);
    await command(["git", "-C", directory, "commit", "-qm", "left"]);
    const left = await revision(directory);

    await command(["git", "-C", directory, "switch", "-qc", "feature/stack"]);
    await Deno.writeTextFile(`${directory}/stack.txt`, "stack\n");
    await command(["git", "-C", directory, "add", "stack.txt"]);
    await command(["git", "-C", directory, "commit", "-qm", "stack"]);
    const stack = await revision(directory);

    await command([
      "git",
      "-C",
      directory,
      "switch",
      "-qc",
      "feature/right",
      base,
    ]);
    await Deno.writeTextFile(`${directory}/shared.txt`, "right\n");
    await Deno.writeTextFile(`${directory}/right.txt`, "right\n");
    await command(["git", "-C", directory, "add", "."]);
    await command(["git", "-C", directory, "commit", "-qm", "right"]);
    return { directory, base, left, right: await revision(directory), stack };
  } catch (error) {
    await Deno.remove(directory, { recursive: true });
    throw error;
  }
}

async function revision(directory: string): Promise<string> {
  return (await command(["git", "-C", directory, "rev-parse", "HEAD"])).trim();
}

async function command(args: readonly string[]): Promise<string> {
  const executable = args[0];
  if (executable === undefined) throw new Error("empty command");
  const output = await new Deno.Command(executable, {
    args: args.slice(1),
    stdout: "piped",
    stderr: "piped",
  }).output();
  if (!output.success) {
    throw new Error(
      `${args.join(" ")} failed: ${new TextDecoder().decode(output.stderr)}`,
    );
  }
  return new TextDecoder().decode(output.stdout);
}

async function removeIfPresent(path: string): Promise<void> {
  try {
    await Deno.remove(path, { recursive: true });
  } catch (error) {
    if (!(error instanceof Deno.errors.NotFound)) throw error;
  }
}

function gitPr(
  number: number,
  head_ref: string,
  base_ref: string,
  git_head: string,
  git_base: string,
): GitInput["prs"][number] {
  return parseGitInput({
    schema_version: 1,
    repository: "one",
    prs: [{
      number,
      title: `PR ${number}`,
      author: null,
      head_ref,
      base_ref,
      draft: false,
      mergeable: "MERGEABLE",
      review_decision: "APPROVED",
      created_at: "2026-01-01T00:00:00Z",
      updated_at: "2026-01-01T00:00:00Z",
      additions: 1,
      deletions: 1,
      git_head,
      git_base,
    }],
  }).prs[0] ?? neverPr();
}

function neverPr(): never {
  throw new Error("single PR decoder invariant failed");
}
