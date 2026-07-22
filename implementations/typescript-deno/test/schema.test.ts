import { parseGitInput, parsePureInput } from "../src/schema.ts";
import { assertEquals, assertThrows } from "./assert.ts";

const pureFixture = new URL(
  "../../../fixtures/pure-input.json",
  import.meta.url,
);
const gitFixture = new URL("../../../fixtures/git-input.json", import.meta.url);

Deno.test("runtime decoder accepts the shared inputs", async () => {
  const pure: unknown = JSON.parse(await Deno.readTextFile(pureFixture));
  const git: unknown = JSON.parse(await Deno.readTextFile(gitFixture));
  assertEquals(parsePureInput(pure).schema_version, 1);
  assertEquals(parseGitInput(git).schema_version, 1);
});

Deno.test("runtime decoder rejects incorrect and unknown fields", async () => {
  const raw: unknown = JSON.parse(await Deno.readTextFile(pureFixture));
  const parsed = parsePureInput(raw);
  const first = parsed.prs[0];
  if (first === undefined) throw new Error("fixture must contain a PR");
  assertThrows(
    () =>
      parsePureInput({
        ...parsed,
        prs: [{ ...first, number: "1" }, ...parsed.prs.slice(1)],
      }),
    "expected a safe integer",
  );
  assertThrows(
    () => parsePureInput({ ...parsed, surprise: true }),
    "unknown field(s): surprise",
  );
  assertThrows(
    () =>
      parsePureInput({
        ...parsed,
        prs: [{ ...first, mergeable: "MAYBE" }, ...parsed.prs.slice(1)],
      }),
    "expected one of",
  );
  assertThrows(
    () =>
      parsePureInput({
        ...parsed,
        prs: [
          { ...first, created_at: "2026-02-31T00:00:00Z" },
          ...parsed.prs.slice(1),
        ],
      }),
    "expected an RFC 3339 timestamp",
  );
});

Deno.test("runtime decoder rejects duplicates, dangling edges, and unsafe revisions", async () => {
  const rawPure: unknown = JSON.parse(await Deno.readTextFile(pureFixture));
  const pure = parsePureInput(rawPure);
  const first = pure.prs[0];
  if (first === undefined) throw new Error("fixture must contain a PR");
  assertThrows(
    () => parsePureInput({ ...pure, prs: [...pure.prs, first] }),
    "duplicate PR number",
  );
  const pureSecond = pure.prs[1];
  if (pureSecond === undefined) throw new Error("fixture must contain two PRs");
  assertThrows(
    () =>
      parsePureInput({
        ...pure,
        prs: [
          first,
          { ...pureSecond, head_ref: first.head_ref },
          ...pure.prs.slice(2),
        ],
      }),
    "head_ref values must be unique",
  );
  assertThrows(
    () =>
      parsePureInput({
        ...pure,
        conflict_edges: [{ a: first.number, b: 999, paths: ["x"] }],
      }),
    "unknown PR",
  );

  const rawGit: unknown = JSON.parse(await Deno.readTextFile(gitFixture));
  const git = parseGitInput(rawGit);
  const gitFirst = git.prs[0];
  if (gitFirst === undefined) throw new Error("fixture must contain a PR");
  const gitSecond = git.prs[1];
  if (gitSecond === undefined) throw new Error("fixture must contain two PRs");
  assertThrows(
    () =>
      parseGitInput({
        ...git,
        prs: [
          gitFirst,
          { ...gitSecond, head_ref: gitFirst.head_ref },
          ...git.prs.slice(2),
        ],
      }),
    "head_ref values must be unique",
  );
  assertThrows(
    () =>
      parseGitInput({
        ...git,
        prs: [{ ...gitFirst, git_head: "--help" }, ...git.prs.slice(1)],
      }),
    "revision must not start",
  );
});
