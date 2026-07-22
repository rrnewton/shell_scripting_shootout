package main

import (
	"bytes"
	"testing"
)

func TestRenderUsesArraysAndIsDeterministic(t *testing.T) {
	plan := makePlan(AnalysisInput{Repository: "acme/widgets", PRs: []PullRequest{}, ConflictEdges: []ConflictEdge{}, AncestryEdges: []AncestryEdge{}})
	first, err := renderJSON(plan)
	if err != nil {
		t.Fatal(err)
	}
	second, err := renderJSON(plan)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(first, second) {
		t.Fatal("JSON output changed between renders")
	}
	if bytes.Contains(first, []byte("null")) {
		t.Fatalf("JSON contains null slice: %s", first)
	}
}

func TestHumanEmptyGolden(t *testing.T) {
	plan := makePlan(AnalysisInput{Repository: "acme/widgets", PRs: []PullRequest{}, ConflictEdges: []ConflictEdge{}, AncestryEdges: []AncestryEdge{}})
	want := "Repository: acme/widgets\n" +
		"Pull requests: 0\n" +
		"Held pull requests:\n  (none)\n" +
		"Ordering cycles:\n  (none)\n" +
		"Suggested landing batches:\n  (none)\n" +
		"Ready landing batches:\n  (none)\n" +
		"Ready now: (none)\n" +
		"Suggested rebase plan:\n  (none)\n"
	if got := string(renderHuman(plan)); got != want {
		t.Fatalf("human output:\n%s\nwant:\n%s", got, want)
	}
}
