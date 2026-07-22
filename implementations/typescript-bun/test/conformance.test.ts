import { describe, expect, test } from "bun:test";
import { buildPlan } from "../src/planner.ts";
import { renderHuman, renderJson } from "../src/render.ts";
import { pureInputSchema, purePlanningInput } from "../src/schema.ts";

const repositoryRoot = new URL("../../../", import.meta.url);

describe("shared conformance fixtures", () => {
  test("matches the canonical pure JSON byte for byte", async () => {
    const raw: unknown = await Bun.file(new URL("fixtures/pure-input.json", repositoryRoot)).json();
    const plan = buildPlan(purePlanningInput(pureInputSchema.parse(raw)));
    const expected = await Bun.file(
      new URL("fixtures/expected/pure-output.json", repositoryRoot),
    ).text();
    expect(renderJson(plan)).toBe(expected);
  });

  test("matches the canonical pure human summary", async () => {
    const raw: unknown = await Bun.file(new URL("fixtures/pure-input.json", repositoryRoot)).json();
    const plan = buildPlan(purePlanningInput(pureInputSchema.parse(raw)));
    expect(renderHuman(plan)).toBe("fixture/example: 8 PRs, 2 conflicts, ready #2, #7, #8\n");
  });
});
