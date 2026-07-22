package main

type PRNumber int64
type GitRevision string
type Mergeable string
type ReviewDecision string

const (
	MergeableYes         Mergeable = "MERGEABLE"
	MergeableConflicting Mergeable = "CONFLICTING"
	MergeableUnknown     Mergeable = "UNKNOWN"

	ReviewApproved         ReviewDecision = "APPROVED"
	ReviewChangesRequested ReviewDecision = "CHANGES_REQUESTED"
	ReviewRequired         ReviewDecision = "REVIEW_REQUIRED"
	ReviewNone             ReviewDecision = "NONE"
)

type PullRequest struct {
	Number            PRNumber
	Title             string
	Author            *string
	HeadRef           string
	BaseRef           string
	Draft             bool
	Mergeable         Mergeable
	ReviewDecision    ReviewDecision
	CreatedAt         string
	UpdatedAt         string
	Additions         int64
	Deletions         int64
	Files             []string
	BaseConflictPaths []string
	GitHead           *GitRevision
	GitBase           *GitRevision
}

type ConflictEdge struct {
	A     PRNumber `json:"a"`
	B     PRNumber `json:"b"`
	Paths []string `json:"paths"`
}

type AncestryEdge struct {
	Before PRNumber
	After  PRNumber
}

type OrderingEdge struct {
	Before PRNumber
	After  PRNumber
	Reason string
}

type AnalysisInput struct {
	Repository    string
	PRs           []PullRequest
	ConflictEdges []ConflictEdge
	AncestryEdges []AncestryEdge
}

type NormalizedNode struct {
	Additions         int64          `json:"additions"`
	Author            string         `json:"author"`
	BaseConflictPaths []string       `json:"base_conflict_paths"`
	BaseRef           string         `json:"base_ref"`
	Deletions         int64          `json:"deletions"`
	Draft             bool           `json:"draft"`
	FilesCount        int            `json:"files_count"`
	HeadRef           string         `json:"head_ref"`
	Mergeable         Mergeable      `json:"mergeable"`
	PR                PRNumber       `json:"pr"`
	ReviewDecision    ReviewDecision `json:"review_decision"`
	Title             string         `json:"title"`
}

type JSONOrderingEdge struct {
	After  PRNumber `json:"after"`
	Before PRNumber `json:"before"`
	Reason string   `json:"reason"`
}

type HeldPullRequest struct {
	PR      PRNumber `json:"pr"`
	Reasons []string `json:"reasons"`
}

type RebaseEntry struct {
	After   []PRNumber `json:"after"`
	PR      PRNumber   `json:"pr"`
	Reasons []string   `json:"reasons"`
}

type Plan struct {
	ConflictEdges           []ConflictEdge     `json:"conflict_edges"`
	FileOverlapEdges        []ConflictEdge     `json:"file_overlap_edges"`
	HeldPRs                 []HeldPullRequest  `json:"held_prs"`
	Nodes                   []NormalizedNode   `json:"nodes"`
	OrderingCycles          []PRNumber         `json:"ordering_cycles"`
	OrderingEdges           []JSONOrderingEdge `json:"ordering_edges"`
	ReadyLandingBatches     [][]PRNumber       `json:"ready_landing_batches"`
	ReadyNow                []PRNumber         `json:"ready_now"`
	Repository              string             `json:"repository"`
	Stacks                  [][]PRNumber       `json:"stacks"`
	SuggestedLandingBatches [][]PRNumber       `json:"suggested_landing_batches"`
	SuggestedRebasePlan     []RebaseEntry      `json:"suggested_rebase_plan"`
}
