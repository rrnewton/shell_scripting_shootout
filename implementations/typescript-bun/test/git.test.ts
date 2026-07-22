import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { analyzeGit, GitCommandError, runGit } from "../src/git.ts";
import { buildPlan } from "../src/planner.ts";
import { gitInputSchema } from "../src/schema.ts";

const temporaryDirectories: string[] = [];

afterEach(async () => {
  await Promise.all(temporaryDirectories.splice(0).map((directory) => rm(directory, { recursive: true })));
});

describe("offline Git analysis", () => {
  test("uses real diff, merge-tree, and ancestry queries", async () => {
    const fixture = await createGitFixture();
    const input = gitInputSchema.parse({
      schema_version: 1,
      repository: "acme/git-fixture",
      prs: [
        gitPr(10, "feature/left", "main", fixture.left, fixture.base),
        gitPr(11, "feature/right", "main", fixture.right, fixture.base),
        gitPr(12, "feature/stack", "feature/left", fixture.stack, fixture.left),
      ],
    });
    const analysis = await analyzeGit(input, join(fixture.directory, ".git"));
    expect(plain(analysis.nodes.map((node) => [node.number, node.files]))).toEqual([
      [10, ["left.txt", "shared.txt"]],
      [11, ["right.txt", "shared.txt"]],
      [12, ["stack.txt"]],
    ]);
    const plan = buildPlan(analysis);
    expect(plain(plan.conflict_edges)).toEqual([
      { a: 10, b: 11, paths: ["shared.txt"] },
      { a: 11, b: 12, paths: ["shared.txt"] },
    ]);
    expect(plain(plan.ordering_edges)).toEqual([{ before: 10, after: 12, reason: "base-ref" }]);
  });

  test("distinguishes expected status 1 from Git failures", async () => {
    const fixture = await createGitFixture();
    const gitDirectory = join(fixture.directory, ".git");
    const expected = await runGit(
      gitDirectory,
      ["merge-base", "--is-ancestor", fixture.left, fixture.right],
      [0, 1],
    );
    expect(expected.exitCode).toBe(1);
    expect(runGit(gitDirectory, ["not-a-command"], [0])).rejects.toBeInstanceOf(GitCommandError);
  });
});

interface GitFixture {
  readonly directory: string;
  readonly base: string;
  readonly left: string;
  readonly right: string;
  readonly stack: string;
}

async function createGitFixture(): Promise<GitFixture> {
  const directory = await mkdtemp(join(tmpdir(), "pr-plan-git-"));
  temporaryDirectories.push(directory);
  await command(["git", "init", "-q", "-b", "main", directory]);
  await command(["git", "-C", directory, "config", "user.name", "Fixture"]);
  await command(["git", "-C", directory, "config", "user.email", "fixture@example.com"]);
  await Bun.write(join(directory, "shared.txt"), "base\n");
  await command(["git", "-C", directory, "add", "shared.txt"]);
  await command(["git", "-C", directory, "commit", "-qm", "base"]);
  const base = await revision(directory);

  await command(["git", "-C", directory, "switch", "-qc", "feature/left"]);
  await Bun.write(join(directory, "shared.txt"), "left\n");
  await Bun.write(join(directory, "left.txt"), "left\n");
  await command(["git", "-C", directory, "add", "."]);
  await command(["git", "-C", directory, "commit", "-qm", "left"]);
  const left = await revision(directory);

  await command(["git", "-C", directory, "switch", "-qc", "feature/stack"]);
  await Bun.write(join(directory, "stack.txt"), "stack\n");
  await command(["git", "-C", directory, "add", "stack.txt"]);
  await command(["git", "-C", directory, "commit", "-qm", "stack"]);
  const stack = await revision(directory);

  await command(["git", "-C", directory, "switch", "-qc", "feature/right", base]);
  await Bun.write(join(directory, "shared.txt"), "right\n");
  await Bun.write(join(directory, "right.txt"), "right\n");
  await command(["git", "-C", directory, "add", "."]);
  await command(["git", "-C", directory, "commit", "-qm", "right"]);
  return { directory, base, left, right: await revision(directory), stack };
}

async function revision(directory: string): Promise<string> {
  return (await command(["git", "-C", directory, "rev-parse", "HEAD"])).trim();
}

async function command(args: readonly string[]): Promise<string> {
  const child = Bun.spawn([...args], { stdout: "pipe", stderr: "pipe" });
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ]);
  if (exitCode !== 0) throw new Error(`${args.join(" ")} failed: ${stderr}`);
  return stdout;
}

function gitPr(number: number, head_ref: string, base_ref: string, git_head: string, git_base: string) {
  return {
    number,
    title: `PR ${number}`,
    author: null,
    head_ref,
    base_ref,
    draft: false,
    mergeable: "MERGEABLE" as const,
    review_decision: "APPROVED" as const,
    created_at: "2026-01-01T00:00:00Z",
    updated_at: "2026-01-01T00:00:00Z",
    additions: 1,
    deletions: 1,
    git_head,
    git_base,
  };
}

function plain(value: unknown): unknown {
  return JSON.parse(JSON.stringify(value)) as unknown;
}
