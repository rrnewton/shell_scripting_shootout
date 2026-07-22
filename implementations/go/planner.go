package main

import (
	"sort"
	"strconv"
)

type numberSet map[PRNumber]struct{}

func (set numberSet) add(number PRNumber) { set[number] = struct{}{} }

func (set numberSet) contains(number PRNumber) bool {
	_, ok := set[number]
	return ok
}

func sortedNumbers(set numberSet) []PRNumber {
	result := make([]PRNumber, 0, len(set))
	for number := range set {
		result = append(result, number)
	}
	sort.Slice(result, func(i, j int) bool { return result[i] < result[j] })
	return result
}

func orderingEdges(data AnalysisInput) []OrderingEdge {
	edges := make(map[prPair]OrderingEdge)
	byHead := make(map[string]PRNumber, len(data.PRs))
	for _, pr := range data.PRs {
		byHead[pr.HeadRef] = pr.Number
	}
	for _, pr := range data.PRs {
		if parent, ok := byHead[pr.BaseRef]; ok && parent != pr.Number {
			pair := prPair{parent, pr.Number}
			edges[pair] = OrderingEdge{Before: parent, After: pr.Number, Reason: "base-ref"}
		}
	}
	for _, ancestry := range data.AncestryEdges {
		pair := prPair{ancestry.Before, ancestry.After}
		if _, exists := edges[pair]; !exists {
			edges[pair] = OrderingEdge{Before: ancestry.Before, After: ancestry.After, Reason: "ancestry"}
		}
	}
	result := make([]OrderingEdge, 0, len(edges))
	for _, edge := range edges {
		result = append(result, edge)
	}
	sort.Slice(result, func(i, j int) bool {
		if result[i].Before != result[j].Before {
			return result[i].Before < result[j].Before
		}
		return result[i].After < result[j].After
	})
	return result
}

func fileOverlaps(prs []PullRequest) []ConflictEdge {
	fileSets := make(map[PRNumber]map[string]struct{}, len(prs))
	for _, pr := range prs {
		files := make(map[string]struct{}, len(pr.Files))
		for _, path := range pr.Files {
			files[path] = struct{}{}
		}
		fileSets[pr.Number] = files
	}
	result := make([]ConflictEdge, 0)
	for leftIndex, left := range prs {
		for _, right := range prs[leftIndex+1:] {
			paths := make([]string, 0)
			for path := range fileSets[left.Number] {
				if _, shared := fileSets[right.Number][path]; shared {
					paths = append(paths, path)
				}
			}
			if len(paths) != 0 {
				sort.Strings(paths)
				result = append(result, ConflictEdge{A: left.Number, B: right.Number, Paths: paths})
			}
		}
	}
	return result
}

func hasPath(adjacency map[PRNumber]numberSet, start, target PRNumber, skip prPair) bool {
	pending := []PRNumber{start}
	seen := make(numberSet)
	for len(pending) != 0 {
		last := len(pending) - 1
		current := pending[last]
		pending = pending[:last]
		if seen.contains(current) {
			continue
		}
		seen.add(current)
		for child := range adjacency[current] {
			if current == skip.First && child == skip.Second {
				continue
			}
			if child == target {
				return true
			}
			pending = append(pending, child)
		}
	}
	return false
}

func buildStacks(edges []OrderingEdge) [][]PRNumber {
	adjacency := make(map[PRNumber]numberSet)
	for _, edge := range edges {
		if adjacency[edge.Before] == nil {
			adjacency[edge.Before] = make(numberSet)
		}
		adjacency[edge.Before].add(edge.After)
	}
	reduced := make([]OrderingEdge, 0, len(edges))
	for _, edge := range edges {
		if !hasPath(adjacency, edge.Before, edge.After, prPair{edge.Before, edge.After}) {
			reduced = append(reduced, edge)
		}
	}
	children := make(map[PRNumber]numberSet)
	parents := make(map[PRNumber]numberSet)
	involved := make(numberSet)
	for _, edge := range reduced {
		if children[edge.Before] == nil {
			children[edge.Before] = make(numberSet)
		}
		if parents[edge.After] == nil {
			parents[edge.After] = make(numberSet)
		}
		children[edge.Before].add(edge.After)
		parents[edge.After].add(edge.Before)
		involved.add(edge.Before)
		involved.add(edge.After)
	}
	result := make([][]PRNumber, 0)
	var visit func(PRNumber, []PRNumber)
	visit = func(node PRNumber, path []PRNumber) {
		descendants := sortedNumbers(children[node])
		if len(descendants) == 0 {
			if len(path) > 1 {
				result = append(result, append([]PRNumber(nil), path...))
			}
			return
		}
		for _, child := range descendants {
			alreadyInPath := false
			for _, ancestor := range path {
				if ancestor == child {
					alreadyInPath = true
					break
				}
			}
			if !alreadyInPath {
				visit(child, append(path, child))
			}
		}
	}
	for _, root := range sortedNumbers(involved) {
		if len(parents[root]) == 0 {
			visit(root, []PRNumber{root})
		}
	}
	return result
}

func heldPullRequests(prs []PullRequest, ordering []OrderingEdge) []HeldPullRequest {
	reasons := make(map[PRNumber][]string, len(prs))
	for _, pr := range prs {
		prReasons := make([]string, 0, 3)
		if pr.Draft {
			prReasons = append(prReasons, "draft")
		}
		if len(pr.BaseConflictPaths) != 0 {
			prReasons = append(prReasons, "local-base-conflict")
		}
		if pr.Mergeable == MergeableConflicting {
			prReasons = append(prReasons, "github-base-conflicting")
		}
		reasons[pr.Number] = prReasons
	}
	changed := true
	for changed {
		changed = false
		for _, edge := range ordering {
			if len(reasons[edge.Before]) != 0 && len(reasons[edge.After]) == 0 {
				reasons[edge.After] = []string{"depends-on-held:#" + edge.Before.String()}
				changed = true
			}
		}
	}
	result := make([]HeldPullRequest, 0)
	for _, pr := range prs {
		if len(reasons[pr.Number]) != 0 {
			result = append(result, HeldPullRequest{PR: pr.Number, Reasons: reasons[pr.Number]})
		}
	}
	return result
}

func (number PRNumber) String() string {
	return strconv.FormatInt(int64(number), 10)
}

func landingBatches(prs []PullRequest, ordering []OrderingEdge, conflicts []ConflictEdge) ([][]PRNumber, []PRNumber) {
	remaining := make(numberSet, len(prs))
	byNumber := make(map[PRNumber]PullRequest, len(prs))
	conflictsByPR := make(map[PRNumber]numberSet, len(prs))
	predecessors := make(map[PRNumber]numberSet, len(prs))
	children := make(map[PRNumber]numberSet, len(prs))
	for _, pr := range prs {
		remaining.add(pr.Number)
		byNumber[pr.Number] = pr
		conflictsByPR[pr.Number] = make(numberSet)
		predecessors[pr.Number] = make(numberSet)
		children[pr.Number] = make(numberSet)
	}
	for _, edge := range conflicts {
		if remaining.contains(edge.A) && remaining.contains(edge.B) {
			conflictsByPR[edge.A].add(edge.B)
			conflictsByPR[edge.B].add(edge.A)
		}
	}
	for _, edge := range ordering {
		if remaining.contains(edge.Before) && remaining.contains(edge.After) {
			predecessors[edge.After].add(edge.Before)
			children[edge.Before].add(edge.After)
		}
	}
	descendantCache := make(map[PRNumber]int)
	descendantCount := func(number PRNumber) int {
		if cached, ok := descendantCache[number]; ok {
			return cached
		}
		reachable := make(numberSet)
		pending := sortedNumbers(children[number])
		for len(pending) != 0 {
			last := len(pending) - 1
			child := pending[last]
			pending = pending[:last]
			if !reachable.contains(child) {
				reachable.add(child)
				pending = append(pending, sortedNumbers(children[child])...)
			}
		}
		descendantCache[number] = len(reachable)
		return len(reachable)
	}

	placed := make(numberSet)
	batches := make([][]PRNumber, 0)
	cycles := make([]PRNumber, 0)
	for len(remaining) != 0 {
		available := make([]PRNumber, 0)
		for number := range remaining {
			ready := true
			for predecessor := range predecessors[number] {
				if !placed.contains(predecessor) {
					ready = false
					break
				}
			}
			if ready {
				available = append(available, number)
			}
		}
		if len(available) == 0 {
			cycles = sortedNumbers(remaining)
			for _, number := range cycles {
				batches = append(batches, []PRNumber{number})
			}
			break
		}
		sort.Slice(available, func(i, j int) bool {
			left, right := available[i], available[j]
			if leftDescendants, rightDescendants := descendantCount(left), descendantCount(right); leftDescendants != rightDescendants {
				return leftDescendants > rightDescendants
			}
			leftConflicts, rightConflicts := 0, 0
			for peer := range conflictsByPR[left] {
				if remaining.contains(peer) {
					leftConflicts++
				}
			}
			for peer := range conflictsByPR[right] {
				if remaining.contains(peer) {
					rightConflicts++
				}
			}
			if leftConflicts != rightConflicts {
				return leftConflicts < rightConflicts
			}
			leftSize := uint64(byNumber[left].Additions) + uint64(byNumber[left].Deletions)
			rightSize := uint64(byNumber[right].Additions) + uint64(byNumber[right].Deletions)
			if leftSize != rightSize {
				return leftSize < rightSize
			}
			if byNumber[left].CreatedAt != byNumber[right].CreatedAt {
				return byNumber[left].CreatedAt < byNumber[right].CreatedAt
			}
			return left < right
		})
		batch := make([]PRNumber, 0)
		for _, candidate := range available {
			compatible := true
			for _, selected := range batch {
				if conflictsByPR[candidate].contains(selected) {
					compatible = false
					break
				}
			}
			if compatible {
				batch = append(batch, candidate)
			}
		}
		batches = append(batches, batch)
		for _, number := range batch {
			delete(remaining, number)
			placed.add(number)
		}
	}
	return batches, cycles
}

func rebasePlan(batches [][]PRNumber, ordering []OrderingEdge, conflicts []ConflictEdge) []RebaseEntry {
	batchOf := make(map[PRNumber]int)
	for index, batch := range batches {
		for _, number := range batch {
			batchOf[number] = index
		}
	}
	dependencies := make(map[PRNumber]numberSet)
	reasons := make(map[PRNumber]map[string]struct{})
	add := func(pr, after PRNumber, reason string) {
		if dependencies[pr] == nil {
			dependencies[pr] = make(numberSet)
			reasons[pr] = make(map[string]struct{})
		}
		dependencies[pr].add(after)
		reasons[pr][reason] = struct{}{}
	}
	for _, edge := range ordering {
		beforeBatch, beforeOK := batchOf[edge.Before]
		afterBatch, afterOK := batchOf[edge.After]
		if beforeOK && afterOK && beforeBatch < afterBatch {
			add(edge.After, edge.Before, "stack-dependency")
		}
	}
	for _, edge := range conflicts {
		aBatch, aOK := batchOf[edge.A]
		bBatch, bOK := batchOf[edge.B]
		if !aOK || !bOK || aBatch == bBatch {
			continue
		}
		if aBatch < bBatch {
			add(edge.B, edge.A, "pair-conflict")
		} else {
			add(edge.A, edge.B, "pair-conflict")
		}
	}
	numbers := make([]PRNumber, 0, len(dependencies))
	for number := range dependencies {
		numbers = append(numbers, number)
	}
	sort.Slice(numbers, func(i, j int) bool {
		if batchOf[numbers[i]] != batchOf[numbers[j]] {
			return batchOf[numbers[i]] < batchOf[numbers[j]]
		}
		return numbers[i] < numbers[j]
	})
	result := make([]RebaseEntry, 0, len(numbers))
	for _, number := range numbers {
		entryReasons := make([]string, 0, 2)
		if _, ok := reasons[number]["pair-conflict"]; ok {
			entryReasons = append(entryReasons, "pair-conflict")
		}
		if _, ok := reasons[number]["stack-dependency"]; ok {
			entryReasons = append(entryReasons, "stack-dependency")
		}
		result = append(result, RebaseEntry{PR: number, After: sortedNumbers(dependencies[number]), Reasons: entryReasons})
	}
	return result
}

func makePlan(data AnalysisInput) Plan {
	ordering := orderingEdges(data)
	conflicts := append(make([]ConflictEdge, 0, len(data.ConflictEdges)), data.ConflictEdges...)
	sort.Slice(conflicts, func(i, j int) bool {
		if conflicts[i].A != conflicts[j].A {
			return conflicts[i].A < conflicts[j].A
		}
		return conflicts[i].B < conflicts[j].B
	})
	held := heldPullRequests(data.PRs, ordering)
	heldNumbers := make(numberSet, len(held))
	for _, item := range held {
		heldNumbers.add(item.PR)
	}
	suggested, cycles := landingBatches(data.PRs, ordering, conflicts)
	readyPRs := make([]PullRequest, 0, len(data.PRs)-len(held))
	for _, pr := range data.PRs {
		if !heldNumbers.contains(pr.Number) {
			readyPRs = append(readyPRs, pr)
		}
	}
	ready, _ := landingBatches(readyPRs, ordering, conflicts)
	readyNow := make([]PRNumber, 0)
	if len(ready) != 0 {
		readyNow = append(readyNow, ready[0]...)
	}
	nodes := make([]NormalizedNode, 0, len(data.PRs))
	for _, pr := range data.PRs {
		author := "unknown"
		if pr.Author != nil {
			author = *pr.Author
		}
		nodes = append(nodes, NormalizedNode{
			Additions: pr.Additions, Author: author,
			BaseConflictPaths: append(make([]string, 0, len(pr.BaseConflictPaths)), pr.BaseConflictPaths...), BaseRef: pr.BaseRef,
			Deletions: pr.Deletions, Draft: pr.Draft, FilesCount: len(pr.Files), HeadRef: pr.HeadRef,
			Mergeable: pr.Mergeable, PR: pr.Number, ReviewDecision: pr.ReviewDecision, Title: pr.Title,
		})
	}
	jsonOrdering := make([]JSONOrderingEdge, 0, len(ordering))
	for _, edge := range ordering {
		jsonOrdering = append(jsonOrdering, JSONOrderingEdge{After: edge.After, Before: edge.Before, Reason: edge.Reason})
	}
	return Plan{
		ConflictEdges: conflicts, FileOverlapEdges: fileOverlaps(data.PRs), HeldPRs: held,
		Nodes: nodes, OrderingCycles: cycles, OrderingEdges: jsonOrdering,
		ReadyLandingBatches: ready, ReadyNow: readyNow, Repository: data.Repository,
		Stacks: buildStacks(ordering), SuggestedLandingBatches: suggested,
		SuggestedRebasePlan: rebasePlan(suggested, ordering, conflicts),
	}
}
