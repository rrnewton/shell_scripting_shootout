import std/[json, strutils]

import model

proc renderJson*(plan: Plan): string =
  pretty(toJson(plan), 2) & "\n"

proc prList(numbers: openArray[PrNumber]): string =
  if numbers.len == 0:
    return "(none)"
  var items: seq[string]
  for number in numbers:
    items.add("#" & $number)
  items.join(", ")

proc renderHuman*(plan: Plan): string =
  result.add("Repository: " & plan.repository & "\n")
  result.add("Pull requests: " & $plan.nodes.len & "\n")
  result.add("Held pull requests:\n")
  if plan.heldPrs.len == 0:
    result.add("  (none)\n")
  else:
    for item in plan.heldPrs:
      result.add("  #" & $item.pr & ": " & item.reasons.join(", ") & "\n")
  result.add("Ordering cycles:\n")
  if plan.orderingCycles.len == 0:
    result.add("  (none)\n")
  else:
    result.add("  " & prList(plan.orderingCycles) & "\n")
  result.add("Suggested landing batches:\n")
  if plan.suggestedLandingBatches.len == 0:
    result.add("  (none)\n")
  else:
    for index, batch in plan.suggestedLandingBatches:
      result.add("  " & $(index + 1) & ": " & prList(batch) & "\n")
  result.add("Ready landing batches:\n")
  if plan.readyLandingBatches.len == 0:
    result.add("  (none)\n")
  else:
    for index, batch in plan.readyLandingBatches:
      result.add("  " & $(index + 1) & ": " & prList(batch) & "\n")
  result.add("Ready now: " & prList(plan.readyNow) & "\n")
  result.add("Suggested rebase plan:\n")
  if plan.suggestedRebasePlan.len == 0:
    result.add("  (none)\n")
  else:
    for item in plan.suggestedRebasePlan:
      result.add("  #" & $item.pr & " after " & prList(item.after) & ": " &
        item.reasons.join(", ") & "\n")
