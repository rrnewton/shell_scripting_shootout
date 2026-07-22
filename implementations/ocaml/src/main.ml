open Cmdliner
open Pr_plan

let fpath = Arg.conv (Fpath.of_string, Fpath.pp)

let input =
  Arg.(
    required
    & opt (some fpath) None
    & info [ "input" ] ~docv:"FILE"
        ~doc:"Read the version 1 input document from $(docv).")

let git_directory =
  Arg.(
    required
    & opt (some fpath) None
    & info [ "git-dir" ] ~docv:"DIR"
        ~doc:"Analyze objects and refs in the local Git repository $(docv).")

let human =
  Arg.(
    value & flag
    & info [ "human" ]
        ~doc:"Emit deterministic human-readable output instead of JSON.")

let execute mode input git_directory human =
  let ( let* ) = Result.bind in
  let result =
    let* data = Decode.load input mode in
    let* data =
      match (mode, git_directory) with
      | Decode.Pure, _ -> Ok data
      | Decode.Git, Some directory -> Git_analysis.analyze data directory
      | Decode.Git, None -> Error (`Msg "--git-dir is required in git mode")
    in
    let output =
      if human then Render.render_human (Planner.make data)
      else Render.render_json (Planner.make data)
    in
    print_string output;
    Ok ()
  in
  match result with
  | Ok () -> `Ok ()
  | Error (`Msg message) -> `Error (false, "pr-plan: error: " ^ message)

let pure_command =
  let term =
    Term.(
      ret
        (const (fun input human -> execute Decode.Pure input None human)
        $ input $ human))
  in
  Cmd.v
    (Cmd.info "pure" ~doc:"Plan from validated precomputed graph data.")
    term

let git_command =
  let term =
    Term.(
      ret
        (const (fun input directory human ->
             execute Decode.Git input (Some directory) human)
        $ input $ git_directory $ human))
  in
  Cmd.v
    (Cmd.info "git"
       ~doc:"Analyze a local Git repository and build a landing plan.")
    term

let command =
  Cmd.group
    (Cmd.info "pr-plan" ~version:"0.1.0"
       ~doc:"Build deterministic pull-request conflict and landing plans.")
    [ pure_command; git_command ]

let () = exit (Cmd.eval command)
