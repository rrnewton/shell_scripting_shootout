import type {
  AncestryEdge,
  ConflictEdge,
  GitInput,
  GitInputPr,
  GitObjectId,
  GitRevision,
  Mergeable,
  PlanningInput,
  PrNode,
  PrNumber,
  PureInput,
  ReviewDecision,
} from "./types.ts";

export class ValidationError extends Error {
  constructor(path: string, message: string) {
    super(`${path}: ${message}`);
    this.name = "ValidationError";
  }
}

type JsonObject = Record<string, unknown>;

const commonPrKeys = [
  "number",
  "title",
  "author",
  "head_ref",
  "base_ref",
  "draft",
  "mergeable",
  "review_decision",
  "created_at",
  "updated_at",
  "additions",
  "deletions",
] as const;

const timestampPattern =
  /^\d{4}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12]\d|3[01])T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d+)?(?:Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)$/;

export function parsePureInput(value: unknown): PureInput {
  const root = object(value, "$", [
    "schema_version",
    "repository",
    "prs",
    "conflict_edges",
    "ancestry_edges",
  ]);
  literalOne(root["schema_version"], "$.schema_version");
  const repository = nonEmptyString(root["repository"], "$.repository");
  const prs = array(root["prs"], "$.prs").map((item, index) =>
    purePr(item, `$.prs[${index}]`)
  );
  validateUniquePrs(prs);
  const known = new Set(prs.map((pr) => pr.number));
  const conflictEdges = array(root["conflict_edges"], "$.conflict_edges").map((
    item,
    index,
  ) => conflictEdge(item, `$.conflict_edges[${index}]`, known));
  validateUniqueConflictEdges(conflictEdges);
  const ancestryEdges = array(root["ancestry_edges"], "$.ancestry_edges").map((
    item,
    index,
  ) => ancestryEdge(item, `$.ancestry_edges[${index}]`, known));
  validateUniqueAncestryEdges(ancestryEdges);
  return {
    schema_version: 1,
    repository,
    prs,
    conflict_edges: conflictEdges,
    ancestry_edges: ancestryEdges,
  };
}

export function parseGitInput(value: unknown): GitInput {
  const root = object(value, "$", ["schema_version", "repository", "prs"]);
  literalOne(root["schema_version"], "$.schema_version");
  const prs = array(root["prs"], "$.prs").map((item, index) =>
    gitPr(item, `$.prs[${index}]`)
  );
  validateUniquePrs(prs);
  return {
    schema_version: 1,
    repository: nonEmptyString(root["repository"], "$.repository"),
    prs,
  };
}

export function purePlanningInput(input: PureInput): PlanningInput {
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

export function gitObjectId(value: string): GitObjectId {
  if (!/^[0-9a-f]{40}(?:[0-9a-f]{24})?$/.test(value)) {
    throw new Error(`Git returned invalid object ID: ${JSON.stringify(value)}`);
  }
  return value as GitObjectId;
}

function purePr(value: unknown, path: string): PrNode {
  const item = object(value, path, [
    ...commonPrKeys,
    "files",
    "base_conflict_paths",
  ]);
  return {
    ...commonPr(item, path),
    files: paths(item["files"], `${path}.files`),
    base_conflict_paths: paths(
      item["base_conflict_paths"],
      `${path}.base_conflict_paths`,
    ),
  };
}

function gitPr(value: unknown, path: string): GitInputPr {
  const item = object(value, path, [...commonPrKeys, "git_head", "git_base"]);
  return {
    ...commonPr(item, path),
    git_head: revision(item["git_head"], `${path}.git_head`),
    git_base: revision(item["git_base"], `${path}.git_base`),
  };
}

function commonPr(
  item: JsonObject,
  path: string,
): Omit<PrNode, "files" | "base_conflict_paths"> {
  return {
    number: prNumber(item["number"], `${path}.number`),
    title: nonEmptyString(item["title"], `${path}.title`),
    author: nullableString(item["author"], `${path}.author`),
    head_ref: nonEmptyString(item["head_ref"], `${path}.head_ref`),
    base_ref: nonEmptyString(item["base_ref"], `${path}.base_ref`),
    draft: boolean(item["draft"], `${path}.draft`),
    mergeable: oneOf(item["mergeable"], `${path}.mergeable`, [
      "MERGEABLE",
      "CONFLICTING",
      "UNKNOWN",
    ]),
    review_decision: oneOf(item["review_decision"], `${path}.review_decision`, [
      "APPROVED",
      "CHANGES_REQUESTED",
      "REVIEW_REQUIRED",
      "NONE",
    ]),
    created_at: timestamp(item["created_at"], `${path}.created_at`),
    updated_at: timestamp(item["updated_at"], `${path}.updated_at`),
    additions: nonNegativeInteger(item["additions"], `${path}.additions`),
    deletions: nonNegativeInteger(item["deletions"], `${path}.deletions`),
  };
}

function conflictEdge(
  value: unknown,
  path: string,
  known: ReadonlySet<PrNumber>,
): ConflictEdge {
  const item = object(value, path, ["a", "b", "paths"]);
  const a = knownPrNumber(item["a"], `${path}.a`, known);
  const b = knownPrNumber(item["b"], `${path}.b`, known);
  if (a === b) fail(path, "conflict edge must join two different PRs");
  const edgePaths = paths(item["paths"], `${path}.paths`);
  if (edgePaths.length === 0) fail(`${path}.paths`, "must not be empty");
  return { a, b, paths: edgePaths };
}

function ancestryEdge(
  value: unknown,
  path: string,
  known: ReadonlySet<PrNumber>,
): AncestryEdge {
  const item = object(value, path, ["before", "after"]);
  const before = knownPrNumber(item["before"], `${path}.before`, known);
  const after = knownPrNumber(item["after"], `${path}.after`, known);
  if (before === after) fail(path, "ancestry edge must join two different PRs");
  return { before, after };
}

function object(
  value: unknown,
  path: string,
  keys: readonly string[],
): JsonObject {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    fail(path, "expected an object");
  }
  const result = value as JsonObject;
  const expected = new Set(keys);
  const missing = keys.filter((key) => !Object.hasOwn(result, key));
  const unknown = Object.keys(result).filter((key) => !expected.has(key)).sort(
    compareText,
  );
  if (missing.length > 0) fail(path, `missing field(s): ${missing.join(", ")}`);
  if (unknown.length > 0) fail(path, `unknown field(s): ${unknown.join(", ")}`);
  return result;
}

function array(value: unknown, path: string): readonly unknown[] {
  if (!Array.isArray(value)) fail(path, "expected an array");
  return value;
}

function nonEmptyString(value: unknown, path: string): string {
  if (typeof value !== "string") fail(path, "expected a string");
  if (value.length === 0) fail(path, "must not be empty");
  if (value.includes("\0")) fail(path, "must not contain NUL");
  return value;
}

function nullableString(value: unknown, path: string): string | null {
  return value === null ? null : nonEmptyString(value, path);
}

function positiveInteger(value: unknown, path: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value)) {
    fail(path, "expected a safe integer");
  }
  if (value <= 0) fail(path, "must be positive");
  return value;
}

function nonNegativeInteger(value: unknown, path: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value)) {
    fail(path, "expected a safe integer");
  }
  if (value < 0) fail(path, "must not be negative");
  return value;
}

function boolean(value: unknown, path: string): boolean {
  if (typeof value !== "boolean") fail(path, "expected a boolean");
  return value;
}

function oneOf<T extends Mergeable | ReviewDecision>(
  value: unknown,
  path: string,
  allowed: readonly T[],
): T {
  if (
    typeof value !== "string" ||
    !allowed.some((candidate) => candidate === value)
  ) {
    fail(path, `expected one of: ${allowed.join(", ")}`);
  }
  return value as T;
}

function timestamp(value: unknown, path: string): string {
  const text = nonEmptyString(value, path);
  if (
    !timestampPattern.test(text) ||
    !hasValidCalendarDate(text) ||
    !Number.isFinite(Date.parse(text))
  ) {
    fail(path, "expected an RFC 3339 timestamp with a UTC offset");
  }
  return text;
}

function hasValidCalendarDate(value: string): boolean {
  const year = Number(value.slice(0, 4));
  const month = Number(value.slice(5, 7));
  const day = Number(value.slice(8, 10));
  const leapYear = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  const maximumDay = month === 2
    ? leapYear ? 29 : 28
    : month === 4 || month === 6 || month === 9 || month === 11
    ? 30
    : 31;
  return day <= maximumDay;
}

function paths(value: unknown, path: string): readonly string[] {
  const result = array(value, path).map((item, index) => {
    const text = nonEmptyString(item, `${path}[${index}]`);
    if (text.startsWith("/")) {
      fail(`${path}[${index}]`, "expected a repository-relative path");
    }
    return text;
  });
  if (new Set(result).size !== result.length) {
    fail(path, "paths must be unique");
  }
  return result;
}

function revision(value: unknown, path: string): GitRevision {
  const text = nonEmptyString(value, path);
  if (text.startsWith("-") || hasControlCharacter(text)) {
    fail(
      path,
      "revision must not start with '-' or contain control characters",
    );
  }
  return text as GitRevision;
}

function prNumber(value: unknown, path: string): PrNumber {
  return positiveInteger(value, path) as PrNumber;
}

function knownPrNumber(
  value: unknown,
  path: string,
  known: ReadonlySet<PrNumber>,
): PrNumber {
  const number = prNumber(value, path);
  if (!known.has(number)) fail(path, `unknown PR: ${number}`);
  return number;
}

function literalOne(value: unknown, path: string): asserts value is 1 {
  if (value !== 1) fail(path, "expected schema version 1");
}

function validateUniquePrs(
  prs: readonly { readonly number: PrNumber }[],
): void {
  const duplicateNumber = duplicate(prs.map((pr) => pr.number));
  if (duplicateNumber !== undefined) {
    fail("$.prs", `duplicate PR number: ${duplicateNumber}`);
  }
}

function validateUniqueConflictEdges(edges: readonly ConflictEdge[]): void {
  const duplicateKey = duplicate(edges.map((edge) => edgeKey(edge.a, edge.b)));
  if (duplicateKey !== undefined) {
    fail("$.conflict_edges", `duplicate conflict edge: ${duplicateKey}`);
  }
}

function validateUniqueAncestryEdges(edges: readonly AncestryEdge[]): void {
  const duplicateKey = duplicate(
    edges.map((edge) => `${edge.before}>${edge.after}`),
  );
  if (duplicateKey !== undefined) {
    fail("$.ancestry_edges", `duplicate ancestry edge: ${duplicateKey}`);
  }
}

function duplicate<T>(values: readonly T[]): T | undefined {
  const seen = new Set<T>();
  for (const value of values) {
    if (seen.has(value)) return value;
    seen.add(value);
  }
  return undefined;
}

function edgeKey(a: PrNumber, b: PrNumber): string {
  return a < b ? `${a}:${b}` : `${b}:${a}`;
}

function compareText(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0;
}

function hasControlCharacter(value: string): boolean {
  for (const character of value) {
    const code = character.charCodeAt(0);
    if (code <= 0x1f || code === 0x7f) return true;
  }
  return false;
}

function fail(path: string, message: string): never {
  throw new ValidationError(path, message);
}
