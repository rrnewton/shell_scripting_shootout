open Model

let json_numbers values =
  `List (List.map (fun value -> `Int (Pr_number.to_int value)) values)

let json_paths values =
  `List (List.map (fun value -> `String (Fpath.to_string value)) values)

let json_node pr =
  `Assoc
    [
      ("pr", `Int (Pr_number.to_int pr.number));
      ("title", `String pr.title);
      ("author", `String (Option.value ~default:"unknown" pr.author));
      ("head_ref", `String pr.head_ref);
      ("base_ref", `String pr.base_ref);
      ("draft", `Bool pr.draft);
      ("mergeable", `String (string_of_mergeable pr.mergeable));
      ("review_decision", `String (string_of_review_decision pr.review_decision));
      ("additions", `Int pr.additions);
      ("deletions", `Int pr.deletions);
      ("files_count", `Int (List.length pr.files));
      ("base_conflict_paths", json_paths pr.base_conflict_paths);
    ]

let json_conflict edge =
  `Assoc
    [
      ("a", `Int (Pr_number.to_int edge.a));
      ("b", `Int (Pr_number.to_int edge.b));
      ("paths", json_paths edge.paths);
    ]

let json_ordering edge =
  `Assoc
    [
      ("before", `Int (Pr_number.to_int edge.before));
      ("after", `Int (Pr_number.to_int edge.after));
      ("reason", `String (string_of_order_reason edge.reason));
    ]

let json_held (held : held_pr) =
  `Assoc
    [
      ("pr", `Int (Pr_number.to_int held.pr));
      ("reasons", `List (List.map (fun reason -> `String reason) held.reasons));
    ]

let json_rebase (entry : rebase_entry) =
  `Assoc
    [
      ("pr", `Int (Pr_number.to_int entry.pr));
      ("after", json_numbers entry.after);
      ( "reasons",
        `List
          (List.map
             (fun reason -> `String (string_of_rebase_reason reason))
             entry.reasons) );
    ]

let json plan =
  `Assoc
    [
      ("repository", `String plan.repository);
      ("nodes", `List (List.map json_node plan.nodes));
      ("conflict_edges", `List (List.map json_conflict plan.conflict_edges));
      ( "file_overlap_edges",
        `List (List.map json_conflict plan.file_overlap_edges) );
      ("ordering_edges", `List (List.map json_ordering plan.ordering_edges));
      ("stacks", `List (List.map json_numbers plan.stacks));
      ( "suggested_landing_batches",
        `List (List.map json_numbers plan.suggested_landing_batches) );
      ( "suggested_rebase_plan",
        `List (List.map json_rebase plan.suggested_rebase_plan) );
      ( "ready_landing_batches",
        `List (List.map json_numbers plan.ready_landing_batches) );
      ("ready_now", json_numbers plan.ready_now);
      ("held_prs", `List (List.map json_held plan.held_prs));
      ("ordering_cycles", json_numbers plan.ordering_cycles);
    ]

let render_json plan =
  Yojson.Basic.pretty_to_string ~std:true (json plan) ^ "\n"

let pr_list values =
  match values with
  | [] -> "(none)"
  | _ ->
      values
      |> List.map (fun value -> "#" ^ Pr_number.to_string value)
      |> String.concat ", "

let numbered_batches heading batches =
  heading
  ::
  (match batches with
  | [] -> [ "  (none)" ]
  | _ ->
      List.mapi
        (fun index batch ->
          Printf.sprintf "  %d: %s" (index + 1) (pr_list batch))
        batches)

let render_human plan =
  let held =
    "Held pull requests:"
    ::
    (match plan.held_prs with
    | [] -> [ "  (none)" ]
    | values ->
        List.map
          (fun (item : held_pr) ->
            Printf.sprintf "  #%s: %s"
              (Pr_number.to_string item.pr)
              (String.concat ", " item.reasons))
          values)
  in
  let cycles =
    [
      "Ordering cycles:";
      (if plan.ordering_cycles = [] then "  (none)"
       else "  " ^ pr_list plan.ordering_cycles);
    ]
  in
  let rebases =
    "Suggested rebase plan:"
    ::
    (match plan.suggested_rebase_plan with
    | [] -> [ "  (none)" ]
    | values ->
        List.map
          (fun (item : rebase_entry) ->
            Printf.sprintf "  #%s after %s: %s"
              (Pr_number.to_string item.pr)
              (pr_list item.after)
              (String.concat ", "
                 (List.map string_of_rebase_reason item.reasons)))
          values)
  in
  String.concat "\n"
    ([
       Printf.sprintf "Repository: %s" plan.repository;
       Printf.sprintf "Pull requests: %d" (List.length plan.nodes);
     ]
    @ held @ cycles
    @ numbered_batches "Suggested landing batches:"
        plan.suggested_landing_batches
    @ numbered_batches "Ready landing batches:" plan.ready_landing_batches
    @ [ "Ready now: " ^ pr_list plan.ready_now ]
    @ rebases)
  ^ "\n"
