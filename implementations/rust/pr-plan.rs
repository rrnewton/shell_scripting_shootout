#!/usr/bin/env rust-script
//! ```cargo
//! [package]
//! edition = "2024"
//!
//! [dependencies]
//! clap = { version = "=4.6.4", features = ["derive"] }
//! serde = { version = "=1.0.229", features = ["derive"] }
//! serde_json = "=1.0.151"
//! ```

use clap::{Parser, Subcommand};
use serde::{Deserialize, Deserializer, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::ffi::{OsStr, OsString};
use std::fmt::{self, Display};
use std::fs;
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, Output};

type Result<T> = std::result::Result<T, AppError>;

#[derive(Debug)]
struct AppError(String);

impl Display for AppError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for AppError {}

impl From<io::Error> for AppError {
    fn from(error: io::Error) -> Self {
        Self(error.to_string())
    }
}

impl From<serde_json::Error> for AppError {
    fn from(error: serde_json::Error) -> Self {
        Self(error.to_string())
    }
}

fn fail(message: impl Into<String>) -> AppError {
    AppError(message.into())
}

#[derive(Parser)]
#[command(
    name = "pr-plan",
    version,
    about = "Plan deterministic pull-request landing batches"
)]
struct Cli {
    #[command(subcommand)]
    command: Mode,
}

#[derive(Subcommand)]
enum Mode {
    /// Validate a fully collected graph and plan without child processes.
    Pure {
        /// JSON input path, or - for standard input.
        #[arg(long)]
        input: PathBuf,
        /// Render stable human-readable text instead of canonical JSON.
        #[arg(long)]
        human: bool,
    },
    /// Collect graph data from an immutable local Git repository and plan.
    Git {
        /// JSON input path, or - for standard input.
        #[arg(long)]
        input: PathBuf,
        /// Worktree root or bare .git directory to inspect.
        #[arg(long)]
        git_dir: PathBuf,
        /// Render stable human-readable text instead of canonical JSON.
        #[arg(long)]
        human: bool,
    },
}

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(transparent)]
struct PrNumber(u64);

impl<'de> Deserialize<'de> for PrNumber {
    fn deserialize<D>(deserializer: D) -> std::result::Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value = u64::deserialize(deserializer)?;
        if value == 0 {
            return Err(serde::de::Error::custom(
                "PR number must be greater than zero",
            ));
        }
        Ok(Self(value))
    }
}

impl Display for PrNumber {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        Display::fmt(&self.0, formatter)
    }
}

#[derive(Clone, Debug, Deserialize)]
#[serde(transparent)]
struct GitRevision(String);

impl GitRevision {
    fn validate(&self, field: &str) -> Result<()> {
        validate_nonempty(field, &self.0)?;
        if self.0.starts_with('-') || self.0.chars().any(char::is_control) {
            return Err(fail(format!("{field} is not a safe Git revision")));
        }
        Ok(())
    }
}

#[derive(Clone, Debug)]
struct CommitId(String);

impl CommitId {
    fn parse(value: String) -> Result<Self> {
        let value = value.trim().to_owned();
        if !matches!(value.len(), 40 | 64) || !value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return Err(fail(format!("Git returned invalid commit ID {value:?}")));
        }
        Ok(Self(value))
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
enum Mergeability {
    Mergeable,
    Conflicting,
    Unknown,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
enum ReviewDecision {
    Approved,
    ChangesRequested,
    ReviewRequired,
    None,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct PureInput {
    schema_version: u32,
    repository: String,
    prs: Vec<PurePr>,
    conflict_edges: Vec<PathEdge>,
    ancestry_edges: Vec<AncestryInput>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct PurePr {
    number: PrNumber,
    title: String,
    author: Option<String>,
    head_ref: String,
    base_ref: String,
    draft: bool,
    mergeable: Mergeability,
    review_decision: ReviewDecision,
    created_at: String,
    updated_at: String,
    additions: u64,
    deletions: u64,
    files: Vec<String>,
    base_conflict_paths: Vec<String>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct GitInput {
    schema_version: u32,
    repository: String,
    prs: Vec<GitPr>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct GitPr {
    number: PrNumber,
    title: String,
    author: Option<String>,
    head_ref: String,
    base_ref: String,
    draft: bool,
    mergeable: Mergeability,
    review_decision: ReviewDecision,
    created_at: String,
    updated_at: String,
    additions: u64,
    deletions: u64,
    git_head: GitRevision,
    git_base: GitRevision,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
struct PathEdge {
    a: PrNumber,
    b: PrNumber,
    paths: Vec<String>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct AncestryInput {
    before: PrNumber,
    after: PrNumber,
}

#[derive(Clone, Debug, Serialize)]
struct Node {
    pr: PrNumber,
    title: String,
    author: String,
    head_ref: String,
    base_ref: String,
    draft: bool,
    mergeable: Mergeability,
    review_decision: ReviewDecision,
    additions: u64,
    deletions: u64,
    files_count: usize,
    base_conflict_paths: Vec<String>,
    #[serde(skip)]
    files: Vec<String>,
    #[serde(skip)]
    created_at: String,
}

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd, Serialize)]
struct OrderingEdge {
    before: PrNumber,
    after: PrNumber,
    reason: OrderingReason,
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd, Serialize)]
enum OrderingReason {
    #[serde(rename = "base-ref")]
    BaseRef,
    #[serde(rename = "ancestry")]
    Ancestry,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
struct HeldPr {
    pr: PrNumber,
    reasons: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
struct RebaseStep {
    pr: PrNumber,
    after: Vec<PrNumber>,
    reasons: Vec<String>,
}

#[derive(Clone, Debug, Serialize)]
struct Plan {
    repository: String,
    nodes: Vec<Node>,
    conflict_edges: Vec<PathEdge>,
    file_overlap_edges: Vec<PathEdge>,
    ordering_edges: Vec<OrderingEdge>,
    stacks: Vec<Vec<PrNumber>>,
    suggested_landing_batches: Vec<Vec<PrNumber>>,
    suggested_rebase_plan: Vec<RebaseStep>,
    ready_landing_batches: Vec<Vec<PrNumber>>,
    ready_now: Vec<PrNumber>,
    held_prs: Vec<HeldPr>,
    ordering_cycles: Vec<PrNumber>,
}

struct GraphInput {
    repository: String,
    nodes: Vec<Node>,
    conflicts: Vec<PathEdge>,
    ancestry: Vec<AncestryInput>,
}

fn main() -> ExitCode {
    match run(Cli::parse()) {
        Ok(output) => {
            print!("{output}");
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("error: {error}");
            ExitCode::FAILURE
        }
    }
}

fn run(cli: Cli) -> Result<String> {
    let (graph, human) = match cli.command {
        Mode::Pure { input, human } => {
            let input: PureInput = read_json(&input)?;
            (normalize_pure(input)?, human)
        }
        Mode::Git {
            input,
            git_dir,
            human,
        } => {
            let input: GitInput = read_json(&input)?;
            (analyze_git(input, &git_dir)?, human)
        }
    };
    let plan = build_plan(graph)?;
    if human {
        Ok(render_human(&plan))
    } else {
        let mut output = serde_json::to_string_pretty(&plan)?;
        output.push('\n');
        Ok(output)
    }
}

fn read_json<T: for<'de> Deserialize<'de>>(path: &Path) -> Result<T> {
    let source = if path == Path::new("-") {
        let mut source = String::new();
        io::stdin().read_to_string(&mut source)?;
        source
    } else {
        fs::read_to_string(path)
            .map_err(|error| fail(format!("cannot read {}: {error}", path.display())))?
    };
    serde_json::from_str(&source).map_err(|error| {
        fail(format!(
            "invalid JSON in {}: {error}",
            if path == Path::new("-") {
                "standard input".to_owned()
            } else {
                path.display().to_string()
            }
        ))
    })
}

fn validate_header(schema_version: u32, repository: &str) -> Result<()> {
    if schema_version != 1 {
        return Err(fail(format!(
            "unsupported schema_version {schema_version}; expected 1"
        )));
    }
    validate_nonempty("repository", repository)
}

fn validate_nonempty(field: &str, value: &str) -> Result<()> {
    if value.trim().is_empty() {
        Err(fail(format!("{field} must not be empty")))
    } else if value.contains('\0') {
        Err(fail(format!("{field} must not contain NUL")))
    } else {
        Ok(())
    }
}

fn validate_metadata(
    number: PrNumber,
    title: &str,
    author: Option<&str>,
    head_ref: &str,
    base_ref: &str,
    created_at: &str,
    updated_at: &str,
) -> Result<()> {
    for (field, value) in [
        ("title", title),
        ("head_ref", head_ref),
        ("base_ref", base_ref),
        ("created_at", created_at),
        ("updated_at", updated_at),
    ] {
        validate_nonempty(&format!("PR {number} {field}"), value)?;
    }
    if let Some(author) = author {
        validate_nonempty(&format!("PR {number} author"), author)?;
    }
    Ok(())
}

fn normalize_paths(number: PrNumber, field: &str, paths: Vec<String>) -> Result<Vec<String>> {
    let mut normalized = BTreeSet::new();
    for path in paths {
        validate_nonempty(&format!("PR {number} {field} path"), &path)?;
        if Path::new(&path).is_absolute() {
            return Err(fail(format!(
                "PR {number} {field} path must be repository-relative: {path:?}"
            )));
        }
        if !normalized.insert(path.clone()) {
            return Err(fail(format!(
                "PR {number} {field} contains duplicate path {path:?}"
            )));
        }
    }
    Ok(normalized.into_iter().collect())
}

fn pure_node(pr: PurePr) -> Result<Node> {
    validate_metadata(
        pr.number,
        &pr.title,
        pr.author.as_deref(),
        &pr.head_ref,
        &pr.base_ref,
        &pr.created_at,
        &pr.updated_at,
    )?;
    let files = normalize_paths(pr.number, "files", pr.files)?;
    let base_conflict_paths =
        normalize_paths(pr.number, "base_conflict_paths", pr.base_conflict_paths)?;
    Ok(Node {
        pr: pr.number,
        title: pr.title,
        author: pr.author.unwrap_or_else(|| "unknown".to_owned()),
        head_ref: pr.head_ref,
        base_ref: pr.base_ref,
        draft: pr.draft,
        mergeable: pr.mergeable,
        review_decision: pr.review_decision,
        additions: pr.additions,
        deletions: pr.deletions,
        files_count: files.len(),
        base_conflict_paths,
        files,
        created_at: pr.created_at,
    })
}

fn normalize_pure(input: PureInput) -> Result<GraphInput> {
    validate_header(input.schema_version, &input.repository)?;
    let mut nodes = input
        .prs
        .into_iter()
        .map(pure_node)
        .collect::<Result<Vec<_>>>()?;
    nodes.sort_by_key(|node| node.pr);
    validate_unique_nodes(&nodes)?;
    let numbers: BTreeSet<_> = nodes.iter().map(|node| node.pr).collect();
    let conflicts = normalize_path_edges(input.conflict_edges, &numbers, "conflict_edges")?;
    let ancestry = normalize_ancestry(input.ancestry_edges, &numbers)?;
    Ok(GraphInput {
        repository: input.repository,
        nodes,
        conflicts,
        ancestry,
    })
}

fn validate_unique_nodes(nodes: &[Node]) -> Result<()> {
    for pair in nodes.windows(2) {
        if pair[0].pr == pair[1].pr {
            return Err(fail(format!("duplicate PR number {}", pair[0].pr)));
        }
    }
    let mut head_refs = BTreeSet::new();
    for node in nodes {
        if !head_refs.insert(&node.head_ref) {
            return Err(fail(format!("duplicate head_ref {:?}", node.head_ref)));
        }
    }
    Ok(())
}

fn normalize_path_edges(
    edges: Vec<PathEdge>,
    numbers: &BTreeSet<PrNumber>,
    field: &str,
) -> Result<Vec<PathEdge>> {
    let mut seen = BTreeSet::new();
    let mut normalized = Vec::new();
    for mut edge in edges {
        if edge.a == edge.b {
            return Err(fail(format!(
                "{field} contains self edge for PR {}",
                edge.a
            )));
        }
        if !numbers.contains(&edge.a) || !numbers.contains(&edge.b) {
            return Err(fail(format!(
                "{field} edge {}-{} references an unknown PR",
                edge.a, edge.b
            )));
        }
        let key = ordered_pair(edge.a, edge.b);
        if !seen.insert(key) {
            return Err(fail(format!(
                "{field} contains duplicate edge {}-{}",
                key.0, key.1
            )));
        }
        if edge.paths.is_empty() {
            return Err(fail(format!(
                "{field} edge {}-{} must contain at least one path",
                edge.a, edge.b
            )));
        }
        let mut paths = BTreeSet::new();
        for path in edge.paths.drain(..) {
            validate_nonempty(&format!("{field} path"), &path)?;
            if Path::new(&path).is_absolute() {
                return Err(fail(format!("{field} path must be repository-relative")));
            }
            if !paths.insert(path.clone()) {
                return Err(fail(format!(
                    "{field} edge {}-{} contains duplicate path {path:?}",
                    edge.a, edge.b
                )));
            }
        }
        normalized.push(PathEdge {
            a: key.0,
            b: key.1,
            paths: paths.into_iter().collect(),
        });
    }
    normalized.sort_by_key(|edge| (edge.a, edge.b));
    Ok(normalized)
}

fn normalize_ancestry(
    edges: Vec<AncestryInput>,
    numbers: &BTreeSet<PrNumber>,
) -> Result<Vec<AncestryInput>> {
    let mut normalized = BTreeSet::new();
    for edge in edges {
        if edge.before == edge.after {
            return Err(fail(format!(
                "ancestry_edges contains self edge for PR {}",
                edge.before
            )));
        }
        if !numbers.contains(&edge.before) || !numbers.contains(&edge.after) {
            return Err(fail(format!(
                "ancestry edge {}->{} references an unknown PR",
                edge.before, edge.after
            )));
        }
        if !normalized.insert((edge.before, edge.after)) {
            return Err(fail(format!(
                "duplicate ancestry edge {}->{}",
                edge.before, edge.after
            )));
        }
    }
    Ok(normalized
        .into_iter()
        .map(|(before, after)| AncestryInput { before, after })
        .collect())
}

fn analyze_git(input: GitInput, git_dir: &Path) -> Result<GraphInput> {
    validate_header(input.schema_version, &input.repository)?;
    let git = Git::open(git_dir)?;
    let mut records = input.prs;
    records.sort_by_key(|pr| pr.number);
    for pair in records.windows(2) {
        if pair[0].number == pair[1].number {
            return Err(fail(format!("duplicate PR number {}", pair[0].number)));
        }
    }

    let mut revisions = BTreeMap::<PrNumber, (CommitId, CommitId)>::new();
    let mut nodes = Vec::with_capacity(records.len());
    for pr in records {
        validate_metadata(
            pr.number,
            &pr.title,
            pr.author.as_deref(),
            &pr.head_ref,
            &pr.base_ref,
            &pr.created_at,
            &pr.updated_at,
        )?;
        pr.git_head
            .validate(&format!("PR {} git_head", pr.number))?;
        pr.git_base
            .validate(&format!("PR {} git_base", pr.number))?;
        let head = git.resolve(&pr.git_head)?;
        let base = git.resolve(&pr.git_base)?;
        let files = git.changed_files(&base, &head)?;
        let base_conflict_paths = git.merge_conflicts(&base, &head)?;
        revisions.insert(pr.number, (base, head));
        nodes.push(Node {
            pr: pr.number,
            title: pr.title,
            author: pr.author.unwrap_or_else(|| "unknown".to_owned()),
            head_ref: pr.head_ref,
            base_ref: pr.base_ref,
            draft: pr.draft,
            mergeable: pr.mergeable,
            review_decision: pr.review_decision,
            additions: pr.additions,
            deletions: pr.deletions,
            files_count: files.len(),
            base_conflict_paths,
            files,
            created_at: pr.created_at,
        });
    }
    validate_unique_nodes(&nodes)?;

    let mut conflicts = Vec::new();
    let mut ancestry = Vec::new();
    for (index, left) in nodes.iter().enumerate() {
        for right in &nodes[index + 1..] {
            let left_head = &revisions[&left.pr].1;
            let right_head = &revisions[&right.pr].1;
            let paths = git.merge_conflicts(left_head, right_head)?;
            if !paths.is_empty() {
                conflicts.push(PathEdge {
                    a: left.pr,
                    b: right.pr,
                    paths,
                });
            }
            if git.is_ancestor(left_head, right_head)? {
                ancestry.push(AncestryInput {
                    before: left.pr,
                    after: right.pr,
                });
            } else if git.is_ancestor(right_head, left_head)? {
                ancestry.push(AncestryInput {
                    before: right.pr,
                    after: left.pr,
                });
            }
        }
    }
    Ok(GraphInput {
        repository: input.repository,
        nodes,
        conflicts,
        ancestry,
    })
}

enum GitLocation {
    WorkTree(PathBuf),
    Bare(PathBuf),
}

struct Git {
    location: GitLocation,
}

impl Git {
    fn open(path: &Path) -> Result<Self> {
        if !path.is_dir() {
            return Err(fail(format!(
                "Git directory does not exist: {}",
                path.display()
            )));
        }
        let location = if path.join(".git").exists() {
            GitLocation::WorkTree(path.to_owned())
        } else {
            GitLocation::Bare(path.to_owned())
        };
        let git = Self { location };
        git.expect_success(&[OsStr::new("rev-parse"), OsStr::new("--git-dir")])?;
        Ok(git)
    }

    fn command(&self) -> Command {
        let mut command = Command::new("git");
        match &self.location {
            GitLocation::WorkTree(path) => {
                command.arg("-C").arg(path);
            }
            GitLocation::Bare(path) => {
                command.arg("--git-dir").arg(path);
            }
        }
        command
    }

    fn execute<I, S>(&self, arguments: I) -> Result<Output>
    where
        I: IntoIterator<Item = S>,
        S: AsRef<OsStr>,
    {
        let arguments: Vec<OsString> = arguments
            .into_iter()
            .map(|argument| argument.as_ref().to_owned())
            .collect();
        self.command()
            .args(&arguments)
            .output()
            .map_err(|error| fail(format!("could not execute git {:?}: {error}", arguments)))
    }

    fn expect_success(&self, arguments: &[&OsStr]) -> Result<Output> {
        let output = self.execute(arguments.iter().copied())?;
        if output.status.success() {
            Ok(output)
        } else {
            Err(git_failure(arguments, &output))
        }
    }

    fn resolve(&self, revision: &GitRevision) -> Result<CommitId> {
        let commit = format!("{}^{{commit}}", revision.0);
        let output = self.expect_success(&[
            OsStr::new("rev-parse"),
            OsStr::new("--verify"),
            OsStr::new("--end-of-options"),
            OsStr::new(&commit),
        ])?;
        let stdout = String::from_utf8(output.stdout)
            .map_err(|_| fail("git rev-parse returned non-UTF-8 output"))?;
        CommitId::parse(stdout)
    }

    fn changed_files(&self, base: &CommitId, head: &CommitId) -> Result<Vec<String>> {
        let range = format!("{}...{}", base.0, head.0);
        let output = self.expect_success(&[
            OsStr::new("diff"),
            OsStr::new("--name-only"),
            OsStr::new("-z"),
            OsStr::new(&range),
            OsStr::new("--"),
        ])?;
        parse_nul_paths(&output.stdout, "git diff")
    }

    fn merge_conflicts(&self, left: &CommitId, right: &CommitId) -> Result<Vec<String>> {
        let arguments = [
            OsStr::new("merge-tree"),
            OsStr::new("--write-tree"),
            OsStr::new("--name-only"),
            OsStr::new("-z"),
            OsStr::new(&left.0),
            OsStr::new(&right.0),
        ];
        let output = self.execute(arguments)?;
        match output.status.code() {
            Some(0) => Ok(Vec::new()),
            Some(1) => parse_merge_tree_paths(&output.stdout),
            _ => Err(git_failure(&arguments, &output)),
        }
    }

    fn is_ancestor(&self, ancestor: &CommitId, descendant: &CommitId) -> Result<bool> {
        let arguments = [
            OsStr::new("merge-base"),
            OsStr::new("--is-ancestor"),
            OsStr::new(&ancestor.0),
            OsStr::new(&descendant.0),
        ];
        let output = self.execute(arguments)?;
        match output.status.code() {
            Some(0) => Ok(true),
            Some(1) => Ok(false),
            _ => Err(git_failure(&arguments, &output)),
        }
    }
}

fn git_failure(arguments: &[&OsStr], output: &Output) -> AppError {
    let stderr = String::from_utf8_lossy(&output.stderr);
    fail(format!(
        "git {:?} failed with {}: {}",
        arguments,
        output.status,
        stderr.trim()
    ))
}

fn parse_nul_paths(bytes: &[u8], operation: &str) -> Result<Vec<String>> {
    let mut paths = BTreeSet::new();
    for raw in bytes
        .split(|byte| *byte == 0)
        .filter(|part| !part.is_empty())
    {
        let path = std::str::from_utf8(raw)
            .map_err(|_| fail(format!("{operation} returned a non-UTF-8 path")))?;
        paths.insert(path.to_owned());
    }
    Ok(paths.into_iter().collect())
}

fn parse_merge_tree_paths(bytes: &[u8]) -> Result<Vec<String>> {
    let fields: Vec<&[u8]> = bytes.split(|byte| *byte == 0).collect();
    if fields.is_empty() {
        return Err(fail("conflicting git merge-tree returned no result"));
    }
    let mut paths = BTreeSet::new();
    for raw in fields.iter().skip(1).take_while(|field| !field.is_empty()) {
        let path = std::str::from_utf8(raw)
            .map_err(|_| fail("git merge-tree returned a non-UTF-8 conflict path"))?;
        paths.insert(path.to_owned());
    }
    if paths.is_empty() {
        Err(fail("git merge-tree reported a conflict without any paths"))
    } else {
        Ok(paths.into_iter().collect())
    }
}

fn build_plan(mut graph: GraphInput) -> Result<Plan> {
    graph.nodes.sort_by_key(|node| node.pr);
    let file_overlap_edges = file_overlap_edges(&graph.nodes);
    let ordering_edges = ordering_edges(&graph.nodes, graph.ancestry);
    let stacks = stacks(&graph.nodes, &ordering_edges);
    let suggested = landing_batches(&graph.nodes, &ordering_edges, &graph.conflicts);
    let suggested_rebase_plan = rebase_plan(&ordering_edges, &graph.conflicts, &suggested.batches);
    let held_prs = held_prs(&graph.nodes, &ordering_edges);
    let held_numbers: BTreeSet<_> = held_prs.iter().map(|held| held.pr).collect();
    let ready_nodes: Vec<_> = graph
        .nodes
        .iter()
        .filter(|node| !held_numbers.contains(&node.pr))
        .cloned()
        .collect();
    let ready = landing_batches(&ready_nodes, &ordering_edges, &graph.conflicts);
    let ready_now = ready.batches.first().cloned().unwrap_or_default();
    Ok(Plan {
        repository: graph.repository,
        nodes: graph.nodes,
        conflict_edges: graph.conflicts,
        file_overlap_edges,
        ordering_edges,
        stacks,
        suggested_landing_batches: suggested.batches,
        suggested_rebase_plan,
        ready_landing_batches: ready.batches,
        ready_now,
        held_prs,
        ordering_cycles: suggested.cycles,
    })
}

fn ordered_pair(left: PrNumber, right: PrNumber) -> (PrNumber, PrNumber) {
    if left < right {
        (left, right)
    } else {
        (right, left)
    }
}

fn file_overlap_edges(nodes: &[Node]) -> Vec<PathEdge> {
    let file_sets: Vec<BTreeSet<&str>> = nodes
        .iter()
        .map(|node| node.files.iter().map(String::as_str).collect())
        .collect();
    let mut edges = Vec::new();
    for left in 0..nodes.len() {
        for right in left + 1..nodes.len() {
            let paths: Vec<String> = file_sets[left]
                .intersection(&file_sets[right])
                .map(|path| (*path).to_owned())
                .collect();
            if !paths.is_empty() {
                edges.push(PathEdge {
                    a: nodes[left].pr,
                    b: nodes[right].pr,
                    paths,
                });
            }
        }
    }
    edges
}

fn ordering_edges(nodes: &[Node], ancestry: Vec<AncestryInput>) -> Vec<OrderingEdge> {
    let mut edges = BTreeMap::new();
    for child in nodes {
        for parent in nodes {
            if child.pr != parent.pr && child.base_ref == parent.head_ref {
                edges.insert(
                    (parent.pr, child.pr),
                    OrderingEdge {
                        before: parent.pr,
                        after: child.pr,
                        reason: OrderingReason::BaseRef,
                    },
                );
            }
        }
    }
    for edge in ancestry {
        edges
            .entry((edge.before, edge.after))
            .or_insert(OrderingEdge {
                before: edge.before,
                after: edge.after,
                reason: OrderingReason::Ancestry,
            });
    }
    edges.into_values().collect()
}

fn stacks(_nodes: &[Node], ordering: &[OrderingEdge]) -> Vec<Vec<PrNumber>> {
    let mut adjacency = BTreeMap::<PrNumber, BTreeSet<PrNumber>>::new();
    for edge in ordering {
        adjacency.entry(edge.before).or_default().insert(edge.after);
    }
    let reduced: Vec<_> = ordering
        .iter()
        .filter(|edge| !has_alternate_path(&adjacency, edge.before, edge.after))
        .collect();
    let mut children = BTreeMap::<PrNumber, BTreeSet<PrNumber>>::new();
    let mut parents = BTreeMap::<PrNumber, BTreeSet<PrNumber>>::new();
    let mut involved = BTreeSet::new();
    for edge in reduced {
        children.entry(edge.before).or_default().insert(edge.after);
        parents.entry(edge.after).or_default().insert(edge.before);
        involved.extend([edge.before, edge.after]);
    }
    let mut result = Vec::new();
    for root in involved
        .iter()
        .copied()
        .filter(|number| !parents.contains_key(number))
    {
        collect_stack_paths(root, &children, &mut vec![root], &mut result);
    }
    result
}

fn has_alternate_path(
    adjacency: &BTreeMap<PrNumber, BTreeSet<PrNumber>>,
    start: PrNumber,
    target: PrNumber,
) -> bool {
    let mut pending = vec![start];
    let mut seen = BTreeSet::new();
    while let Some(current) = pending.pop() {
        if !seen.insert(current) {
            continue;
        }
        if let Some(children) = adjacency.get(&current) {
            for child in children {
                if current == start && *child == target {
                    continue;
                }
                if *child == target {
                    return true;
                }
                pending.push(*child);
            }
        }
    }
    false
}

fn collect_stack_paths(
    node: PrNumber,
    children: &BTreeMap<PrNumber, BTreeSet<PrNumber>>,
    path: &mut Vec<PrNumber>,
    result: &mut Vec<Vec<PrNumber>>,
) {
    let descendants = children.get(&node).cloned().unwrap_or_default();
    if descendants.is_empty() {
        if path.len() > 1 {
            result.push(path.clone());
        }
        return;
    }
    for child in descendants {
        if !path.contains(&child) {
            path.push(child);
            collect_stack_paths(child, children, path, result);
            path.pop();
        }
    }
}

struct BatchPlan {
    batches: Vec<Vec<PrNumber>>,
    cycles: Vec<PrNumber>,
}

fn landing_batches(nodes: &[Node], ordering: &[OrderingEdge], conflicts: &[PathEdge]) -> BatchPlan {
    let numbers: BTreeSet<_> = nodes.iter().map(|node| node.pr).collect();
    let by_number: BTreeMap<_, _> = nodes.iter().map(|node| (node.pr, node)).collect();
    let conflict_pairs: BTreeSet<_> = conflicts
        .iter()
        .filter(|edge| numbers.contains(&edge.a) && numbers.contains(&edge.b))
        .map(|edge| ordered_pair(edge.a, edge.b))
        .collect();
    let mut remaining = numbers.clone();
    let mut placed = BTreeSet::new();
    let mut batches = Vec::new();
    let mut cycles = Vec::new();
    while !remaining.is_empty() {
        let mut ready: Vec<_> = remaining
            .iter()
            .copied()
            .filter(|candidate| {
                !ordering
                    .iter()
                    .filter(|edge| numbers.contains(&edge.before) && numbers.contains(&edge.after))
                    .any(|edge| edge.after == *candidate && !placed.contains(&edge.before))
            })
            .collect();
        if ready.is_empty() {
            cycles = remaining.iter().copied().collect();
            batches.extend(cycles.iter().copied().map(|number| vec![number]));
            break;
        }
        ready.sort_by(|left, right| {
            descendant_count(*right, &numbers, ordering)
                .cmp(&descendant_count(*left, &numbers, ordering))
                .then_with(|| {
                    conflict_count(*left, &remaining, &conflict_pairs).cmp(&conflict_count(
                        *right,
                        &remaining,
                        &conflict_pairs,
                    ))
                })
                .then_with(|| {
                    let left_size = by_number[left]
                        .additions
                        .saturating_add(by_number[left].deletions);
                    let right_size = by_number[right]
                        .additions
                        .saturating_add(by_number[right].deletions);
                    left_size.cmp(&right_size)
                })
                .then_with(|| by_number[left].created_at.cmp(&by_number[right].created_at))
                .then_with(|| left.cmp(right))
        });
        let mut batch = Vec::new();
        for candidate in ready {
            if batch
                .iter()
                .all(|selected| !conflict_pairs.contains(&ordered_pair(*selected, candidate)))
            {
                batch.push(candidate);
            }
        }
        for number in &batch {
            remaining.remove(number);
            placed.insert(*number);
        }
        batches.push(batch);
    }
    BatchPlan { batches, cycles }
}

fn descendant_count(
    number: PrNumber,
    numbers: &BTreeSet<PrNumber>,
    ordering: &[OrderingEdge],
) -> usize {
    let mut reachable = BTreeSet::new();
    let mut pending = vec![number];
    while let Some(current) = pending.pop() {
        for edge in ordering {
            if edge.before == current
                && numbers.contains(&edge.after)
                && reachable.insert(edge.after)
            {
                pending.push(edge.after);
            }
        }
    }
    reachable.len()
}

fn conflict_count(
    number: PrNumber,
    remaining: &BTreeSet<PrNumber>,
    conflicts: &BTreeSet<(PrNumber, PrNumber)>,
) -> usize {
    remaining
        .iter()
        .filter(|other| **other != number && conflicts.contains(&ordered_pair(number, **other)))
        .count()
}

fn held_prs(nodes: &[Node], ordering: &[OrderingEdge]) -> Vec<HeldPr> {
    let mut reasons = BTreeMap::<PrNumber, Vec<String>>::new();
    for node in nodes {
        let held = reasons.entry(node.pr).or_default();
        if node.draft {
            held.push("draft".to_owned());
        }
        if !node.base_conflict_paths.is_empty() {
            held.push("local-base-conflict".to_owned());
        }
        if node.mergeable == Mergeability::Conflicting {
            held.push("github-base-conflicting".to_owned());
        }
    }

    loop {
        let held_numbers: BTreeSet<_> = reasons
            .iter()
            .filter(|(_, reasons)| !reasons.is_empty())
            .map(|(number, _)| *number)
            .collect();
        let mut changed = false;
        for edge in ordering {
            if held_numbers.contains(&edge.before) && reasons[&edge.after].is_empty() {
                reasons.insert(
                    edge.after,
                    vec![format!("depends-on-held:#{}", edge.before)],
                );
                changed = true;
            }
        }
        if !changed {
            break;
        }
    }
    reasons
        .into_iter()
        .filter(|(_, reasons)| !reasons.is_empty())
        .map(|(pr, reasons)| HeldPr { pr, reasons })
        .collect()
}

fn rebase_plan(
    ordering: &[OrderingEdge],
    conflicts: &[PathEdge],
    batches: &[Vec<PrNumber>],
) -> Vec<RebaseStep> {
    let batch_of: BTreeMap<_, _> = batches
        .iter()
        .enumerate()
        .flat_map(|(batch, numbers)| numbers.iter().map(move |number| (*number, batch)))
        .collect();
    let mut steps = BTreeMap::<PrNumber, (BTreeSet<PrNumber>, BTreeSet<String>)>::new();
    for edge in ordering {
        if batch_of.get(&edge.before) < batch_of.get(&edge.after) {
            let step = steps.entry(edge.after).or_default();
            step.0.insert(edge.before);
            step.1.insert("stack-dependency".to_owned());
        }
    }
    for edge in conflicts {
        let (Some(a_batch), Some(b_batch)) = (batch_of.get(&edge.a), batch_of.get(&edge.b)) else {
            continue;
        };
        let (earlier, later) = match a_batch.cmp(b_batch) {
            std::cmp::Ordering::Less => (edge.a, edge.b),
            std::cmp::Ordering::Greater => (edge.b, edge.a),
            std::cmp::Ordering::Equal => continue,
        };
        let step = steps.entry(later).or_default();
        step.0.insert(earlier);
        step.1.insert("pair-conflict".to_owned());
    }
    let mut result: Vec<_> = steps
        .into_iter()
        .map(|(pr, (after, reasons))| RebaseStep {
            pr,
            after: after.into_iter().collect(),
            reasons: reasons.into_iter().collect(),
        })
        .collect();
    result.sort_by_key(|step| (batch_of[&step.pr], step.pr));
    result
}

fn render_human(plan: &Plan) -> String {
    let mut output = String::new();
    output.push_str(&format!("Repository: {}\n", plan.repository));
    output.push_str(&format!("Pull requests: {}\n", plan.nodes.len()));
    render_batches(
        &mut output,
        "Suggested landing batches",
        &plan.suggested_landing_batches,
    );
    render_batches(
        &mut output,
        "Ready landing batches",
        &plan.ready_landing_batches,
    );
    output.push_str("Ready now:");
    if plan.ready_now.is_empty() {
        output.push_str(" none\n");
    } else {
        for number in &plan.ready_now {
            output.push_str(&format!(" #{number}"));
        }
        output.push('\n');
    }
    output.push_str("Held pull requests:\n");
    if plan.held_prs.is_empty() {
        output.push_str("  none\n");
    } else {
        for held in &plan.held_prs {
            output.push_str(&format!("  #{}: {}\n", held.pr, held.reasons.join(", ")));
        }
    }
    output.push_str(&format!("Merge conflicts: {}\n", plan.conflict_edges.len()));
    output.push_str(&format!(
        "File overlaps: {}\n",
        plan.file_overlap_edges.len()
    ));
    output.push_str("Suggested rebase plan:\n");
    if plan.suggested_rebase_plan.is_empty() {
        output.push_str("  none\n");
    } else {
        for step in &plan.suggested_rebase_plan {
            let after = step
                .after
                .iter()
                .map(|number| format!("#{number}"))
                .collect::<Vec<_>>()
                .join(" ");
            output.push_str(&format!(
                "  #{} after {}: {}\n",
                step.pr,
                after,
                step.reasons.join(", ")
            ));
        }
    }
    output.push_str("Ordering cycles:\n");
    if plan.ordering_cycles.is_empty() {
        output.push_str("  none\n");
    } else {
        let members = plan
            .ordering_cycles
            .iter()
            .map(|number| format!("#{number}"))
            .collect::<Vec<_>>()
            .join(" -> ");
        output.push_str(&format!("  {members}\n"));
    }
    output
}

fn render_batches(output: &mut String, heading: &str, batches: &[Vec<PrNumber>]) {
    output.push_str(heading);
    output.push_str(":\n");
    if batches.is_empty() {
        output.push_str("  none\n");
    } else {
        for (index, batch) in batches.iter().enumerate() {
            let members = batch
                .iter()
                .map(|number| format!("#{number}"))
                .collect::<Vec<_>>()
                .join(" ");
            output.push_str(&format!("  {}: {members}\n", index + 1));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

    fn pure_json(prs: &str, conflicts: &str, ancestry: &str) -> String {
        format!(
            r#"{{
  "schema_version": 1,
  "repository": "acme/widgets",
  "prs": [{prs}],
  "conflict_edges": [{conflicts}],
  "ancestry_edges": [{ancestry}]
}}"#
        )
    }

    fn pr(number: u64, head: &str, base: &str) -> String {
        format!(
            r#"{{
  "number": {number}, "title": "PR {number}", "author": null,
  "head_ref": "{head}", "base_ref": "{base}", "draft": false,
  "mergeable": "MERGEABLE", "review_decision": "APPROVED",
  "created_at": "2025-01-01T00:00:00Z", "updated_at": "2025-01-02T00:00:00Z",
  "additions": 1, "deletions": 0, "files": ["src/shared.rs", "src/{number}.rs"],
  "base_conflict_paths": []
}}"#
        )
    }

    fn parse_pure(source: &str) -> Result<GraphInput> {
        normalize_pure(serde_json::from_str(source)?)
    }

    #[test]
    fn rejects_wrong_types_unknown_fields_and_zero_numbers() {
        let wrong_type = pure_json(
            &pr(1, "one", "main").replace("\"number\": 1", "\"number\": \"1\""),
            "",
            "",
        );
        assert!(serde_json::from_str::<PureInput>(&wrong_type).is_err());
        let unknown = pure_json(
            &pr(1, "one", "main").replace("\"title\":", "\"surprise\": true, \"title\":"),
            "",
            "",
        );
        assert!(serde_json::from_str::<PureInput>(&unknown).is_err());
        let zero = pure_json(&pr(0, "zero", "main"), "", "");
        assert!(serde_json::from_str::<PureInput>(&zero).is_err());
    }

    #[test]
    fn plans_empty_and_single_inputs() {
        let empty = build_plan(parse_pure(&pure_json("", "", "")).unwrap()).unwrap();
        assert!(empty.nodes.is_empty());
        assert!(empty.ready_now.is_empty());
        let single =
            build_plan(parse_pure(&pure_json(&pr(7, "feature", "main"), "", "")).unwrap()).unwrap();
        assert_eq!(single.ready_now, vec![PrNumber(7)]);
        assert_eq!(single.nodes[0].author, "unknown");
    }

    #[test]
    fn detects_stacks_cycles_conflicts_and_holds() {
        let first = pr(1, "parent", "child");
        let second = pr(2, "child", "parent").replace("\"draft\": false", "\"draft\": true");
        let source = pure_json(
            &format!("{first},{second}"),
            r#"{"a":2,"b":1,"paths":["src/shared.rs"]}"#,
            "",
        );
        let plan = build_plan(parse_pure(&source).unwrap()).unwrap();
        assert_eq!(plan.conflict_edges[0].a, PrNumber(1));
        assert_eq!(plan.ordering_cycles, vec![PrNumber(1), PrNumber(2)]);
        assert_eq!(
            plan.suggested_landing_batches,
            vec![vec![PrNumber(1)], vec![PrNumber(2)]]
        );
        assert!(plan.held_prs.iter().any(|held| {
            held.pr == PrNumber(2) && held.reasons.iter().any(|reason| reason == "draft")
        }));
        assert!(plan.held_prs.iter().any(|held| {
            held.pr == PrNumber(1)
                && held
                    .reasons
                    .iter()
                    .any(|reason| reason == "depends-on-held:#2")
        }));
        assert!(plan.ready_landing_batches.is_empty());
    }

    #[test]
    fn output_is_deterministic_and_human_output_is_stable() {
        let source = pure_json(
            &format!("{},{}", pr(2, "two", "main"), pr(1, "one", "main")),
            r#"{"a":2,"b":1,"paths":["z","a"]}"#,
            "",
        );
        let first = build_plan(parse_pure(&source).unwrap()).unwrap();
        let first_json = serde_json::to_string_pretty(&first).unwrap();
        let second_json =
            serde_json::to_string_pretty(&build_plan(parse_pure(&source).unwrap()).unwrap())
                .unwrap();
        assert_eq!(first_json, second_json);
        assert_eq!(
            serde_json::to_value(&first).unwrap(),
            serde_json::json!({
                "repository": "acme/widgets",
                "nodes": [
                    {
                        "pr": 1, "title": "PR 1", "author": "unknown",
                        "head_ref": "one", "base_ref": "main", "draft": false,
                        "mergeable": "MERGEABLE", "review_decision": "APPROVED",
                        "additions": 1, "deletions": 0, "files_count": 2,
                        "base_conflict_paths": []
                    },
                    {
                        "pr": 2, "title": "PR 2", "author": "unknown",
                        "head_ref": "two", "base_ref": "main", "draft": false,
                        "mergeable": "MERGEABLE", "review_decision": "APPROVED",
                        "additions": 1, "deletions": 0, "files_count": 2,
                        "base_conflict_paths": []
                    }
                ],
                "conflict_edges": [{"a": 1, "b": 2, "paths": ["a", "z"]}],
                "file_overlap_edges": [{"a": 1, "b": 2, "paths": ["src/shared.rs"]}],
                "ordering_edges": [],
                "stacks": [],
                "suggested_landing_batches": [[1], [2]],
                "suggested_rebase_plan": [
                    {"pr": 2, "after": [1], "reasons": ["pair-conflict"]}
                ],
                "ready_landing_batches": [[1], [2]],
                "ready_now": [1],
                "held_prs": [],
                "ordering_cycles": []
            })
        );
        assert_eq!(first.conflict_edges[0].paths, vec!["a", "z"]);
        assert_eq!(
            render_human(&first),
            "Repository: acme/widgets\nPull requests: 2\nSuggested landing batches:\n  1: #1\n  2: #2\nReady landing batches:\n  1: #1\n  2: #2\nReady now: #1\nHeld pull requests:\n  none\nMerge conflicts: 1\nFile overlaps: 1\nSuggested rebase plan:\n  #2 after #1: pair-conflict\nOrdering cycles:\n  none\n"
        );
    }

    struct TempRepo(PathBuf);

    impl TempRepo {
        fn new() -> Self {
            let serial = TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
            let path =
                std::env::temp_dir().join(format!("pr-plan-rust-{}-{serial}", std::process::id()));
            let _ = fs::remove_dir_all(&path);
            fs::create_dir_all(&path).unwrap();
            run_command(Command::new("git").arg("init").arg("-q").arg(&path));
            run_command(Command::new("git").arg("-C").arg(&path).args([
                "config",
                "user.name",
                "Test",
            ]));
            run_command(Command::new("git").arg("-C").arg(&path).args([
                "config",
                "user.email",
                "test@example.invalid",
            ]));
            Self(path)
        }

        fn git(&self, arguments: &[&str]) {
            run_command(Command::new("git").arg("-C").arg(&self.0).args(arguments));
        }

        fn write(&self, name: &str, contents: &str) {
            fs::write(self.0.join(name), contents).unwrap();
        }
    }

    impl Drop for TempRepo {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn run_command(command: &mut Command) {
        let output = command.output().unwrap();
        assert!(
            output.status.success(),
            "command failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    #[test]
    fn git_analysis_handles_expected_status_one_and_failures() {
        let repo = TempRepo::new();
        repo.write("shared.txt", "base\n");
        repo.git(&["add", "shared.txt"]);
        repo.git(&["commit", "-qm", "base"]);
        repo.git(&["branch", "base"]);
        repo.git(&["switch", "-qc", "left"]);
        repo.write("shared.txt", "left\n");
        repo.git(&["commit", "-qam", "left"]);
        repo.git(&["switch", "-qc", "right", "base"]);
        repo.write("shared.txt", "right\n");
        repo.git(&["commit", "-qam", "right"]);

        let git = Git::open(&repo.0).unwrap();
        let left = git.resolve(&GitRevision("left".into())).unwrap();
        let right = git.resolve(&GitRevision("right".into())).unwrap();
        assert_eq!(
            git.merge_conflicts(&left, &right).unwrap(),
            vec!["shared.txt"]
        );
        assert!(!git.is_ancestor(&left, &right).unwrap());
        assert!(git.resolve(&GitRevision("missing".into())).is_err());

        let input: GitInput = serde_json::from_str(
            r#"{
  "schema_version": 1,
  "repository": "acme/git-fixture",
  "prs": [
    {
      "number": 2, "title": "Right", "author": null,
      "head_ref": "right", "base_ref": "base", "draft": false,
      "mergeable": "MERGEABLE", "review_decision": "APPROVED",
      "created_at": "2025-01-02", "updated_at": "2025-01-02",
      "additions": 1, "deletions": 1, "git_head": "right", "git_base": "base"
    },
    {
      "number": 1, "title": "Left", "author": "alice",
      "head_ref": "left", "base_ref": "base", "draft": false,
      "mergeable": "MERGEABLE", "review_decision": "APPROVED",
      "created_at": "2025-01-01", "updated_at": "2025-01-01",
      "additions": 1, "deletions": 1, "git_head": "left", "git_base": "base"
    }
  ]
}"#,
        )
        .unwrap();
        let plan = build_plan(analyze_git(input, &repo.0).unwrap()).unwrap();
        assert_eq!(plan.conflict_edges.len(), 1);
        assert_eq!(plan.conflict_edges[0].paths, vec!["shared.txt"]);
        assert_eq!(plan.file_overlap_edges.len(), 1);
        assert_eq!(
            plan.suggested_landing_batches,
            vec![vec![PrNumber(1)], vec![PrNumber(2)]]
        );
    }

    #[test]
    fn unsafe_git_revision_is_rejected_before_execution() {
        assert!(GitRevision("--help".into()).validate("git_head").is_err());
        assert!(GitRevision("".into()).validate("git_head").is_err());
    }
}
