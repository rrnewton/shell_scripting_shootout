import { describe, expect, test } from "bun:test";

const cli = new URL("../src/cli.ts", import.meta.url).pathname;
const input = new URL("fixtures/pure.json", import.meta.url).pathname;

describe("command line", () => {
  test("prints help without reading input", async () => {
    const result = await invoke(["--help"]);
    expect(result.exitCode).toBe(0);
    expect(result.stdout).toContain("pr-plan pure --input FILE [--human]");
    expect(result.stderr).toBe("");
  });

  test("uses stable exit code 2 for malformed input", async () => {
    const malformed = await temporaryJson({ schema_version: 1, repository: "bad", prs: "wrong" });
    const result = await invoke(["pure", "--input", malformed]);
    expect(result.exitCode).toBe(2);
    expect(result.stderr).toContain("input error:");
  });

  test("supports concurrent source invocations", async () => {
    const results = await Promise.all(
      Array.from({ length: 4 }, () => invoke(["pure", "--input", input])),
    );
    expect(results.every((result) => result.exitCode === 0)).toBe(true);
    expect(new Set(results.map((result) => result.stdout)).size).toBe(1);
  });
});

async function invoke(args: readonly string[]) {
  const child = Bun.spawn([process.execPath, "run", cli, ...args], {
    stdout: "pipe",
    stderr: "pipe",
  });
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ]);
  return { stdout, stderr, exitCode };
}

async function temporaryJson(value: unknown): Promise<string> {
  const path = `${Bun.env["TMPDIR"] ?? "/tmp"}/pr-plan-malformed-${crypto.randomUUID()}.json`;
  await Bun.write(path, JSON.stringify(value));
  return path;
}
