open Model
module String_map = Map.Make (String)
module Path_set = Set.Make (Fpath)

let set_for number map =
  Option.value ~default:Pr_set.empty (Pr_map.find_opt number map)

let add_to_set_map key value map =
  Pr_map.add key (Pr_set.add value (set_for key map)) map

let ordering_edges input =
  let by_head =
    List.fold_left
      (fun map pr -> String_map.add pr.head_ref pr.number map)
      String_map.empty input.prs
  in
  let base_edges =
    List.fold_left
      (fun edges pr ->
        match String_map.find_opt pr.base_ref by_head with
        | Some parent when Pr_number.compare parent pr.number <> 0 ->
            Pr_pair_map.add (parent, pr.number)
              { before = parent; after = pr.number; reason = Base_ref }
              edges
        | _ -> edges)
      Pr_pair_map.empty input.prs
  in
  List.fold_left
    (fun edges (before, after) ->
      if Pr_pair_map.mem (before, after) edges then edges
      else
        Pr_pair_map.add (before, after)
          { before; after; reason = Ancestry }
          edges)
    base_edges input.ancestry_edges
  |> Pr_pair_map.bindings |> List.map snd

let file_overlaps prs =
  let rec left_loop edges = function
    | [] -> List.rev edges
    | left :: rest ->
        let left_files =
          List.fold_left
            (fun set path -> Path_set.add path set)
            Path_set.empty left.files
        in
        let edges =
          List.fold_left
            (fun edges right ->
              let shared =
                List.filter
                  (fun path -> Path_set.mem path left_files)
                  right.files
              in
              if shared = [] then edges
              else
                { a = left.number; b = right.number; paths = shared } :: edges)
            edges rest
        in
        left_loop edges rest
  in
  left_loop [] prs |> List.sort compare_conflict

let has_path adjacency ~start ~target ~skip =
  let rec visit pending seen =
    match pending with
    | [] -> false
    | current :: rest when Pr_set.mem current seen -> visit rest seen
    | current :: rest ->
        let seen = Pr_set.add current seen in
        let children = set_for current adjacency |> Pr_set.elements in
        let rec inspect pending = function
          | [] -> visit pending seen
          | child :: children when Pr_pair.compare (current, child) skip = 0 ->
              inspect pending children
          | child :: _ when Pr_number.compare child target = 0 -> true
          | child :: children -> inspect (child :: pending) children
        in
        inspect rest children
  in
  visit [ start ] Pr_set.empty

let stacks edges =
  let adjacency =
    List.fold_left
      (fun map edge -> add_to_set_map edge.before edge.after map)
      Pr_map.empty edges
  in
  let reduced =
    List.filter
      (fun edge ->
        not
          (has_path adjacency ~start:edge.before ~target:edge.after
             ~skip:(edge.before, edge.after)))
      edges
  in
  let children, parents, involved =
    List.fold_left
      (fun (children, parents, involved) edge ->
        ( add_to_set_map edge.before edge.after children,
          add_to_set_map edge.after edge.before parents,
          involved |> Pr_set.add edge.before |> Pr_set.add edge.after ))
      (Pr_map.empty, Pr_map.empty, Pr_set.empty)
      reduced
  in
  let roots =
    Pr_set.filter
      (fun number -> Pr_set.is_empty (set_for number parents))
      involved
    |> Pr_set.elements
  in
  let rec paths_from node path =
    let descendants = set_for node children |> Pr_set.elements in
    match descendants with
    | [] -> if List.length path > 1 then [ path ] else []
    | _ ->
        List.concat_map
          (fun child ->
            if List.exists (fun value -> Pr_number.compare value child = 0) path
            then []
            else paths_from child (path @ [ child ]))
          descendants
  in
  List.concat_map (fun root -> paths_from root [ root ]) roots

let held_prs prs ordering =
  let initial =
    List.fold_left
      (fun map pr ->
        let reasons =
          ( ( [] |> fun values ->
              if pr.draft then values @ [ "draft" ] else values )
          |> fun values ->
            if pr.base_conflict_paths <> [] then
              values @ [ "local-base-conflict" ]
            else values )
          |> fun values ->
          if pr.mergeable = Conflicting then
            values @ [ "github-base-conflicting" ]
          else values
        in
        Pr_map.add pr.number reasons map)
      Pr_map.empty prs
  in
  let rec propagate reasons =
    let changed, updated =
      List.fold_left
        (fun (changed, map) edge ->
          let before =
            Option.value ~default:[] (Pr_map.find_opt edge.before map)
          in
          let after =
            Option.value ~default:[] (Pr_map.find_opt edge.after map)
          in
          if before <> [] && after = [] then
            ( true,
              Pr_map.add edge.after
                [
                  Printf.sprintf "depends-on-held:#%s"
                    (Pr_number.to_string edge.before);
                ]
                map )
          else (changed, map))
        (false, reasons) ordering
    in
    if changed then propagate updated else updated
  in
  propagate initial |> Pr_map.bindings
  |> List.filter_map (fun (pr, reasons) ->
         if reasons = [] then None else Some { pr; reasons })

type batch_plan = { batches : Pr_number.t list list; cycles : Pr_number.t list }

let intersection_size left right =
  Pr_set.fold
    (fun item count -> if Pr_set.mem item right then count + 1 else count)
    left 0

let landing_batches prs ordering conflicts =
  let numbers =
    List.fold_left (fun set pr -> Pr_set.add pr.number set) Pr_set.empty prs
  in
  if Pr_set.is_empty numbers then { batches = []; cycles = [] }
  else
    let by_number =
      List.fold_left
        (fun map pr -> Pr_map.add pr.number pr map)
        Pr_map.empty prs
    in
    let empty_sets =
      Pr_set.fold
        (fun number map -> Pr_map.add number Pr_set.empty map)
        numbers Pr_map.empty
    in
    let conflict_map =
      List.fold_left
        (fun map edge ->
          if Pr_set.mem edge.a numbers && Pr_set.mem edge.b numbers then
            map |> add_to_set_map edge.a edge.b |> add_to_set_map edge.b edge.a
          else map)
        empty_sets conflicts
    in
    let predecessors, children =
      List.fold_left
        (fun (predecessors, children) edge ->
          if Pr_set.mem edge.before numbers && Pr_set.mem edge.after numbers
          then
            ( add_to_set_map edge.after edge.before predecessors,
              add_to_set_map edge.before edge.after children )
          else (predecessors, children))
        (empty_sets, empty_sets) ordering
    in
    let descendant_count number =
      let rec visit pending seen =
        match pending with
        | [] -> Pr_set.cardinal seen
        | current :: rest when Pr_set.mem current seen -> visit rest seen
        | current :: rest ->
            let seen = Pr_set.add current seen in
            visit (Pr_set.elements (set_for current children) @ rest) seen
      in
      visit (Pr_set.elements (set_for number children)) Pr_set.empty
    in
    let compare_available remaining left right =
      let left_pr = Pr_map.find left by_number
      and right_pr = Pr_map.find right by_number in
      let comparisons =
        [
          Int.compare (descendant_count right) (descendant_count left);
          Int.compare
            (intersection_size (set_for left conflict_map) remaining)
            (intersection_size (set_for right conflict_map) remaining);
          Int.compare
            (left_pr.additions + left_pr.deletions)
            (right_pr.additions + right_pr.deletions);
          String.compare left_pr.created_at right_pr.created_at;
          Pr_number.compare left right;
        ]
      in
      Option.value ~default:0 (List.find_opt (( <> ) 0) comparisons)
    in
    let rec place remaining placed batches =
      if Pr_set.is_empty remaining then
        { batches = List.rev batches; cycles = [] }
      else
        let available =
          Pr_set.filter
            (fun number -> Pr_set.subset (set_for number predecessors) placed)
            remaining
          |> Pr_set.elements
          |> List.sort (compare_available remaining)
        in
        match available with
        | [] ->
            let cycles = Pr_set.elements remaining in
            {
              batches =
                List.rev batches @ List.map (fun number -> [ number ]) cycles;
              cycles;
            }
        | _ ->
            let batch =
              List.fold_left
                (fun selected candidate ->
                  if
                    List.for_all
                      (fun peer ->
                        not (Pr_set.mem peer (set_for candidate conflict_map)))
                      selected
                  then selected @ [ candidate ]
                  else selected)
                [] available
            in
            let batch_set =
              List.fold_left
                (fun set number -> Pr_set.add number set)
                Pr_set.empty batch
            in
            place
              (Pr_set.diff remaining batch_set)
              (Pr_set.union placed batch_set)
              (batch :: batches)
    in
    place numbers Pr_set.empty []

let rebase_plan batches ordering conflicts =
  let batch_of =
    List.mapi (fun index batch -> (index, batch)) batches
    |> List.fold_left
         (fun map (index, batch) ->
           List.fold_left
             (fun map number -> Pr_map.add number index map)
             map batch)
         Pr_map.empty
  in
  let earlier left right =
    match (Pr_map.find_opt left batch_of, Pr_map.find_opt right batch_of) with
    | Some left_batch, Some right_batch -> left_batch < right_batch
    | _ -> false
  in
  let dependencies, reasons =
    List.fold_left
      (fun (dependencies, reasons) edge ->
        if earlier edge.before edge.after then
          ( add_to_set_map edge.after edge.before dependencies,
            Pr_map.add edge.after
              (Stack_dependency
              :: Option.value ~default:[] (Pr_map.find_opt edge.after reasons))
              reasons )
        else (dependencies, reasons))
      (Pr_map.empty, Pr_map.empty)
      ordering
  in
  let dependencies, reasons =
    List.fold_left
      (fun (dependencies, reasons) edge ->
        match
          (Pr_map.find_opt edge.a batch_of, Pr_map.find_opt edge.b batch_of)
        with
        | Some a_batch, Some b_batch when a_batch <> b_batch ->
            let earlier_pr, later_pr =
              if a_batch < b_batch then (edge.a, edge.b) else (edge.b, edge.a)
            in
            ( add_to_set_map later_pr earlier_pr dependencies,
              Pr_map.add later_pr
                (Pair_conflict
                :: Option.value ~default:[] (Pr_map.find_opt later_pr reasons))
                reasons )
        | _ -> (dependencies, reasons))
      (dependencies, reasons) conflicts
  in
  let unique_reasons values =
    [ Pair_conflict; Stack_dependency ]
    |> List.filter (fun reason -> List.mem reason values)
  in
  Pr_map.bindings dependencies
  |> List.map (fun (pr, after) ->
         {
           pr;
           after = Pr_set.elements after;
           reasons =
             unique_reasons
               (Option.value ~default:[] (Pr_map.find_opt pr reasons));
         })
  |> List.sort (fun left right ->
         match
           Int.compare
             (Pr_map.find left.pr batch_of)
             (Pr_map.find right.pr batch_of)
         with
         | 0 -> Pr_number.compare left.pr right.pr
         | result -> result)

let make input =
  let ordering_edges = ordering_edges input in
  let conflict_edges = List.sort compare_conflict input.conflict_edges in
  let held_prs = held_prs input.prs ordering_edges in
  let held_numbers =
    List.fold_left
      (fun set (item : held_pr) -> Pr_set.add item.pr set)
      Pr_set.empty held_prs
  in
  let suggested = landing_batches input.prs ordering_edges conflict_edges in
  let ready_prs =
    List.filter (fun pr -> not (Pr_set.mem pr.number held_numbers)) input.prs
  in
  let ready = landing_batches ready_prs ordering_edges conflict_edges in
  {
    repository = input.repository;
    nodes = input.prs;
    conflict_edges;
    file_overlap_edges = file_overlaps input.prs;
    ordering_edges;
    stacks = stacks ordering_edges;
    suggested_landing_batches = suggested.batches;
    suggested_rebase_plan =
      rebase_plan suggested.batches ordering_edges conflict_edges;
    ready_landing_batches = ready.batches;
    ready_now = (match ready.batches with batch :: _ -> batch | [] -> []);
    held_prs;
    ordering_cycles = suggested.cycles;
  }
