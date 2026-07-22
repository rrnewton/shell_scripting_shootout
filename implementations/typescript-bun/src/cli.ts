#!/usr/bin/env bun

import { ZodError } from "zod";
import { analyzeGit, GitCommandError } from "./git.ts";
import { buildPlan } from "./planner.ts";
import { gitInputSchema, pureInputSchema, purePlanningInput } from "./schema.ts";
import { renderHuman, renderJson } from "./render.ts";

const usage = `Usage:
  pr-plan pure --input FILE [--human]
  pr-plan git --input FILE --git-dir DIR [--human]

Options:
  --input FILE    Read the version 1 input document from FILE
  --git-dir DIR   Analyze objects in this Git directory
  --human         Emit deterministic human-readable output instead of JSON
  -h, --help      Show this help
`;

interface CliOptions {
  readonly mode: "pure" | "git";
  readonly input: string;
  readonly gitDirectory?: string;
  readonly human: boolean;
}

class UsageError extends Error {}
class InputError extends Error {}

export async function main(args: readonly string[]): Promise<number> {
  if (args.includes("--help") || args.includes("-h")) {
    process.stdout.write(usage);
    return 0;
  }

  try {
    const options = parseArgs(args);
    const input = await readJson(options.input);
    const planningInput = options.mode === "pure"
      ? parsePureInput(input)
      : await analyzeGit(parseGitInput(input), requiredGitDirectory(options));
    const output = options.human ? renderHuman(buildPlan(planningInput)) : renderJson(buildPlan(planningInput));
    process.stdout.write(output);
    return 0;
  } catch (error) {
    if (error instanceof UsageError) {
      process.stderr.write(`error: ${error.message}\n\n${usage}`);
      return 2;
    }
    if (error instanceof InputError || error instanceof ZodError) {
      process.stderr.write(`input error: ${formatError(error)}\n`);
      return 2;
    }
    if (error instanceof GitCommandError) {
      process.stderr.write(`git error: ${error.message}\n`);
      return 1;
    }
    process.stderr.write(`error: ${formatError(error)}\n`);
    return 1;
  }
}

function parseArgs(args: readonly string[]): CliOptions {
  const mode = args[0];
  if (mode !== "pure" && mode !== "git") throw new UsageError("expected mode 'pure' or 'git'");

  let input: string | undefined;
  let gitDirectory: string | undefined;
  let human = false;
  for (let index = 1; index < args.length; index += 1) {
    const argument = args[index];
    if (argument === "--human") {
      if (human) throw new UsageError("--human was provided more than once");
      human = true;
    } else if (argument === "--input") {
      if (input !== undefined) throw new UsageError("--input was provided more than once");
      input = optionValue(args, index, "--input");
      index += 1;
    } else if (argument === "--git-dir") {
      if (gitDirectory !== undefined) throw new UsageError("--git-dir was provided more than once");
      gitDirectory = optionValue(args, index, "--git-dir");
      index += 1;
    } else {
      throw new UsageError(`unknown argument: ${argument ?? "<missing>"}`);
    }
  }
  if (input === undefined) throw new UsageError("--input is required");
  if (mode === "git" && gitDirectory === undefined) throw new UsageError("--git-dir is required in git mode");
  if (mode === "pure" && gitDirectory !== undefined) throw new UsageError("--git-dir is only valid in git mode");
  return gitDirectory === undefined
    ? { mode, input, human }
    : { mode, input, gitDirectory, human };
}

function optionValue(args: readonly string[], index: number, name: string): string {
  const value = args[index + 1];
  if (value === undefined || value.startsWith("--")) throw new UsageError(`${name} requires a value`);
  return value;
}

async function readJson(path: string): Promise<unknown> {
  let text: string;
  try {
    text = await Bun.file(path).text();
  } catch (error) {
    throw new InputError(`cannot read ${JSON.stringify(path)}: ${formatError(error)}`);
  }
  try {
    const parsed: unknown = JSON.parse(text);
    return parsed;
  } catch (error) {
    throw new InputError(`invalid JSON in ${JSON.stringify(path)}: ${formatError(error)}`);
  }
}

function parsePureInput(value: unknown) {
  const result = pureInputSchema.safeParse(value);
  if (!result.success) throw result.error;
  try {
    return purePlanningInput(result.data);
  } catch (error) {
    throw new InputError(formatError(error));
  }
}

function parseGitInput(value: unknown) {
  const result = gitInputSchema.safeParse(value);
  if (!result.success) throw result.error;
  return result.data;
}

function requiredGitDirectory(options: CliOptions): string {
  if (options.gitDirectory === undefined) throw new Error("internal CLI invariant failed");
  return options.gitDirectory;
}

function formatError(error: unknown): string {
  if (error instanceof ZodError) {
    return error.issues
      .map((issue) => `${issue.path.length > 0 ? issue.path.join(".") : "input"}: ${issue.message}`)
      .join("; ");
  }
  return error instanceof Error ? error.message : String(error);
}

if (import.meta.main) process.exitCode = await main(Bun.argv.slice(2));
