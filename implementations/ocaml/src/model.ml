module Pr_number = struct
  type t = Pr of int

  let compare (Pr left) (Pr right) = Int.compare left right
  let of_int value = Pr value
  let to_int (Pr value) = value
  let to_string value = string_of_int (to_int value)
end

module Pr_set = Set.Make (Pr_number)
module Pr_map = Map.Make (Pr_number)

module Pr_pair = struct
  type t = Pr_number.t * Pr_number.t

  let compare (left_a, left_b) (right_a, right_b) =
    match Pr_number.compare left_a right_a with
    | 0 -> Pr_number.compare left_b right_b
    | result -> result
end

module Pr_pair_set = Set.Make (Pr_pair)
module Pr_pair_map = Map.Make (Pr_pair)

type mergeable = Mergeable | Conflicting | Unknown

type review_decision =
  | Approved
  | Changes_requested
  | Review_required
  | None_given

type order_reason = Base_ref | Ancestry
type rebase_reason = Pair_conflict | Stack_dependency
type git_revision = Git_revision of string
type object_id = Object_id of string

type pull_request = {
  number : Pr_number.t;
  title : string;
  author : string option;
  head_ref : string;
  base_ref : string;
  draft : bool;
  mergeable : mergeable;
  review_decision : review_decision;
  created_at : string;
  updated_at : string;
  additions : int;
  deletions : int;
  files : Fpath.t list;
  base_conflict_paths : Fpath.t list;
  git_head : git_revision option;
  git_base : git_revision option;
}

type conflict_edge = { a : Pr_number.t; b : Pr_number.t; paths : Fpath.t list }

type ordering_edge = {
  before : Pr_number.t;
  after : Pr_number.t;
  reason : order_reason;
}

type held_pr = { pr : Pr_number.t; reasons : string list }

type rebase_entry = {
  pr : Pr_number.t;
  after : Pr_number.t list;
  reasons : rebase_reason list;
}

type analysis_input = {
  repository : string;
  prs : pull_request list;
  conflict_edges : conflict_edge list;
  ancestry_edges : Pr_pair.t list;
}

type plan = {
  repository : string;
  nodes : pull_request list;
  conflict_edges : conflict_edge list;
  file_overlap_edges : conflict_edge list;
  ordering_edges : ordering_edge list;
  stacks : Pr_number.t list list;
  suggested_landing_batches : Pr_number.t list list;
  suggested_rebase_plan : rebase_entry list;
  ready_landing_batches : Pr_number.t list list;
  ready_now : Pr_number.t list;
  held_prs : held_pr list;
  ordering_cycles : Pr_number.t list;
}

let string_of_mergeable = function
  | Mergeable -> "MERGEABLE"
  | Conflicting -> "CONFLICTING"
  | Unknown -> "UNKNOWN"

let string_of_review_decision = function
  | Approved -> "APPROVED"
  | Changes_requested -> "CHANGES_REQUESTED"
  | Review_required -> "REVIEW_REQUIRED"
  | None_given -> "NONE"

let string_of_order_reason = function
  | Base_ref -> "base-ref"
  | Ancestry -> "ancestry"

let string_of_rebase_reason = function
  | Pair_conflict -> "pair-conflict"
  | Stack_dependency -> "stack-dependency"

let compare_conflict left right =
  match Pr_number.compare left.a right.a with
  | 0 -> Pr_number.compare left.b right.b
  | result -> result

let compare_ordering left right =
  match Pr_number.compare left.before right.before with
  | 0 -> Pr_number.compare left.after right.after
  | result -> result
