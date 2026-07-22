export type PrNumber = number & { readonly __brand: "PrNumber" };
export type GitObjectId = string & { readonly __brand: "GitObjectId" };

export type Mergeable = "MERGEABLE" | "CONFLICTING" | "UNKNOWN";
export type ReviewDecision =
  | "APPROVED"
  | "CHANGES_REQUESTED"
  | "REVIEW_REQUIRED"
  | "NONE";

export interface PrNode {
  readonly number: PrNumber;
  readonly title: string;
  readonly author: string | null;
  readonly head_ref: string;
  readonly base_ref: string;
  readonly draft: boolean;
  readonly mergeable: Mergeable;
  readonly review_decision: ReviewDecision;
  readonly created_at: string;
  readonly updated_at: string;
  readonly additions: number;
  readonly deletions: number;
  readonly files: readonly string[];
  readonly base_conflict_paths: readonly string[];
}

export interface NormalizedPrNode {
  readonly pr: PrNumber;
  readonly title: string;
  readonly author: string;
  readonly head_ref: string;
  readonly base_ref: string;
  readonly draft: boolean;
  readonly mergeable: Mergeable;
  readonly review_decision: ReviewDecision;
  readonly additions: number;
  readonly deletions: number;
  readonly files_count: number;
  readonly base_conflict_paths: readonly string[];
}

export interface ConflictEdge {
  readonly a: PrNumber;
  readonly b: PrNumber;
  readonly paths: readonly string[];
}

export type OrderingReason = "base-ref" | "ancestry";

export interface OrderingEdge {
  readonly before: PrNumber;
  readonly after: PrNumber;
  readonly reason: OrderingReason;
}

export interface PlanningInput {
  readonly repository: string;
  readonly nodes: readonly PrNode[];
  readonly conflictEdges: readonly ConflictEdge[];
  readonly ancestryEdges: readonly {
    readonly before: PrNumber;
    readonly after: PrNumber;
  }[];
}

export interface Plan {
  readonly repository: string;
  readonly nodes: readonly NormalizedPrNode[];
  readonly conflict_edges: readonly ConflictEdge[];
  readonly file_overlap_edges: readonly ConflictEdge[];
  readonly ordering_edges: readonly OrderingEdge[];
  readonly stacks: readonly (readonly PrNumber[])[];
  readonly suggested_landing_batches: readonly (readonly PrNumber[])[];
  readonly suggested_rebase_plan: readonly RebaseStep[];
  readonly ready_landing_batches: readonly (readonly PrNumber[])[];
  readonly ready_now: readonly PrNumber[];
  readonly held_prs: readonly HeldPr[];
  readonly ordering_cycles: readonly PrNumber[];
}

export interface HeldPr {
  readonly pr: PrNumber;
  readonly reasons: readonly string[];
}

export interface RebaseStep {
  readonly pr: PrNumber;
  readonly after: readonly PrNumber[];
  readonly reasons: readonly ("pair-conflict" | "stack-dependency")[];
}
