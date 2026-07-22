import { assert, assertEquals, assertStringIncludes } from "./assert.ts";

const cli = new URL("../src/cli.ts", import.meta.url);
const input = new URL("../../../fixtures/pure-input.json", import.meta.url);

Deno.test("CLI prints help without reading input", async () => {
  const result = await invoke(["--help"]);
  assertEquals(result.code, 0);
  assertStringIncludes(result.stdout, "pr-plan pure --input FILE [--human]");
  assertEquals(result.stderr, "");
});

Deno.test("CLI assigns exit code 2 to malformed input", async () => {
  const path = await Deno.makeTempFile({
    prefix: "pr-plan-malformed-",
    suffix: ".json",
  });
  try {
    await Deno.writeTextFile(
      path,
      JSON.stringify({ schema_version: 1, repository: "bad", prs: "wrong" }),
    );
    const result = await invoke(["pure", "--input", path]);
    assertEquals(result.code, 2);
    assertStringIncludes(result.stderr, "input error:");
  } finally {
    await Deno.remove(path);
  }
});

Deno.test("CLI supports concurrent source invocations", async () => {
  const results = await Promise.all(
    Array.from(
      { length: 4 },
      () => invoke(["pure", "--input", input.pathname]),
    ),
  );
  assert(results.every((result) => result.code === 0));
  assertEquals(new Set(results.map((result) => result.stdout)).size, 1);
});

async function invoke(
  args: readonly string[],
): Promise<{ code: number; stdout: string; stderr: string }> {
  const output = await new Deno.Command(Deno.execPath(), {
    args: [
      "run",
      "--no-prompt",
      `--allow-read=${input.pathname},/tmp`,
      cli.pathname,
      ...args,
    ],
    stdout: "piped",
    stderr: "piped",
  }).output();
  const decoder = new TextDecoder();
  return {
    code: output.code,
    stdout: decoder.decode(output.stdout),
    stderr: decoder.decode(output.stderr),
  };
}
