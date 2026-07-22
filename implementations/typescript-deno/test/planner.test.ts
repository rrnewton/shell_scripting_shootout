import { buildPlan } from "../src/planner.ts";
import { renderHuman, renderJson } from "../src/render.ts";
import { parsePureInput, purePlanningInput } from "../src/schema.ts";
import { assertEquals } from "./assert.ts";

const pureFixture = new URL(
  "../../../fixtures/pure-input.json",
  import.meta.url,
);
const pureGolden = new URL(
  "../../../fixtures/expected/pure-output.json",
  import.meta.url,
);

Deno.test("planner matches canonical JSON byte for byte", async () => {
  const value: unknown = JSON.parse(await Deno.readTextFile(pureFixture));
  const plan = buildPlan(purePlanningInput(parsePureInput(value)));
  assertEquals(renderJson(plan), await Deno.readTextFile(pureGolden));
  assertEquals(
    renderHuman(plan),
    "fixture/example: 8 PRs, 2 conflicts, ready #2, #7, #8\n",
  );
});

Deno.test("planner output is repeatable", async () => {
  const value: unknown = JSON.parse(await Deno.readTextFile(pureFixture));
  const plan = buildPlan(purePlanningInput(parsePureInput(value)));
  assertEquals(renderJson(plan), renderJson(plan));
});

Deno.test("planner handles empty inputs", () => {
  const plan = buildPlan({
    repository: "empty",
    nodes: [],
    conflictEdges: [],
    ancestryEdges: [],
  });
  assertEquals(plan.suggested_landing_batches, []);
  assertEquals(plan.ready_now, []);
});
