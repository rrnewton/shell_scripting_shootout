open Pr_plan

let fail message =
  prerr_endline ("test failure: " ^ message);
  exit 1

let check condition message = if not condition then fail message

let expect_error result message =
  check (match result with Error _ -> true | Ok _ -> false) message

let base_pr =
  {|{
    "number": 1,
    "title": "First",
    "author": null,
    "head_ref": "feature/one",
    "base_ref": "main",
    "draft": false,
    "mergeable": "MERGEABLE",
    "review_decision": "APPROVED",
    "created_at": "2026-01-01T00:00:00Z",
    "updated_at": "2026-01-02T00:00:00Z",
    "additions": 1,
    "deletions": 0,
    "files": ["one.txt"],
    "base_conflict_paths": []
  }|}

let document pr =
  Yojson.Basic.from_string
    (Printf.sprintf
       {|{"schema_version":1,"repository":"acme/widgets","prs":[%s],"conflict_edges":[],"ancestry_edges":[]}|}
       pr)

let () =
  let data =
    match Decode.document Decode.Pure (document base_pr) with
    | Ok data -> data
    | Error (`Msg message) -> fail message
  in
  let plan = Planner.make data in
  check (List.length plan.nodes = 1) "single node was not retained";
  check
    (List.length plan.suggested_landing_batches = 1)
    "single PR was not batched";
  check
    (Model.Pr_number.to_int (List.hd plan.ready_now) = 1)
    "single PR was not ready";
  let rendered = Render.render_json plan in
  check (String.contains rendered 'F') "JSON renderer omitted the title";
  check
    (String.equal rendered (Render.render_json plan))
    "JSON rendering was not deterministic";
  let empty =
    match
      Decode.document Decode.Pure
        (Yojson.Basic.from_string
           {|{"schema_version":1,"repository":"acme/widgets","prs":[],"conflict_edges":[],"ancestry_edges":[]}|})
    with
    | Ok data -> Planner.make data
    | Error (`Msg message) -> fail message
  in
  check
    (empty.suggested_landing_batches = [])
    "empty input produced a landing batch";
  check (empty.ready_now = []) "empty input produced a ready PR";
  let malformed =
    String.concat ""
      [
        {|{"schema_version":1,"repository":7,"prs":[],"conflict_edges":[],"ancestry_edges":[]}|};
      ]
  in
  expect_error
    (Decode.document Decode.Pure (Yojson.Basic.from_string malformed))
    "wrongly typed repository was accepted";
  let wrong_number =
    String.concat ""
      [
        {|{"number":"1","title":"First","author":null,"head_ref":"feature/one","base_ref":"main","draft":false,"mergeable":"MERGEABLE","review_decision":"APPROVED","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-02T00:00:00Z","additions":1,"deletions":0,"files":[],"base_conflict_paths":[]}|};
      ]
  in
  expect_error
    (Decode.document Decode.Pure (document wrong_number))
    "string PR number was accepted";
  let duplicate_paths =
    {|{"number":1,"title":"First","author":null,"head_ref":"feature/one","base_ref":"main","draft":false,"mergeable":"MERGEABLE","review_decision":"APPROVED","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-02T00:00:00Z","additions":1,"deletions":0,"files":["same","same"],"base_conflict_paths":[]}|}
  in
  expect_error
    (Decode.document Decode.Pure (document duplicate_paths))
    "duplicate paths were accepted";
  match
    Bos.OS.Dir.with_tmp "pr-plan-git-test-%s"
      (fun repository () ->
        match
          Git_analysis.run_git repository [ "init"; "--quiet" ] ~expected:[ 0 ]
        with
        | Error _ as error -> error
        | Ok _ -> (
            match
              Git_analysis.run_git repository
                [ "rev-parse"; "--verify"; "missing" ]
                ~expected:[ 0; 128 ]
            with
            | Ok result when result.status = 128 ->
                expect_error
                  (Git_analysis.run_git repository
                     [ "rev-parse"; "--verify"; "missing" ]
                     ~expected:[ 0 ])
                  "unexpected Git status was accepted";
                Ok ()
            | Ok _ -> Error (`Msg "expected Git status 128")
            | Error _ as error -> error))
      ()
  with
  | Ok (Ok ()) -> ()
  | Ok (Error (`Msg message)) | Error (`Msg message) -> fail message
