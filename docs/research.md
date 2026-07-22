# Research Notes

The benchmark was designed after reviewing both existing repository scripts and
published language/runtime material. Most public language shootouts emphasize
algorithm throughput; they do not exercise typed JSON boundaries, repeated
source entry, subprocess status handling, Git worktrees, or deterministic graph
planning. A small [interpreter startup comparison][startup] reinforced the need
to separate process startup from useful work, while [hyperfine][hyperfine]
informed the warmup/distribution protocol. This repository records raw samples
directly rather than depending on hyperfine at runtime.

The `pr-plan` workload is a frozen standalone derivative of the PR interference
and conflict-planning scripts in DeepScry and Hermit. It combines their useful
properties: GitHub-shaped metadata, real `git diff`/`merge-tree`/ancestry
queries, expected nonzero statuses, deterministic conflict graphs, stacks, and
landing batches. Live GitHub state is collected once through the shared,
untimed [`gh` adapter](live-github.md).

## Runner Sources

- [`rust-script`][rust-script] is a maintained, purpose-built source runner
  using stable Rust and optimized cached executables.
- [Cargo script RFC 3424][cargo-rfc] defines the upstream single-file package
  design. The [Cargo script project goal][cargo-goal] documents stabilization
  work; the tested Cargo still requires nightly `-Zscript`.
- [Bun TypeScript documentation][bun-ts] documents direct TypeScript execution.
  Runtime execution transpiles but does not replace a strict typecheck.
- [Deno TypeScript documentation][deno-ts] and its [permission model][deno-sec]
  motivated the dependency-free Deno candidate's cached-only, no-network,
  least-permission launcher.
- [Scala CLI][scala-cli] supplies Scala's source directives and cached build
  path. The benchmark disables its build server so no persistent daemon is
  hidden from the per-invocation result.
- [.NET 10 file-based applications][dotnet-files] and
  [F# Interactive][fsi] are credible future entries.

## Additional Candidates

The completed stretch entries are D/`rdmd`, Nim, Deno, and Scala. Other useful
follow-ups are:

- **C# file-based apps / F# scripts:** strong checking and official source
  entry, but a large .NET installation and runtime-memory question.
- **Haskell with Turtle or Shelly:** strong types and established shell DSLs;
  package/toolchain bootstrap and `runghc` startup are the main risks.
- **Crystal:** concise process code and native artifacts, but a less expressive
  type/effect story and no clearly superior transparent source cache.
- **Swift:** strong types and good native performance with a large Linux
  toolchain and thinner repository-scripting ecosystem.
- **Zig:** excellent native control, but JSON/process ergonomics would make this
  workload substantially lower-level.
- **Kotlin scripting:** omitted because Scala already supplies the JVM source
  runner control case.
- **Nushell and Julia:** attractive scripting environments, but neither meets
  this shootout's strong static-checking requirement.

Bash remains deliberately excluded. Thin launchers are allowed, but all graph,
validation, and Git behavior belongs to the candidate language.

[startup]: https://dev.to/serpent7776/measuring-startup-and-shutdown-overhead-of-several-code-interpreters-5hbl
[hyperfine]: https://github.com/sharkdp/hyperfine
[rust-script]: https://github.com/fornwall/rust-script
[cargo-rfc]: https://rust-lang.github.io/rfcs/3424-cargo-script.html
[cargo-goal]: https://rust-lang.github.io/rust-project-goals/2024h2/cargo-script.html
[bun-ts]: https://bun.sh/docs/runtime/typescript
[deno-ts]: https://docs.deno.com/runtime/fundamentals/typescript/
[deno-sec]: https://docs.deno.com/runtime/fundamentals/security/
[scala-cli]: https://scala-cli.virtuslab.org/
[dotnet-files]: https://learn.microsoft.com/en-us/dotnet/core/sdk/file-based-apps
[fsi]: https://learn.microsoft.com/en-us/dotnet/fsharp/tools/fsharp-interactive/
