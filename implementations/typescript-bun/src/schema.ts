import { z } from "zod";
import type {
  ConflictEdge,
  GitObjectId,
  PlanningInput,
  PrNode,
  PrNumber,
} from "./types.ts";

const prNumberSchema = z.number().int().positive().transform((value) => value as PrNumber);
const nonEmpty = z.string().min(1);
const pathSchema = nonEmpty.refine((path) => !path.includes("\0"), "path contains NUL");
const pathsSchema = z.array(pathSchema);

const commonPrSchema = z.strictObject({
  number: prNumberSchema,
  title: nonEmpty,
  author: z.string().min(1).nullable(),
  head_ref: nonEmpty,
  base_ref: nonEmpty,
  draft: z.boolean(),
  mergeable: z.enum(["MERGEABLE", "CONFLICTING", "UNKNOWN"]),
  review_decision: z.enum(["APPROVED", "CHANGES_REQUESTED", "REVIEW_REQUIRED", "NONE"]),
  created_at: z.iso.datetime({ offset: true }),
  updated_at: z.iso.datetime({ offset: true }),
  additions: z.number().int().nonnegative(),
  deletions: z.number().int().nonnegative(),
});

const purePrSchema = commonPrSchema.extend({
  files: pathsSchema,
  base_conflict_paths: pathsSchema,
});

const revisionSchema = nonEmpty
  .refine(
    (revision) => !revision.startsWith("-") && !/[\u0000-\u001f\u007f]/.test(revision),
    "revision must not start with '-' or contain control characters",
  )
  .brand<"GitRevision">();

const gitPrSchema = commonPrSchema.extend({
  git_head: revisionSchema,
  git_base: revisionSchema,
});

const conflictEdgeSchema = z.strictObject({
  a: prNumberSchema,
  b: prNumberSchema,
  paths: pathsSchema.min(1),
});

const ancestryEdgeSchema = z.strictObject({
  before: prNumberSchema,
  after: prNumberSchema,
});

export const pureInputSchema = z.strictObject({
  schema_version: z.literal(1),
  repository: nonEmpty,
  prs: z.array(purePrSchema),
  conflict_edges: z.array(conflictEdgeSchema),
  ancestry_edges: z.array(ancestryEdgeSchema),
});

export const gitInputSchema = z.strictObject({
  schema_version: z.literal(1),
  repository: nonEmpty,
  prs: z.array(gitPrSchema),
});

export type PureInput = z.infer<typeof pureInputSchema>;
export type GitInput = z.infer<typeof gitInputSchema>;
export type GitInputPr = GitInput["prs"][number];
export type GitRevision = GitInputPr["git_head"];

function duplicate<T>(values: readonly T[]): T | undefined {
  const seen = new Set<T>();
  for (const value of values) {
    if (seen.has(value)) return value;
    seen.add(value);
  }
  return undefined;
}

export function validatePureReferences(input: PureInput): void {
  const duplicateNumber = duplicate(input.prs.map((pr) => pr.number));
  if (duplicateNumber !== undefined) throw new Error(`duplicate PR number: ${duplicateNumber}`);

  const numbers = new Set(input.prs.map((pr) => pr.number));
  const edgeKeys: string[] = [];
  for (const edge of input.conflict_edges) {
    if (edge.a === edge.b) throw new Error(`conflict edge ${edge.a}-${edge.b} is a self edge`);
    if (!numbers.has(edge.a) || !numbers.has(edge.b)) {
      throw new Error(`conflict edge ${edge.a}-${edge.b} references an unknown PR`);
    }
    edgeKeys.push(edgeKey(edge.a, edge.b));
  }
  const duplicateConflict = duplicate(edgeKeys);
  if (duplicateConflict !== undefined) throw new Error(`duplicate conflict edge: ${duplicateConflict}`);

  const ancestryKeys: string[] = [];
  for (const edge of input.ancestry_edges) {
    if (edge.before === edge.after) {
      throw new Error(`ancestry edge ${edge.before}-${edge.after} is a self edge`);
    }
    if (!numbers.has(edge.before) || !numbers.has(edge.after)) {
      throw new Error(`ancestry edge ${edge.before}-${edge.after} references an unknown PR`);
    }
    ancestryKeys.push(`${edge.before}>${edge.after}`);
  }
  const duplicateAncestry = duplicate(ancestryKeys);
  if (duplicateAncestry !== undefined) {
    throw new Error(`duplicate ancestry edge: ${duplicateAncestry}`);
  }
}

export function validateUniqueGitPrs(input: GitInput): void {
  const duplicateNumber = duplicate(input.prs.map((pr) => pr.number));
  if (duplicateNumber !== undefined) throw new Error(`duplicate PR number: ${duplicateNumber}`);
}

export function purePlanningInput(input: PureInput): PlanningInput {
  validatePureReferences(input);
  return {
    repository: input.repository,
    nodes: input.prs.map(normalizeNode),
    conflictEdges: input.conflict_edges.map(normalizeConflictEdge),
    ancestryEdges: input.ancestry_edges,
  };
}

export function normalizeNode(pr: PrNode): PrNode {
  return {
    ...pr,
    files: sortedUnique(pr.files),
    base_conflict_paths: sortedUnique(pr.base_conflict_paths),
  };
}

export function normalizeConflictEdge(edge: ConflictEdge): ConflictEdge {
  return { ...edge, paths: sortedUnique(edge.paths) };
}

export function sortedUnique(values: readonly string[]): string[] {
  return [...new Set(values)].sort(compareText);
}

export function edgeKey(a: PrNumber, b: PrNumber): string {
  return a < b ? `${a}:${b}` : `${b}:${a}`;
}

export function gitObjectId(value: string): GitObjectId {
  if (!/^[0-9a-f]{40}(?:[0-9a-f]{24})?$/.test(value)) {
    throw new Error(`Git returned invalid object ID: ${JSON.stringify(value)}`);
  }
  return value as GitObjectId;
}

function compareText(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0;
}
