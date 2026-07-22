open Model

let ( let* ) = Result.bind

let errorf format =
  Format.kasprintf (fun message -> Error (`Msg message)) format

type command_result = { status : int; stdout : string; stderr : string }

let sanitized_environment () =
  let* environment = Bos.OS.Env.current () in
  let inherited_git_variables =
    [
      "GIT_ALTERNATE_OBJECT_DIRECTORIES";
      "GIT_COMMON_DIR";
      "GIT_CONFIG_COUNT";
      "GIT_CONFIG_PARAMETERS";
      "GIT_DIR";
      "GIT_INDEX_FILE";
      "GIT_OBJECT_DIRECTORY";
      "GIT_WORK_TREE";
    ]
  in
  let environment =
    List.fold_left
      (fun env name -> Astring.String.Map.remove name env)
      environment inherited_git_variables
  in
  Ok
    (environment
    |> Astring.String.Map.add "GIT_CONFIG_NOSYSTEM" "1"
    |> Astring.String.Map.add "GIT_CONFIG_GLOBAL" "/dev/null"
    |> Astring.String.Map.add "GIT_OPTIONAL_LOCKS" "0"
    |> Astring.String.Map.add "GIT_TERMINAL_PROMPT" "0"
    |> Astring.String.Map.add "LC_ALL" "C")

let run_git repository arguments ~expected =
  let* environment = sanitized_environment () in
  let* stderr_path = Bos.OS.File.tmp "pr-plan-git-stderr-%s" in
  let command =
    Bos.Cmd.of_list
      ([ "git"; "-C"; Fpath.to_string repository; "--no-pager" ] @ arguments)
  in
  let output =
    Bos.OS.Cmd.run_io ~env:environment
      ~err:(Bos.OS.Cmd.err_file stderr_path)
      command Bos.OS.Cmd.in_null
    |> Bos.OS.Cmd.out_string ~trim:false
  in
  let stderr = Bos.OS.File.read stderr_path in
  let _ = Bos.OS.File.delete stderr_path in
  match (output, stderr) with
  | Error (`Msg message), _ -> Error (`Msg message)
  | _, Error (`Msg message) -> Error (`Msg message)
  | Ok (stdout, (_, `Exited status)), Ok stderr when List.mem status expected ->
      Ok { status; stdout; stderr }
  | Ok (_, (_, `Exited status)), Ok stderr ->
      let operation =
        Option.value ~default:"command" (List.nth_opt arguments 0)
      in
      let detail = String.trim stderr in
      errorf "git %s exited with status %d%s" operation status
        (if detail = "" then "" else ": " ^ detail)
  | Ok (_, (_, `Signaled signal)), Ok _ ->
      let operation =
        Option.value ~default:"command" (List.nth_opt arguments 0)
      in
      errorf "git %s was terminated by signal %d" operation signal

let is_hex value =
  let is_hex_char = function
    | '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true
    | _ -> false
  in
  (String.length value = 40 || String.length value = 64)
  && String.for_all is_hex_char value

let object_id operation output =
  let value = String.trim output in
  if is_hex value then Ok (Object_id (String.lowercase_ascii value))
  else errorf "git %s returned an invalid commit ID" operation

let object_id_string (Object_id value) = value

let resolve_commit repository (Git_revision revision) =
  let* result =
    run_git repository
      [ "rev-parse"; "--verify"; "--end-of-options"; revision ^ "^{commit}" ]
      ~expected:[ 0 ]
  in
  object_id "rev-parse" result.stdout

let merge_base repository left right =
  let* result =
    run_git repository
      [ "merge-base"; object_id_string left; object_id_string right ]
      ~expected:[ 0 ]
  in
  object_id "merge-base" result.stdout

let path_records records =
  let rec loop paths = function
    | [] -> Ok (List.sort_uniq Fpath.compare paths)
    | "" :: rest -> loop paths rest
    | raw :: rest ->
        let* path =
          match Fpath.of_string raw with
          | Ok path when Fpath.is_rel path -> Ok path
          | Ok _ -> errorf "git returned an absolute repository path: %S" raw
          | Error (`Msg message) ->
              errorf "git returned an invalid path %S: %s" raw message
        in
        loop (path :: paths) rest
  in
  loop [] records

let nul_records output = String.split_on_char '\000' output

let changed_files repository base head =
  let* common = merge_base repository base head in
  let* result =
    run_git repository
      [
        "diff";
        "--name-only";
        "-z";
        object_id_string common;
        object_id_string head;
        "--";
      ]
      ~expected:[ 0 ]
  in
  path_records (nul_records result.stdout)

let conflict_paths repository left right =
  let* result =
    run_git repository
      [
        "merge-tree";
        "--write-tree";
        "--name-only";
        "--no-messages";
        "-z";
        object_id_string left;
        object_id_string right;
      ]
      ~expected:[ 0; 1 ]
  in
  if result.status = 0 then Ok []
  else
    match nul_records result.stdout with
    | [] | [ "" ] -> errorf "git merge-tree reported a conflict without output"
    | _tree :: records -> path_records records

let is_ancestor repository before after =
  let* result =
    run_git repository
      [
        "merge-base";
        "--is-ancestor";
        object_id_string before;
        object_id_string after;
      ]
      ~expected:[ 0; 1 ]
  in
  Ok (result.status = 0)

type resolved_pr = { pr : pull_request; head : object_id }

let analyze input repository =
  let* directory_exists = Bos.OS.Dir.exists repository in
  if not directory_exists then
    errorf "%a: Git directory must be a directory" Fpath.pp repository
  else
    let* _ = run_git repository [ "rev-parse"; "--git-dir" ] ~expected:[ 0 ] in
    let rec resolve_prs resolved analyzed = function
      | [] -> Ok (List.rev resolved, List.rev analyzed)
      | pr :: rest -> (
          match (pr.git_head, pr.git_base) with
          | Some head_revision, Some base_revision ->
              let* head = resolve_commit repository head_revision in
              let* base = resolve_commit repository base_revision in
              let* files = changed_files repository base head in
              let* base_conflict_paths = conflict_paths repository base head in
              let analyzed_pr = { pr with files; base_conflict_paths } in
              resolve_prs
                ({ pr = analyzed_pr; head } :: resolved)
                (analyzed_pr :: analyzed) rest
          | _ ->
              errorf "internal error: missing Git revisions for PR #%s"
                (Pr_number.to_string pr.number))
    in
    let* resolved, prs = resolve_prs [] [] input.prs in
    let rec pairs conflicts ancestry = function
      | [] -> Ok (List.rev conflicts, List.sort Pr_pair.compare ancestry)
      | left :: rest ->
          let rec compare_right conflicts ancestry = function
            | [] -> pairs conflicts ancestry rest
            | right :: rights ->
                let* paths = conflict_paths repository left.head right.head in
                let conflicts =
                  if paths = [] then conflicts
                  else
                    { a = left.pr.number; b = right.pr.number; paths }
                    :: conflicts
                in
                let* left_before =
                  is_ancestor repository left.head right.head
                in
                let* right_before =
                  is_ancestor repository right.head left.head
                in
                let ancestry =
                  ( ancestry |> fun edges ->
                    if left_before then
                      (left.pr.number, right.pr.number) :: edges
                    else edges )
                  |> fun edges ->
                  if right_before then
                    (right.pr.number, left.pr.number) :: edges
                  else edges
                in
                compare_right conflicts ancestry rights
          in
          compare_right conflicts ancestry rest
    in
    let* conflict_edges, ancestry_edges = pairs [] [] resolved in
    Ok { input with prs; conflict_edges; ancestry_edges }
