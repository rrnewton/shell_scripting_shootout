import { describe, expect, test } from "bun:test";
import { buildPlan } from "../src/planner.ts";
import { renderHuman, renderJson } from "../src/render.ts";
import { pureInputSchema, purePlanningInput } from "../src/schema.ts";

async function fixturePlan() {
  const value: unknown = await Bun.file(new URL("fixtures/pure.json", import.meta.url)).json();
  return buildPlan(purePlanningInput(pureInputSchema.parse(value)));
}

describe("pure planning", () => {
  test("constructs deterministic graph products", async () => {
    const plan = await fixturePlan();
    expect(plain(plan.conflict_edges)).toEqual([{ a: 3, b: 1, paths: ["src/conflict.ts"] }]);
    expect(plain(plan.file_overlap_edges)).toEqual([
      { a: 1, b: 2, paths: ["src/shared.ts"] },
      { a: 1, b: 3, paths: ["src/shared.ts"] },
      { a: 2, b: 3, paths: ["src/shared.ts"] },
    ]);
    expect(plain(plan.ordering_edges)).toEqual([{ before: 1, after: 2, reason: "base-ref" }]);
    expect(plain(plan.stacks)).toEqual([[1, 2]]);
    expect(plain(plan.suggested_landing_batches)).toEqual([[1], [2, 3]]);
    expect(plain(plan.suggested_rebase_plan)).toEqual([
      { pr: 2, after: [1], reasons: ["stack-dependency"] },
      { pr: 3, after: [1], reasons: ["pair-conflict"] },
    ]);
    expect(plain(plan.ready_landing_batches)).toEqual([[1]]);
    expect(plain(plan.ready_now)).toEqual([1]);
    expect(plain(plan.held_prs)).toEqual([
      { pr: 2, reasons: ["draft"] },
      { pr: 3, reasons: ["local-base-conflict", "github-base-conflicting"] },
    ]);
  });

  test("JSON and human rendering are byte-for-byte repeatable", async () => {
    const plan = await fixturePlan();
    expect(renderJson(plan)).toBe(renderJson(plan));
    expect(renderHuman(plan)).toMatchSnapshot();
    expect(renderJson(plan)).toMatchSnapshot();
  });

  test("handles empty and single-PR inputs", async () => {
    const empty = buildPlan({ repository: "empty", nodes: [], conflictEdges: [], ancestryEdges: [] });
    expect(empty.suggested_landing_batches).toEqual([]);
    expect(empty.ready_now).toEqual([]);

    const value: unknown = await Bun.file(new URL("fixtures/pure.json", import.meta.url)).json();
    const fixture = pureInputSchema.parse(value);
    const first = fixture.prs[0];
    if (first === undefined) throw new Error("fixture must contain a PR");
    const single = buildPlan(
      purePlanningInput({ ...fixture, prs: [first], conflict_edges: [], ancestry_edges: [] }),
    );
    expect(plain(single.suggested_landing_batches)).toEqual([[1]]);
    expect(plain(single.ready_now)).toEqual([1]);
  });

  test("reports artificial ordering cycles", () => {
    const input = pureInputSchema.parse({
      schema_version: 1,
      repository: "cycle",
      prs: [pr(1, "one", "two"), pr(2, "two", "one")],
      conflict_edges: [],
      ancestry_edges: [],
    });
    const plan = buildPlan(purePlanningInput(input));
    expect(plain(plan.ordering_cycles)).toEqual([1, 2]);
    expect(plain(plan.suggested_landing_batches)).toEqual([[1], [2]]);
  });
});

function pr(number: number, head_ref: string, base_ref: string) {
  return {
    number,
    title: `PR ${number}`,
    author: null,
    head_ref,
    base_ref,
    draft: false,
    mergeable: "MERGEABLE" as const,
    review_decision: "NONE" as const,
    created_at: "2026-01-01T00:00:00Z",
    updated_at: "2026-01-01T00:00:00Z",
    additions: 0,
    deletions: 0,
    files: [],
    base_conflict_paths: [],
  };
}

function plain(value: unknown): unknown {
  return JSON.parse(JSON.stringify(value)) as unknown;
}
