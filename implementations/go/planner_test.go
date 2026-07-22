package main

import (
	"reflect"
	"testing"
)

func testPR(number PRNumber) PullRequest {
	author := "alice"
	return PullRequest{
		Number: number, Title: "PR " + number.String(), Author: &author,
		HeadRef: "feature/" + number.String(), BaseRef: "main", Mergeable: MergeableYes,
		ReviewDecision: ReviewApproved, CreatedAt: "2026-01-01T00:00:00Z",
		UpdatedAt: "2026-01-02T00:00:00Z", Additions: int64(number),
		Files: []string{}, BaseConflictPaths: []string{},
	}
}

func TestPlannerEmptyAndSingle(t *testing.T) {
	empty := makePlan(AnalysisInput{Repository: "acme/widgets", PRs: []PullRequest{}, ConflictEdges: []ConflictEdge{}, AncestryEdges: []AncestryEdge{}})
	if len(empty.SuggestedLandingBatches) != 0 || len(empty.ReadyNow) != 0 {
		t.Fatalf("unexpected empty plan: %+v", empty)
	}
	one := testPR(1)
	single := makePlan(AnalysisInput{Repository: "acme/widgets", PRs: []PullRequest{one}, ConflictEdges: []ConflictEdge{}, AncestryEdges: []AncestryEdge{}})
	if !reflect.DeepEqual(single.SuggestedLandingBatches, [][]PRNumber{{1}}) || !reflect.DeepEqual(single.ReadyNow, []PRNumber{1}) {
		t.Fatalf("unexpected single plan: %+v", single)
	}
}

func TestPlannerStacksHoldsConflictsAndOverlaps(t *testing.T) {
	first := testPR(1)
	first.Files = []string{"common.txt", "first.txt"}
	second := testPR(2)
	second.BaseRef = first.HeadRef
	second.Draft = true
	second.Files = []string{"common.txt"}
	third := testPR(3)
	third.BaseRef = second.HeadRef
	third.Files = []string{"third.txt"}
	plan := makePlan(AnalysisInput{
		Repository: "acme/widgets", PRs: []PullRequest{first, second, third},
		ConflictEdges: []ConflictEdge{{A: 1, B: 3, Paths: []string{"conflict.txt"}}},
		AncestryEdges: []AncestryEdge{},
	})
	if !reflect.DeepEqual(plan.Stacks, [][]PRNumber{{1, 2, 3}}) {
		t.Fatalf("stacks = %v", plan.Stacks)
	}
	if !reflect.DeepEqual(plan.SuggestedLandingBatches, [][]PRNumber{{1}, {2}, {3}}) {
		t.Fatalf("batches = %v", plan.SuggestedLandingBatches)
	}
	wantHeld := []HeldPullRequest{
		{PR: 2, Reasons: []string{"draft"}},
		{PR: 3, Reasons: []string{"depends-on-held:#2"}},
	}
	if !reflect.DeepEqual(plan.HeldPRs, wantHeld) {
		t.Fatalf("held = %v, want %v", plan.HeldPRs, wantHeld)
	}
	if !reflect.DeepEqual(plan.ReadyLandingBatches, [][]PRNumber{{1}}) {
		t.Fatalf("ready batches = %v", plan.ReadyLandingBatches)
	}
	if !reflect.DeepEqual(plan.FileOverlapEdges, []ConflictEdge{{A: 1, B: 2, Paths: []string{"common.txt"}}}) {
		t.Fatalf("overlaps = %v", plan.FileOverlapEdges)
	}
}

func TestPlannerReportsOrderingCycle(t *testing.T) {
	first := testPR(1)
	second := testPR(2)
	first.BaseRef = second.HeadRef
	plan := makePlan(AnalysisInput{
		Repository: "acme/widgets", PRs: []PullRequest{first, second}, ConflictEdges: []ConflictEdge{},
		AncestryEdges: []AncestryEdge{{Before: 1, After: 2}},
	})
	if !reflect.DeepEqual(plan.OrderingCycles, []PRNumber{1, 2}) {
		t.Fatalf("cycles = %v", plan.OrderingCycles)
	}
}
