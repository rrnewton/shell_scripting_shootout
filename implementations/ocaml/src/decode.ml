open Model

let ( let* ) = Result.bind

let errorf path format =
  Format.kasprintf (fun message -> Error (`Msg (path ^ ": " ^ message))) format

type mode = Pure | Git

module String_set = Set.Make (String)
module Path_set = Set.Make (Fpath)

let common_pr_keys =
  [
    "number";
    "title";
    "author";
    "head_ref";
    "base_ref";
    "draft";
    "mergeable";
    "review_decision";
    "created_at";
    "updated_at";
    "additions";
    "deletions";
  ]

let pure_pr_keys = common_pr_keys @ [ "files"; "base_conflict_paths" ]
let git_pr_keys = common_pr_keys @ [ "git_head"; "git_base" ]

let pure_root_keys =
  [ "schema_version"; "repository"; "prs"; "conflict_edges"; "ancestry_edges" ]

let git_root_keys = [ "schema_version"; "repository"; "prs" ]

let object_ path = function
  | `Assoc fields -> Ok fields
  | _ -> errorf path "expected an object"

let array path = function
  | `List values -> Ok values
  | _ -> errorf path "expected an array"

let sorted_strings = List.sort String.compare

let exact_keys fields expected path =
  let keys = List.map fst fields in
  let unique =
    List.fold_left (fun set key -> String_set.add key set) String_set.empty keys
  in
  if List.length keys <> String_set.cardinal unique then
    errorf path "object fields must be unique"
  else
    let expected_set =
      List.fold_left
        (fun set key -> String_set.add key set)
        String_set.empty expected
    in
    let missing = String_set.diff expected_set unique |> String_set.elements in
    let unknown = String_set.diff unique expected_set |> String_set.elements in
    match (missing, unknown) with
    | _ :: _, _ ->
        errorf path "missing field(s): %s"
          (String.concat ", " (sorted_strings missing))
    | [], _ :: _ ->
        errorf path "unknown field(s): %s"
          (String.concat ", " (sorted_strings unknown))
    | [], [] -> Ok ()

let field fields key =
  match List.assoc_opt key fields with
  | Some value -> value
  | None -> invalid_arg ("validated JSON object lacks " ^ key)

let string path = function
  | `String value when value = "" -> errorf path "must not be empty"
  | `String value when String.contains value '\000' ->
      errorf path "must not contain NUL"
  | `String value -> Ok value
  | _ -> errorf path "expected a string"

let optional_string path = function
  | `Null -> Ok None
  | value -> Result.map Option.some (string path value)

let integer ?(positive = false) path = function
  | `Int value when positive && value <= 0 -> errorf path "must be positive"
  | `Int value when (not positive) && value < 0 ->
      errorf path "must not be negative"
  | `Int value -> Ok value
  | _ -> errorf path "expected an integer"

let boolean path = function
  | `Bool value -> Ok value
  | _ -> errorf path "expected a boolean"

let timestamp path value =
  let* value = string path value in
  match Ptime.of_rfc3339 ~strict:true value with
  | Ok (_, Some _, count) when count = String.length value -> Ok value
  | Ok (_, None, _) -> errorf path "timestamp must include a UTC offset"
  | _ -> errorf path "expected an RFC 3339 timestamp"

let mergeable path value =
  let* value = string path value in
  match value with
  | "MERGEABLE" -> Ok Mergeable
  | "CONFLICTING" -> Ok Conflicting
  | "UNKNOWN" -> Ok Unknown
  | _ -> errorf path "expected one of: CONFLICTING, MERGEABLE, UNKNOWN"

let review_decision path value =
  let* value = string path value in
  match value with
  | "APPROVED" -> Ok Approved
  | "CHANGES_REQUESTED" -> Ok Changes_requested
  | "REVIEW_REQUIRED" -> Ok Review_required
  | "NONE" -> Ok None_given
  | _ ->
      errorf path
        "expected one of: APPROVED, CHANGES_REQUESTED, NONE, REVIEW_REQUIRED"

let paths path value =
  let* values = array path value in
  let rec decode index seen decoded = function
    | [] -> Ok (List.sort Fpath.compare decoded)
    | raw :: rest ->
        let item_path = Printf.sprintf "%s[%d]" path index in
        let* raw_path = string item_path raw in
        let* file_path =
          match Fpath.of_string raw_path with
          | Error (`Msg message) -> errorf item_path "%s" message
          | Ok file_path when Fpath.is_abs file_path ->
              errorf item_path "expected a repository-relative path"
          | Ok file_path -> Ok file_path
        in
        if Path_set.mem file_path seen then errorf path "paths must be unique"
        else
          decode (index + 1)
            (Path_set.add file_path seen)
            (file_path :: decoded) rest
  in
  decode 0 Path_set.empty [] values

let has_control value =
  let rec loop index =
    if index = String.length value then false
    else
      let code = Char.code value.[index] in
      code <= 31 || code = 127 || loop (index + 1)
  in
  loop 0

let revision path value =
  let* value = string path value in
  if value.[0] = '-' then errorf path "revision must not start with '-'"
  else if has_control value then
    errorf path "revision must not contain control characters"
  else Ok (Git_revision value)

let pull_request mode index value =
  let path = Printf.sprintf "$.prs[%d]" index in
  let* item = object_ path value in
  let* () =
    exact_keys item
      (match mode with Pure -> pure_pr_keys | Git -> git_pr_keys)
      path
  in
  let at name = path ^ "." ^ name in
  let* number = integer ~positive:true (at "number") (field item "number") in
  let* title = string (at "title") (field item "title") in
  let* author = optional_string (at "author") (field item "author") in
  let* head_ref = string (at "head_ref") (field item "head_ref") in
  let* base_ref = string (at "base_ref") (field item "base_ref") in
  let* draft = boolean (at "draft") (field item "draft") in
  let* mergeable = mergeable (at "mergeable") (field item "mergeable") in
  let* review_decision =
    review_decision (at "review_decision") (field item "review_decision")
  in
  let* created_at = timestamp (at "created_at") (field item "created_at") in
  let* updated_at = timestamp (at "updated_at") (field item "updated_at") in
  let* additions = integer (at "additions") (field item "additions") in
  let* deletions = integer (at "deletions") (field item "deletions") in
  let* files, base_conflict_paths, git_head, git_base =
    match mode with
    | Pure ->
        let* files = paths (at "files") (field item "files") in
        let* conflicts =
          paths (at "base_conflict_paths") (field item "base_conflict_paths")
        in
        Ok (files, conflicts, None, None)
    | Git ->
        let* head = revision (at "git_head") (field item "git_head") in
        let* base = revision (at "git_base") (field item "git_base") in
        Ok ([], [], Some head, Some base)
  in
  Ok
    {
      number = Pr_number.of_int number;
      title;
      author;
      head_ref;
      base_ref;
      draft;
      mergeable;
      review_decision;
      created_at;
      updated_at;
      additions;
      deletions;
      files;
      base_conflict_paths;
      git_head;
      git_base;
    }

let decode_list decode values =
  let rec loop index decoded = function
    | [] -> Ok (List.rev decoded)
    | value :: rest ->
        let* item = decode index value in
        loop (index + 1) (item :: decoded) rest
  in
  loop 0 [] values

let pr_number known path value =
  let* value = integer ~positive:true path value in
  let number = Pr_number.of_int value in
  if Pr_set.mem number known then Ok number
  else errorf path "unknown pull request #%d" value

let conflict_edges known value =
  let* values = array "$.conflict_edges" value in
  let rec loop index seen decoded = function
    | [] -> Ok (List.sort compare_conflict decoded)
    | raw :: rest ->
        let path = Printf.sprintf "$.conflict_edges[%d]" index in
        let* item = object_ path raw in
        let* () = exact_keys item [ "a"; "b"; "paths" ] path in
        let* a = pr_number known (path ^ ".a") (field item "a") in
        let* b = pr_number known (path ^ ".b") (field item "b") in
        if Pr_number.compare a b = 0 then
          errorf path "a conflict edge must join two different pull requests"
        else
          let a, b = if Pr_number.compare a b < 0 then (a, b) else (b, a) in
          if Pr_pair_set.mem (a, b) seen then
            errorf path "duplicate conflict edge #%s/#%s"
              (Pr_number.to_string a) (Pr_number.to_string b)
          else
            let* edge_paths = paths (path ^ ".paths") (field item "paths") in
            loop (index + 1)
              (Pr_pair_set.add (a, b) seen)
              ({ a; b; paths = edge_paths } :: decoded)
              rest
  in
  loop 0 Pr_pair_set.empty [] values

let ancestry_edges known value =
  let* values = array "$.ancestry_edges" value in
  let rec loop index seen decoded = function
    | [] -> Ok (List.sort Pr_pair.compare decoded)
    | raw :: rest ->
        let path = Printf.sprintf "$.ancestry_edges[%d]" index in
        let* item = object_ path raw in
        let* () = exact_keys item [ "before"; "after" ] path in
        let* before =
          pr_number known (path ^ ".before") (field item "before")
        in
        let* after = pr_number known (path ^ ".after") (field item "after") in
        if Pr_number.compare before after = 0 then
          errorf path "an ancestry edge must join two different pull requests"
        else if Pr_pair_set.mem (before, after) seen then
          errorf path "duplicate ancestry edge #%s -> #%s"
            (Pr_number.to_string before)
            (Pr_number.to_string after)
        else
          loop (index + 1)
            (Pr_pair_set.add (before, after) seen)
            ((before, after) :: decoded)
            rest
  in
  loop 0 Pr_pair_set.empty [] values

let document mode json =
  let* root = object_ "$" json in
  let* () =
    exact_keys root
      (match mode with Pure -> pure_root_keys | Git -> git_root_keys)
      "$"
  in
  let* version =
    integer ~positive:true "$.schema_version" (field root "schema_version")
  in
  if version <> 1 then
    errorf "$.schema_version" "only schema version 1 is supported"
  else
    let* repository = string "$.repository" (field root "repository") in
    let* raw_prs = array "$.prs" (field root "prs") in
    let* prs = decode_list (pull_request mode) raw_prs in
    let rec validate_prs numbers heads = function
      | [] -> Ok ()
      | pr :: rest ->
          if Pr_set.mem pr.number numbers then
            errorf "$.prs" "pull request numbers must be unique"
          else if String_set.mem pr.head_ref heads then
            errorf "$.prs" "head_ref values must be unique"
          else
            validate_prs
              (Pr_set.add pr.number numbers)
              (String_set.add pr.head_ref heads)
              rest
    in
    let* () = validate_prs Pr_set.empty String_set.empty prs in
    let prs =
      List.sort
        (fun left right -> Pr_number.compare left.number right.number)
        prs
    in
    let known =
      List.fold_left (fun set pr -> Pr_set.add pr.number set) Pr_set.empty prs
    in
    let* conflict_edges, ancestry_edges =
      match mode with
      | Pure ->
          let* conflicts = conflict_edges known (field root "conflict_edges") in
          let* ancestry = ancestry_edges known (field root "ancestry_edges") in
          Ok (conflicts, ancestry)
      | Git -> Ok ([], [])
    in
    Ok { repository; prs; conflict_edges; ancestry_edges }

let load path mode =
  let* contents = Bos.OS.File.read path in
  let* json =
    try Ok (Yojson.Basic.from_string contents)
    with Yojson.Json_error message ->
      Rresult.R.error_msgf "%a: invalid JSON: %s" Fpath.pp path message
  in
  document mode json
