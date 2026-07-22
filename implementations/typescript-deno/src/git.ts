import { gitObjectId, normalizeConflictEdge, sortedUnique } from "./schema.ts";
import type {
  ConflictEdge,
  GitInput,
  GitInputPr,
  GitObjectId,
  GitRevision,
  PlanningInput,
  PrNode,
  PrNumber,
} from "./types.ts";

const commandTimeoutMilliseconds = 30_000;

export class GitCommandError extends Error {
  readonly args: readonly string[];
  readonly exitCode: number;
  readonly stderr: string;

  constructor(args: readonly string[], exitCode: number, stderr: string) {
    super(
      `git ${args.join(" ")} exited ${exitCode}: ${
        stderr.trim() || "no error output"
      }`,
    );
    this.name = "GitCommandError";
    this.args = args;
    this.exitCode = exitCode;
    this.stderr = stderr;
  }
}

export class GitExecutionError extends Error {
  constructor(message: string, options?: ErrorOptions) {
    super(message, options);
    this.name = "GitExecutionError";
  }
}

export interface GitResult {
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

export async function analyzeGit(
  input: GitInput,
  gitDirectory: string,
): Promise<PlanningInput> {
  const objectDirectory = await resolveGitDirectory(gitDirectory);
  const resolvedPrs: ResolvedPr[] = [];
  for (const pr of [...input.prs].sort((a, b) => a.number - b.number)) {
    const base = await resolveRevision(objectDirectory, pr.git_base);
    const head = await resolveRevision(objectDirectory, pr.git_head);
    const files = await changedFiles(objectDirectory, base, head);
    const baseConflictPaths = await mergeConflictPaths(
      objectDirectory,
      base,
      head,
    );
    resolvedPrs.push({ input: pr, base, head, files, baseConflictPaths });
  }

  const conflictEdges: ConflictEdge[] = [];
  const ancestryEdges: {
    readonly before: PrNumber;
    readonly after: PrNumber;
  }[] = [];
  for (let leftIndex = 0; leftIndex < resolvedPrs.length; leftIndex += 1) {
    const left = resolvedPrs[leftIndex];
    if (left === undefined) continue;
    for (
      let rightIndex = leftIndex + 1;
      rightIndex < resolvedPrs.length;
      rightIndex += 1
    ) {
      const right = resolvedPrs[rightIndex];
      if (right === undefined) continue;
      const paths = await mergeConflictPaths(
        objectDirectory,
        left.head,
        right.head,
      );
      if (paths.length > 0) {
        conflictEdges.push(
          normalizeConflictEdge({
            a: left.input.number,
            b: right.input.number,
            paths,
          }),
        );
      }
      if (left.head !== right.head) {
        if (await isAncestor(objectDirectory, left.head, right.head)) {
          ancestryEdges.push({
            before: left.input.number,
            after: right.input.number,
          });
        } else if (await isAncestor(objectDirectory, right.head, left.head)) {
          ancestryEdges.push({
            before: right.input.number,
            after: left.input.number,
          });
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

export async function runGit(
  gitDirectory: string,
  args: readonly string[],
  expectedExitCodes: readonly number[],
): Promise<GitResult> {
  const fullArgs = [`--git-dir=${gitDirectory}`, "--no-pager", ...args];
  let child: Deno.ChildProcess;
  try {
    child = new Deno.Command("git", {
      args: fullArgs,
      stdin: "null",
      stdout: "piped",
      stderr: "piped",
      clearEnv: true,
      env: {
        GIT_CONFIG_GLOBAL: "/dev/null",
        GIT_CONFIG_NOSYSTEM: "1",
        GIT_OPTIONAL_LOCKS: "0",
        GIT_TERMINAL_PROMPT: "0",
        LANGUAGE: "C",
        LC_ALL: "C",
      },
    }).spawn();
  } catch (error) {
    throw new GitExecutionError(`could not start git: ${errorMessage(error)}`, {
      cause: error,
    });
  }

  let timedOut = false;
  const timeout = setTimeout(() => {
    timedOut = true;
    try {
      child.kill("SIGKILL");
    } catch {
      // The child may have exited between the timer firing and the signal.
    }
  }, commandTimeoutMilliseconds);
  let output: Deno.CommandOutput;
  try {
    output = await child.output();
  } catch (error) {
    throw new GitExecutionError(
      `could not collect git output: ${errorMessage(error)}`,
      { cause: error },
    );
  } finally {
    clearTimeout(timeout);
  }
  if (timedOut) {
    throw new GitExecutionError(
      `git ${args[0] ?? "command"} timed out after 30 seconds`,
    );
  }
  const stderr = decode(output.stderr);
  if (!expectedExitCodes.includes(output.code)) {
    throw new GitCommandError(args, output.code, stderr);
  }
  return { exitCode: output.code, stdout: output.stdout, stderr };
}

export async function mergeConflictPaths(
  gitDirectory: string,
  left: GitObjectId,
  right: GitObjectId,
): Promise<string[]> {
  const result = await runGit(
    gitDirectory,
    [
      "merge-tree",
      "--write-tree",
      "--name-only",
      "--no-messages",
      "-z",
      left,
      right,
    ],
    [0, 1],
  );
  if (result.exitCode === 0) return [];
  const fields = parseNulList(result.stdout);
  if (fields.length === 0) {
    throw new GitExecutionError(
      "git merge-tree reported a conflict without output",
    );
  }
  return sortedUnique(fields.slice(1));
}

async function resolveGitDirectory(path: string): Promise<string> {
  let absolute: string;
  try {
    absolute = await Deno.realPath(path);
  } catch (error) {
    throw new GitExecutionError(
      `cannot resolve Git directory ${JSON.stringify(path)}: ${
        errorMessage(error)
      }`,
      {
        cause: error,
      },
    );
  }
  let information: Deno.FileInfo;
  try {
    information = await Deno.stat(absolute);
  } catch (error) {
    throw new GitExecutionError(
      `cannot inspect Git directory ${JSON.stringify(absolute)}: ${
        errorMessage(error)
      }`,
      {
        cause: error,
      },
    );
  }
  if (!information.isDirectory) {
    throw new GitExecutionError(
      `Git directory is not a directory: ${absolute}`,
    );
  }
  const dotGit = `${absolute.replace(/\/$/, "")}/.git`;
  return await isDirectory(dotGit) ? dotGit : absolute;
}

async function isDirectory(path: string): Promise<boolean> {
  try {
    return (await Deno.stat(path)).isDirectory;
  } catch (error) {
    if (error instanceof Deno.errors.NotFound) return false;
    throw error;
  }
}

async function resolveRevision(
  gitDirectory: string,
  revision: GitRevision,
): Promise<GitObjectId> {
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

function toNode(pr: ResolvedPr): PrNode {
  const { git_head: _gitHead, git_base: _gitBase, ...metadata } = pr.input;
  return {
    ...metadata,
    files: pr.files,
    base_conflict_paths: pr.baseConflictPaths,
  };
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

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
