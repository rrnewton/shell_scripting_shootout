import { stat } from "node:fs/promises";
import { resolve } from "node:path";
import { gitObjectId, normalizeConflictEdge, sortedUnique, validateUniqueGitPrs } from "./schema.ts";
import type { GitInput, GitInputPr, GitRevision } from "./schema.ts";
import type {
  ConflictEdge,
  GitObjectId,
  PlanningInput,
  PrNode,
  PrNumber,
} from "./types.ts";

export class GitCommandError extends Error {
  readonly args: readonly string[];
  readonly exitCode: number;
  readonly stderr: string;

  constructor(args: readonly string[], exitCode: number, stderr: string) {
    super(`git ${args.join(" ")} exited ${exitCode}: ${stderr.trim() || "no error output"}`);
    this.name = "GitCommandError";
    this.args = args;
    this.exitCode = exitCode;
    this.stderr = stderr;
  }
}

interface GitResult {
  readonly exitCode: number;
  readonly stdout: Uint8Array;
  readonly stderr: string;
}

interface ResolvedPr {
  readonly input: GitInputPr;
  readonly head: GitObjectId;
  readonly base: GitObjectId;
  readonly files: readonly string[];
  readonly baseConflictPaths: readonly string[];
}

export async function analyzeGit(input: GitInput, gitDirectory: string): Promise<PlanningInput> {
  validateUniqueGitPrs(input);
  const absoluteGitDirectory = resolve(gitDirectory);
  const information = await stat(absoluteGitDirectory).catch(() => undefined);
  if (information === undefined || !information.isDirectory()) {
    throw new Error(`Git directory is not a directory: ${absoluteGitDirectory}`);
  }
  await runGit(absoluteGitDirectory, ["rev-parse", "--git-dir"], [0]);

  const resolvedPrs: ResolvedPr[] = [];
  for (const pr of [...input.prs].sort((a, b) => a.number - b.number)) {
    const base = await resolveRevision(absoluteGitDirectory, pr.git_base);
    const head = await resolveRevision(absoluteGitDirectory, pr.git_head);
    const files = await changedFiles(absoluteGitDirectory, base, head);
    const baseConflictPaths = await mergeConflictPaths(absoluteGitDirectory, base, head);
    resolvedPrs.push({ input: pr, base, head, files, baseConflictPaths });
  }

  const conflictEdges: ConflictEdge[] = [];
  const ancestryEdges: { before: PrNumber; after: PrNumber }[] = [];
  for (let leftIndex = 0; leftIndex < resolvedPrs.length; leftIndex += 1) {
    const left = resolvedPrs[leftIndex];
    if (left === undefined) continue;
    for (let rightIndex = leftIndex + 1; rightIndex < resolvedPrs.length; rightIndex += 1) {
      const right = resolvedPrs[rightIndex];
      if (right === undefined) continue;
      const paths = await mergeConflictPaths(absoluteGitDirectory, left.head, right.head);
      if (paths.length > 0) {
        conflictEdges.push(normalizeConflictEdge({
          a: left.input.number,
          b: right.input.number,
          paths,
        }));
      }
      if (left.head !== right.head) {
        if (await isAncestor(absoluteGitDirectory, left.head, right.head)) {
          ancestryEdges.push({ before: left.input.number, after: right.input.number });
        } else if (await isAncestor(absoluteGitDirectory, right.head, left.head)) {
          ancestryEdges.push({ before: right.input.number, after: left.input.number });
        }
      }
    }
  }

  return {
    repository: input.repository,
    nodes: resolvedPrs.map(toNode),
    conflictEdges,
    ancestryEdges,
  };
}

function toNode(pr: ResolvedPr): PrNode {
  const { git_head: _gitHead, git_base: _gitBase, ...metadata } = pr.input;
  return {
    ...metadata,
    files: pr.files,
    base_conflict_paths: pr.baseConflictPaths,
  };
}

async function resolveRevision(gitDirectory: string, revision: GitRevision): Promise<GitObjectId> {
  const result = await runGit(
    gitDirectory,
    ["rev-parse", "--verify", "--end-of-options", `${revision}^{commit}`],
    [0],
  );
  return gitObjectId(decode(result.stdout).trim());
}

async function changedFiles(
  gitDirectory: string,
  base: GitObjectId,
  head: GitObjectId,
): Promise<string[]> {
  const mergeBaseResult = await runGit(
    gitDirectory,
    ["merge-base", base, head],
    [0],
  );
  const mergeBase = gitObjectId(decode(mergeBaseResult.stdout).trim());
  const result = await runGit(
    gitDirectory,
    ["diff", "--name-only", "-z", `${mergeBase}...${head}`, "--"],
    [0],
  );
  return sortedUnique(parseNulList(result.stdout));
}

async function isAncestor(
  gitDirectory: string,
  possibleAncestor: GitObjectId,
  commit: GitObjectId,
): Promise<boolean> {
  const result = await runGit(
    gitDirectory,
    ["merge-base", "--is-ancestor", possibleAncestor, commit],
    [0, 1],
  );
  return result.exitCode === 0;
}

export async function mergeConflictPaths(
  gitDirectory: string,
  left: GitObjectId,
  right: GitObjectId,
): Promise<string[]> {
  const result = await runGit(
    gitDirectory,
    ["merge-tree", "--write-tree", "--name-only", "--no-messages", "-z", left, right],
    [0, 1],
  );
  if (result.exitCode === 0) return [];
  const fields = parseNulList(result.stdout);
  if (fields.length === 0) throw new Error("git merge-tree reported a conflict without output");
  return sortedUnique(fields.slice(1));
}

export async function runGit(
  gitDirectory: string,
  args: readonly string[],
  expectedExitCodes: readonly number[],
): Promise<GitResult> {
  const command = ["git", "-C", gitDirectory, "--no-pager", ...args];
  const env = { ...process.env };
  for (const name of [
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_COMMON_DIR",
    "GIT_CONFIG_COUNT",
    "GIT_CONFIG_PARAMETERS",
    "GIT_DIR",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_WORK_TREE",
  ]) {
    delete env[name];
  }
  const child = Bun.spawn(command, {
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
    env: {
      ...env,
      LC_ALL: "C",
      GIT_CONFIG_NOSYSTEM: "1",
      GIT_CONFIG_GLOBAL: "/dev/null",
      GIT_OPTIONAL_LOCKS: "0",
      GIT_TERMINAL_PROMPT: "0",
    },
  });
  const [stdoutBuffer, stderr, exitCode] = await Promise.all([
    new Response(child.stdout).arrayBuffer(),
    new Response(child.stderr).text(),
    child.exited,
  ]);
  const stdout = new Uint8Array(stdoutBuffer);
  if (!expectedExitCodes.includes(exitCode)) throw new GitCommandError(args, exitCode, stderr);
  return { exitCode, stdout, stderr };
}

function parseNulList(bytes: Uint8Array): string[] {
  const decoded = decode(bytes);
  if (decoded.length === 0) return [];
  const fields = decoded.split("\0");
  if (fields.at(-1) === "") fields.pop();
  return fields;
}

function decode(bytes: Uint8Array): string {
  return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
}
