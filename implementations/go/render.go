package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
)

func renderJSON(plan Plan) ([]byte, error) {
	result, err := json.MarshalIndent(plan, "", "  ")
	if err != nil {
		return nil, err
	}
	return append(result, '\n'), nil
}

func prList(numbers []PRNumber) string {
	if len(numbers) == 0 {
		return "(none)"
	}
	items := make([]string, len(numbers))
	for index, number := range numbers {
		items[index] = "#" + number.String()
	}
	return strings.Join(items, ", ")
}

func renderHuman(plan Plan) []byte {
	var output bytes.Buffer
	fmt.Fprintf(&output, "Repository: %s\n", plan.Repository)
	fmt.Fprintf(&output, "Pull requests: %d\n", len(plan.Nodes))
	output.WriteString("Held pull requests:\n")
	if len(plan.HeldPRs) == 0 {
		output.WriteString("  (none)\n")
	} else {
		for _, item := range plan.HeldPRs {
			fmt.Fprintf(&output, "  #%d: %s\n", item.PR, strings.Join(item.Reasons, ", "))
		}
	}
	output.WriteString("Ordering cycles:\n")
	if len(plan.OrderingCycles) == 0 {
		output.WriteString("  (none)\n")
	} else {
		fmt.Fprintf(&output, "  %s\n", prList(plan.OrderingCycles))
	}
	output.WriteString("Suggested landing batches:\n")
	if len(plan.SuggestedLandingBatches) == 0 {
		output.WriteString("  (none)\n")
	} else {
		for index, batch := range plan.SuggestedLandingBatches {
			fmt.Fprintf(&output, "  %d: %s\n", index+1, prList(batch))
		}
	}
	output.WriteString("Ready landing batches:\n")
	if len(plan.ReadyLandingBatches) == 0 {
		output.WriteString("  (none)\n")
	} else {
		for index, batch := range plan.ReadyLandingBatches {
			fmt.Fprintf(&output, "  %d: %s\n", index+1, prList(batch))
		}
	}
	fmt.Fprintf(&output, "Ready now: %s\n", prList(plan.ReadyNow))
	output.WriteString("Suggested rebase plan:\n")
	if len(plan.SuggestedRebasePlan) == 0 {
		output.WriteString("  (none)\n")
	} else {
		for _, item := range plan.SuggestedRebasePlan {
			fmt.Fprintf(&output, "  #%d after %s: %s\n", item.PR, prList(item.After), strings.Join(item.Reasons, ", "))
		}
	}
	return output.Bytes()
}
