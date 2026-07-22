import { describe, expect, test } from "bun:test";
import {
  gitInputSchema,
  pureInputSchema,
  purePlanningInput,
  validateUniqueGitPrs,
} from "../src/schema.ts";

describe("untrusted input validation", () => {
  test("accepts the versioned pure fixture", async () => {
    const value: unknown = await Bun.file(new URL("fixtures/pure.json", import.meta.url)).json();
    expect(pureInputSchema.safeParse(value).success).toBe(true);
  });

  test("rejects incorrectly typed and extra fields", () => {
    const malformed: unknown = {
      schema_version: 1,
      repository: "acme/widgets",
      prs: [{ number: "1" }],
      conflict_edges: [],
      ancestry_edges: [],
      unchecked: true,
    };
    const result = pureInputSchema.safeParse(malformed);
    expect(result.success).toBe(false);
    if (!result.success) {
      expect(result.error.issues.some((issue) => issue.path.join(".") === "prs.0.number")).toBe(true);
      expect(result.error.issues.some((issue) => issue.code === "unrecognized_keys")).toBe(true);
    }
  });

  test("rejects null review state instead of widening the domain", async () => {
    const raw: unknown = await Bun.file(new URL("fixtures/pure.json", import.meta.url)).json();
    const parsed = pureInputSchema.parse(raw);
    const first = parsed.prs[0];
    if (first === undefined) throw new Error("fixture must contain a PR");
    expect(
      pureInputSchema.safeParse({
        ...parsed,
        prs: [{ ...first, review_decision: null }, ...parsed.prs.slice(1)],
      }).success,
    ).toBe(false);
  });

  test("rejects duplicate PR numbers and dangling edges", async () => {
    const raw: unknown = await Bun.file(new URL("fixtures/pure.json", import.meta.url)).json();
    const parsed = pureInputSchema.parse(raw);
    const first = parsed.prs[0];
    if (first === undefined) throw new Error("fixture must contain a PR");
    expect(() => purePlanningInput({ ...parsed, prs: [...parsed.prs, first] })).toThrow(
      "duplicate PR number",
    );
    const dangling = pureInputSchema.parse({
        ...parsed,
        ancestry_edges: [{ before: first.number, after: 999 }],
    });
    expect(() => purePlanningInput(dangling)).toThrow("references an unknown PR");
  });

  test("rejects duplicate head refs in pure and Git inputs", async () => {
    const rawPure: unknown = await Bun.file(new URL("fixtures/pure.json", import.meta.url)).json();
    const pure = pureInputSchema.parse(rawPure);
    const pureFirst = pure.prs[0];
    const pureSecond = pure.prs[1];
    if (pureFirst === undefined || pureSecond === undefined) {
      throw new Error("fixture must contain two PRs");
    }
    expect(() =>
      purePlanningInput({
        ...pure,
        prs: [pureFirst, { ...pureSecond, head_ref: pureFirst.head_ref }, ...pure.prs.slice(2)],
      })
    ).toThrow("head_ref values must be unique");

    const rawGit: unknown = await Bun.file(
      new URL("../../../fixtures/git-input.json", import.meta.url),
    ).json();
    const git = gitInputSchema.parse(rawGit);
    const gitFirst = git.prs[0];
    const gitSecond = git.prs[1];
    if (gitFirst === undefined || gitSecond === undefined) {
      throw new Error("fixture must contain two PRs");
    }
    expect(() =>
      validateUniqueGitPrs({
        ...git,
        prs: [gitFirst, { ...gitSecond, head_ref: gitFirst.head_ref }, ...git.prs.slice(2)],
      })
    ).toThrow("head_ref values must be unique");
  });
});
