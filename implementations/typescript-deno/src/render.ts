import type { Plan, PrNumber } from "./types.ts";

export function renderJson(plan: Plan): string {
  return `${JSON.stringify(plan, null, 2)}\n`;
}

export function renderHuman(plan: Plan): string {
  const ready = plan.ready_now.map((number: PrNumber) => `#${number}`).join(
    ", ",
  );
  return `${plan.repository}: ${plan.nodes.length} PRs, ${plan.conflict_edges.length} conflicts, ready ${ready}\n`;
}
