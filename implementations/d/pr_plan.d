module pr_plan;

import std.algorithm : all, canFind, count, each, filter, find, map, sort;
import std.array : Appender, appender, array;
import std.conv : ConvException, to;
import std.exception : enforce;
import std.file : readText;
import std.format : format;
import std.json : JSONException, JSONType, JSONValue, parseJSON;
import std.process : Config, Pid, environment, spawnProcess, wait;
import std.range : chunks;
import std.stdio : File, stdin, stderr, stdout;
import std.string : chomp, join, replace, split, strip;

enum Mergeability
{
    mergeable,
    conflicting,
    unknown,
}

enum ReviewDecision
{
    approved,
    changesRequested,
    reviewRequired,
    none,
}

struct PullRequest
{
    long number;
    string title;
    string author;
    bool hasAuthor;
    string headRef;
    string baseRef;
    bool draft;
    Mergeability mergeability;
    ReviewDecision reviewDecision;
    string createdAt;
    string updatedAt;
    long additions;
    long deletions;
    string[] files;
    string[] baseConflictPaths;
    string gitHead;
    string gitBase;
}

struct ConflictEdge
{
    long a;
    long b;
    string[] paths;
}

struct AncestryEdge
{
    long before;
    long after;
}

struct OrderingEdge
{
    long before;
    long after;
    string reason;
}

struct AnalysisInput
{
    string repository;
    PullRequest[] prs;
    ConflictEdge[] conflictEdges;
    AncestryEdge[] ancestryEdges;
}

struct HeldPullRequest
{
    long pr;
    string[] reasons;
}

struct RebaseEntry
{
    long pr;
    long[] after;
    string[] reasons;
}

struct Plan
{
    string repository;
    PullRequest[] nodes;
    ConflictEdge[] conflictEdges;
    ConflictEdge[] fileOverlapEdges;
    OrderingEdge[] orderingEdges;
    long[][] stacks;
    long[][] suggestedLandingBatches;
    RebaseEntry[] suggestedRebasePlan;
    long[][] readyLandingBatches;
    long[] readyNow;
    HeldPullRequest[] heldPrs;
    long[] orderingCycles;
}

final class InputException : Exception
{
    this(string message)
    {
        super(message);
    }
}

final class GitException : Exception
{
    this(string message)
    {
        super(message);
    }
}

private noreturn inputError(string path, string message)
{
    throw new InputException(path ~ ": " ~ message);
}

private JSONValue[string] objectValue(JSONValue value, string path)
{
    if (value.type != JSONType.object)
        inputError(path, "expected an object");
    return value.object;
}

private JSONValue[] arrayValue(JSONValue value, string path)
{
    if (value.type != JSONType.array)
        inputError(path, "expected an array");
    return value.array;
}

private JSONValue required(ref JSONValue[string] object, string key, string path)
{
    auto value = key in object;
    if (value is null)
        inputError(path, "missing required field " ~ key);
    return *value;
}

private void requireExactKeys(ref JSONValue[string] object, const string[] keys, string path)
{
    bool[string] expected;
    foreach (key; keys)
        expected[key] = true;
    foreach (key; object.byKey)
        if (key !in expected)
            inputError(path, "unexpected field " ~ key);
    foreach (key; keys)
        if (key !in object)
            inputError(path, "missing required field " ~ key);
}

private string stringValue(JSONValue value, string path, bool allowEmpty = false)
{
    if (value.type != JSONType.string)
        inputError(path, "expected a string");
    auto result = value.str;
    if (!allowEmpty && result.length == 0)
        inputError(path, "must not be empty");
    return result;
}

private long integerValue(JSONValue value, string path, long minimum = long.min)
{
    long result;
    if (value.type == JSONType.integer)
    {
        result = value.integer;
    }
    else if (value.type == JSONType.uinteger)
    {
        if (value.uinteger > long.max)
            inputError(path, "integer is out of range");
        result = cast(long) value.uinteger;
    }
    else
    {
        inputError(path, "expected an integer");
    }
    if (result < minimum)
        inputError(path, format("must be at least %s", minimum));
    return result;
}

private bool boolValue(JSONValue value, string path)
{
    if (value.type == JSONType.true_)
        return true;
    if (value.type == JSONType.false_)
        return false;
    inputError(path, "expected a boolean");
}

private int decimalAt(string value, size_t start, size_t count)
{
    int result;
    foreach (index; start .. start + count)
    {
        auto character = value[index];
        if (character < '0' || character > '9')
            return -1;
        result = result * 10 + character - '0';
    }
    return result;
}

private bool leapYear(int year)
{
    return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
}

private bool validTimestamp(string value)
{
    if (value.length < 20 || value[4] != '-' || value[7] != '-' ||
        value[10] != 'T' || value[13] != ':' || value[16] != ':')
        return false;

    auto year = decimalAt(value, 0, 4);
    auto month = decimalAt(value, 5, 2);
    auto day = decimalAt(value, 8, 2);
    auto hour = decimalAt(value, 11, 2);
    auto minute = decimalAt(value, 14, 2);
    auto second = decimalAt(value, 17, 2);
    if (year < 0 || month < 1 || month > 12 || hour < 0 || hour > 23 ||
        minute < 0 || minute > 59 || second < 0 || second > 60)
        return false;

    int[12] days = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    if (leapYear(year))
        days[1] = 29;
    if (day < 1 || day > days[month - 1])
        return false;

    size_t index = 19;
    if (index < value.length && value[index] == '.')
    {
        index++;
        auto fractionStart = index;
        while (index < value.length && value[index] >= '0' && value[index] <= '9')
            index++;
        if (index == fractionStart)
            return false;
    }
    if (index + 1 == value.length && value[index] == 'Z')
        return true;
    if (index + 6 != value.length || (value[index] != '+' && value[index] != '-') ||
        value[index + 3] != ':')
        return false;
    auto offsetHour = decimalAt(value, index + 1, 2);
    auto offsetMinute = decimalAt(value, index + 4, 2);
    return offsetHour >= 0 && offsetHour <= 23 &&
        offsetMinute >= 0 && offsetMinute <= 59;
}

private string timestampValue(JSONValue value, string path)
{
    auto result = stringValue(value, path);
    if (!validTimestamp(result))
        inputError(path, "expected an RFC 3339 timestamp");
    return result;
}

private string validateRevision(string value, string path)
{
    if (value.length == 0)
        inputError(path, "must not be empty");
    if (value[0] == '-')
        inputError(path, "revision must not start with '-'");
    foreach (character; value)
        if (character < 0x20 || character == 0x7f)
            inputError(path, "revision must not contain control characters");
    return value;
}

private string revisionValue(JSONValue value, string path)
{
    return validateRevision(stringValue(value, path), path);
}

private string[] stringArrayValue(JSONValue value, string path)
{
    auto values = arrayValue(value, path);
    string[] result;
    result.reserve(values.length);
    bool[string] seen;
    foreach (index, item; values)
    {
        auto decoded = stringValue(item, format("%s[%s]", path, index));
        if (decoded in seen)
            inputError(path, "paths must be unique");
        seen[decoded] = true;
        result ~= decoded;
    }
    sort(result);
    return result;
}

private Mergeability mergeabilityValue(JSONValue value, string path)
{
    switch (stringValue(value, path))
    {
    case "MERGEABLE":
        return Mergeability.mergeable;
    case "CONFLICTING":
        return Mergeability.conflicting;
    case "UNKNOWN":
        return Mergeability.unknown;
    default:
        inputError(path, "expected MERGEABLE, CONFLICTING, or UNKNOWN");
    }
}

private ReviewDecision reviewDecisionValue(JSONValue value, string path)
{
    switch (stringValue(value, path))
    {
    case "APPROVED":
        return ReviewDecision.approved;
    case "CHANGES_REQUESTED":
        return ReviewDecision.changesRequested;
    case "REVIEW_REQUIRED":
        return ReviewDecision.reviewRequired;
    case "NONE":
        return ReviewDecision.none;
    default:
        inputError(path, "expected APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED, or NONE");
    }
}

private PullRequest decodePullRequest(JSONValue value, size_t index, bool gitMode)
{
    auto path = format("$.prs[%s]", index);
    auto object = objectValue(value, path);
    auto commonKeys = [
        "number", "title", "author", "head_ref", "base_ref", "draft", "mergeable",
        "review_decision", "created_at", "updated_at", "additions", "deletions",
    ];
    auto pureKeys = commonKeys ~ ["files", "base_conflict_paths"];
    auto gitKeys = commonKeys ~ ["git_head", "git_base"];
    requireExactKeys(object, gitMode ? gitKeys : pureKeys, path);

    PullRequest pr;
    pr.number = integerValue(required(object, "number", path), path ~ ".number", 1);
    pr.title = stringValue(required(object, "title", path), path ~ ".title");
    auto author = required(object, "author", path);
    if (author.type == JSONType.null_)
    {
        pr.hasAuthor = false;
    }
    else
    {
        pr.author = stringValue(author, path ~ ".author");
        pr.hasAuthor = true;
    }
    pr.headRef = stringValue(required(object, "head_ref", path), path ~ ".head_ref");
    pr.baseRef = stringValue(required(object, "base_ref", path), path ~ ".base_ref");
    pr.draft = boolValue(required(object, "draft", path), path ~ ".draft");
    pr.mergeability = mergeabilityValue(required(object, "mergeable", path), path ~ ".mergeable");
    pr.reviewDecision = reviewDecisionValue(required(object, "review_decision", path), path ~ ".review_decision");
    pr.createdAt = timestampValue(required(object, "created_at", path), path ~ ".created_at");
    pr.updatedAt = timestampValue(required(object, "updated_at", path), path ~ ".updated_at");
    pr.additions = integerValue(required(object, "additions", path), path ~ ".additions", 0);
    pr.deletions = integerValue(required(object, "deletions", path), path ~ ".deletions", 0);
    if (gitMode)
    {
        pr.gitHead = revisionValue(required(object, "git_head", path), path ~ ".git_head");
        pr.gitBase = revisionValue(required(object, "git_base", path), path ~ ".git_base");
    }
    else
    {
        pr.files = stringArrayValue(required(object, "files", path), path ~ ".files");
        pr.baseConflictPaths = stringArrayValue(required(object, "base_conflict_paths", path), path ~ ".base_conflict_paths");
    }
    return pr;
}

private ConflictEdge decodeConflictEdge(JSONValue value, size_t index)
{
    auto path = format("$.conflict_edges[%s]", index);
    auto object = objectValue(value, path);
    requireExactKeys(object, ["a", "b", "paths"], path);
    auto edge = ConflictEdge(
        integerValue(required(object, "a", path), path ~ ".a", 1),
        integerValue(required(object, "b", path), path ~ ".b", 1),
        stringArrayValue(required(object, "paths", path), path ~ ".paths"),
    );
    if (edge.a == edge.b)
        inputError(path, "self edges are not allowed");
    if (edge.paths.length == 0)
        inputError(path ~ ".paths", "must contain at least one path");
    return edge;
}

private AncestryEdge decodeAncestryEdge(JSONValue value, size_t index)
{
    auto path = format("$.ancestry_edges[%s]", index);
    auto object = objectValue(value, path);
    requireExactKeys(object, ["before", "after"], path);
    auto edge = AncestryEdge(
        integerValue(required(object, "before", path), path ~ ".before", 1),
        integerValue(required(object, "after", path), path ~ ".after", 1),
    );
    if (edge.before == edge.after)
        inputError(path, "self edges are not allowed");
    return edge;
}

private AnalysisInput decodeDocument(JSONValue document, bool gitMode)
{
    auto root = objectValue(document, "$");
    immutable pureKeys = ["schema_version", "repository", "prs", "conflict_edges", "ancestry_edges"];
    immutable gitKeys = ["schema_version", "repository", "prs"];
    requireExactKeys(root, gitMode ? gitKeys : pureKeys, "$");
    if (integerValue(required(root, "schema_version", "$"), "$.schema_version") != 1)
        inputError("$.schema_version", "unsupported schema version");

    AnalysisInput result;
    result.repository = stringValue(required(root, "repository", "$"), "$.repository");
    auto prs = arrayValue(required(root, "prs", "$"), "$.prs");
    result.prs.reserve(prs.length);
    bool[long] numbers;
    foreach (index, item; prs)
    {
        auto pr = decodePullRequest(item, index, gitMode);
        if (pr.number in numbers)
            inputError(format("$.prs[%s].number", index), "duplicate PR number");
        numbers[pr.number] = true;
        result.prs ~= pr;
    }

    if (!gitMode)
    {
        auto conflicts = arrayValue(required(root, "conflict_edges", "$"), "$.conflict_edges");
        bool[string] conflictPairs;
        foreach (index, item; conflicts)
        {
            auto edge = decodeConflictEdge(item, index);
            if (edge.a !in numbers || edge.b !in numbers)
                inputError(format("$.conflict_edges[%s]", index), "references an unknown PR");
            auto key = edge.a < edge.b ? format("%s:%s", edge.a, edge.b) : format("%s:%s", edge.b, edge.a);
            if (key in conflictPairs)
                inputError(format("$.conflict_edges[%s]", index), "duplicate conflict edge");
            conflictPairs[key] = true;
            result.conflictEdges ~= edge;
        }

        auto ancestry = arrayValue(required(root, "ancestry_edges", "$"), "$.ancestry_edges");
        bool[string] ancestryPairs;
        foreach (index, item; ancestry)
        {
            auto edge = decodeAncestryEdge(item, index);
            if (edge.before !in numbers || edge.after !in numbers)
                inputError(format("$.ancestry_edges[%s]", index), "references an unknown PR");
            auto key = format("%s:%s", edge.before, edge.after);
            if (key in ancestryPairs)
                inputError(format("$.ancestry_edges[%s]", index), "duplicate ancestry edge");
            ancestryPairs[key] = true;
            result.ancestryEdges ~= edge;
        }
    }
    return result;
}

AnalysisInput parseInput(string contents, bool gitMode)
{
    try
    {
        return decodeDocument(parseJSON(contents), gitMode);
    }
    catch (InputException error)
    {
        throw error;
    }
    catch (JSONException error)
    {
        throw new InputException("invalid JSON: " ~ error.msg);
    }
    catch (ConvException error)
    {
        throw new InputException("invalid input: " ~ error.msg);
    }
}

private string[] sortedUnique(const string[] values)
{
    bool[string] seen;
    string[] result;
    foreach (value; values)
        if (value !in seen)
        {
            seen[value] = true;
            result ~= value;
        }
    sort(result);
    return result;
}

private long[] sortedNumbers(ref bool[long] values)
{
    long[] result;
    result.reserve(values.length);
    foreach (value; values.byKey)
        result ~= value;
    sort(result);
    return result;
}

private string readHandle(ref File file)
{
    file.seek(0);
    auto output = appender!string;
    ubyte[4096] buffer;
    while (!file.eof)
    {
        auto bytes = file.rawRead(buffer[]);
        if (bytes.length == 0)
            break;
        output.put(cast(char[]) bytes);
    }
    return output.data;
}

struct CommandResult
{
    int status;
    string output;
    string error;
}

private string[string] gitEnvironment()
{
    auto result = environment.toAA();
    foreach (name; [
        "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_COMMON_DIR",
        "GIT_CONFIG_COUNT",
        "GIT_CONFIG_PARAMETERS",
        "GIT_DIR",
        "GIT_INDEX_FILE",
        "GIT_OBJECT_DIRECTORY",
        "GIT_WORK_TREE",
    ])
        result.remove(name);
    result["GIT_CONFIG_NOSYSTEM"] = "1";
    result["GIT_CONFIG_GLOBAL"] = "/dev/null";
    result["GIT_OPTIONAL_LOCKS"] = "0";
    result["GIT_TERMINAL_PROMPT"] = "0";
    result["LC_ALL"] = "C";
    return result;
}

CommandResult runGit(string repository, const string[] arguments, const int[] allowedStatuses = [0])
{
    string[] command = ["git", "-C", repository] ~ arguments;
    auto outputFile = File.tmpfile();
    auto errorFile = File.tmpfile();
    scope (exit)
    {
        outputFile.close();
        errorFile.close();
    }

    int status;
    try
    {
        auto config = Config.retainStdout | Config.retainStderr | Config.newEnv;
        Pid child = spawnProcess(command, stdin, outputFile, errorFile, gitEnvironment(), config);
        status = wait(child);
    }
    catch (Exception error)
    {
        throw new GitException("could not start git: " ~ error.msg);
    }
    auto output = readHandle(outputFile);
    auto error = readHandle(errorFile);
    if (!allowedStatuses.canFind(status))
    {
        auto detail = error.strip.length ? error.strip : output.strip;
        throw new GitException(format(
            "git command failed with status %s: git %-(%s %)\n%s",
            status,
            arguments,
            detail,
        ).strip);
    }
    return CommandResult(status, output, error);
}

private string gitObjectId(string value)
{
    value = value.strip;
    if (value.length != 40 && value.length != 64)
        throw new GitException("git returned an invalid object ID: " ~ value);
    foreach (character; value)
        if (!(character >= '0' && character <= '9') && !(character >= 'a' && character <= 'f'))
            throw new GitException("git returned an invalid object ID: " ~ value);
    return value;
}

private string[] nonemptyLines(string output)
{
    string[] result;
    foreach (line; output.split("\n"))
    {
        line = line.chomp("\r");
        if (line.length)
            result ~= line;
    }
    return result;
}

private string[] mergeTreePaths(string repository, string left, string right)
{
    // A conflict is the one expected nonzero status for this Git probe.
    auto result = runGit(
        repository,
        ["merge-tree", "--write-tree", "--name-only", "--messages", left, right],
        [0, 1],
    );
    if (result.status == 0)
        return [];
    auto lines = result.output.split("\n");
    string[] paths;
    foreach (line; lines[1 .. $])
    {
        auto path = line.chomp("\r");
        if (path.length == 0)
            break;
        paths ~= path;
    }
    return sortedUnique(paths);
}

private bool isAncestor(string repository, string before, string after)
{
    return runGit(repository, ["merge-base", "--is-ancestor", before, after], [0, 1]).status == 0;
}

AnalysisInput analyzeRepository(AnalysisInput input, string repository)
{
    foreach (index, ref pr; input.prs)
    {
        validateRevision(pr.gitHead, format("$.prs[%s].git_head", index));
        validateRevision(pr.gitBase, format("$.prs[%s].git_base", index));
    }
    runGit(repository, ["rev-parse", "--git-dir"]);

    AnalysisInput result;
    result.repository = input.repository;
    string[long] revisions;
    foreach (raw; input.prs)
    {
        auto pr = raw;
        auto head = gitObjectId(runGit(repository,
            ["rev-parse", "--verify", "--end-of-options", pr.gitHead ~ "^{commit}"]).output);
        auto base = gitObjectId(runGit(repository,
            ["rev-parse", "--verify", "--end-of-options", pr.gitBase ~ "^{commit}"]).output);
        auto mergeBase = gitObjectId(runGit(repository, ["merge-base", base, head]).output);
        auto paths = runGit(repository, ["diff", "--name-only", "-z", mergeBase ~ "..." ~ head]).output;
        pr.files = paths.split('\0').filter!(path => path.length != 0).array;
        pr.files = sortedUnique(pr.files);
        pr.baseConflictPaths = mergeTreePaths(repository, base, head);
        pr.gitHead = null;
        pr.gitBase = null;
        result.prs ~= pr;
        revisions[pr.number] = head;
    }

    foreach (leftIndex, ref left; result.prs)
        foreach (ref right; result.prs[leftIndex + 1 .. $])
        {
            auto leftHead = revisions[left.number];
            auto rightHead = revisions[right.number];
            auto paths = mergeTreePaths(repository, leftHead, rightHead);
            if (paths.length)
                result.conflictEdges ~= ConflictEdge(left.number, right.number, paths);
            if (leftHead != rightHead && isAncestor(repository, leftHead, rightHead))
                result.ancestryEdges ~= AncestryEdge(left.number, right.number);
            else if (leftHead != rightHead && isAncestor(repository, rightHead, leftHead))
                result.ancestryEdges ~= AncestryEdge(right.number, left.number);
        }
    return result;
}

private string mergeabilityName(Mergeability value)
{
    final switch (value)
    {
    case Mergeability.mergeable:
        return "MERGEABLE";
    case Mergeability.conflicting:
        return "CONFLICTING";
    case Mergeability.unknown:
        return "UNKNOWN";
    }
}

private string reviewDecisionName(ReviewDecision value)
{
    final switch (value)
    {
    case ReviewDecision.approved:
        return "APPROVED";
    case ReviewDecision.changesRequested:
        return "CHANGES_REQUESTED";
    case ReviewDecision.reviewRequired:
        return "REVIEW_REQUIRED";
    case ReviewDecision.none:
        return "NONE";
    }
}

private bool hasPath(ref bool[long][long] adjacency, long start, long target, long skipBefore, long skipAfter)
{
    long[] pending = [start];
    bool[long] seen;
    while (pending.length)
    {
        auto current = pending[$ - 1];
        pending.length--;
        if (current in seen)
            continue;
        seen[current] = true;
        auto children = current in adjacency;
        if (children is null)
            continue;
        foreach (child; (*children).byKey)
        {
            if (current == skipBefore && child == skipAfter)
                continue;
            if (child == target)
                return true;
            pending ~= child;
        }
    }
    return false;
}

private long[][] buildStacks(OrderingEdge[] edges)
{
    bool[long][long] adjacency;
    foreach (edge; edges)
        adjacency[edge.before][edge.after] = true;
    OrderingEdge[] reduced;
    foreach (edge; edges)
        if (!hasPath(adjacency, edge.before, edge.after, edge.before, edge.after))
            reduced ~= edge;

    bool[long][long] children;
    bool[long][long] parents;
    bool[long] involved;
    foreach (edge; reduced)
    {
        children[edge.before][edge.after] = true;
        parents[edge.after][edge.before] = true;
        involved[edge.before] = true;
        involved[edge.after] = true;
    }

    long[][] stacks;
    void visit(long node, long[] path)
    {
        bool[long] empty;
        auto childSet = node in children;
        auto descendants = childSet is null ? sortedNumbers(empty) : sortedNumbers(*childSet);
        if (descendants.length == 0)
        {
            if (path.length > 1)
                stacks ~= path;
            return;
        }
        foreach (child; descendants)
            if (!path.canFind(child))
                visit(child, path ~ child);
    }

    foreach (root; sortedNumbers(involved))
    {
        auto parentSet = root in parents;
        if (parentSet is null || parentSet.length == 0)
            visit(root, [root]);
    }
    return stacks;
}

private struct BatchResult
{
    long[][] batches;
    long[] cycles;
}

private BatchResult landingBatches(PullRequest[] prs, OrderingEdge[] ordering, ConflictEdge[] conflictEdges)
{
    bool[long] remaining;
    PullRequest[long] byNumber;
    bool[long][long] conflicts;
    bool[long][long] predecessors;
    bool[long][long] children;
    foreach (pr; prs)
    {
        remaining[pr.number] = true;
        byNumber[pr.number] = pr;
        conflicts[pr.number] = null;
        predecessors[pr.number] = null;
        children[pr.number] = null;
    }
    foreach (edge; conflictEdges)
        if (edge.a in remaining && edge.b in remaining)
        {
            conflicts[edge.a][edge.b] = true;
            conflicts[edge.b][edge.a] = true;
        }
    foreach (edge; ordering)
        if (edge.before in remaining && edge.after in remaining)
        {
            predecessors[edge.after][edge.before] = true;
            children[edge.before][edge.after] = true;
        }

    size_t[long] descendantCache;
    size_t descendantCount(long number)
    {
        auto cached = number in descendantCache;
        if (cached !is null)
            return *cached;
        bool[long] reachable;
        auto pending = sortedNumbers(children[number]);
        while (pending.length)
        {
            auto child = pending[$ - 1];
            pending.length--;
            if (child !in reachable)
            {
                reachable[child] = true;
                pending ~= sortedNumbers(children[child]);
            }
        }
        descendantCache[number] = reachable.length;
        return reachable.length;
    }

    bool[long] placed;
    long[][] batches;
    long[] cycles;
    while (remaining.length)
    {
        long[] available;
        foreach (number; remaining.byKey)
        {
            bool ready = true;
            foreach (predecessor; predecessors[number].byKey)
                if (predecessor !in placed)
                {
                    ready = false;
                    break;
                }
            if (ready)
                available ~= number;
        }
        if (available.length == 0)
        {
            cycles = sortedNumbers(remaining);
            foreach (number; cycles)
                batches ~= [number];
            break;
        }
        sort!((left, right) {
            auto leftDescendants = descendantCount(left);
            auto rightDescendants = descendantCount(right);
            if (leftDescendants != rightDescendants)
                return leftDescendants > rightDescendants;
            auto leftConflicts = conflicts[left].byKey.count!(peer => peer in remaining);
            auto rightConflicts = conflicts[right].byKey.count!(peer => peer in remaining);
            if (leftConflicts != rightConflicts)
                return leftConflicts < rightConflicts;
            auto leftSize = byNumber[left].additions + byNumber[left].deletions;
            auto rightSize = byNumber[right].additions + byNumber[right].deletions;
            if (leftSize != rightSize)
                return leftSize < rightSize;
            if (byNumber[left].createdAt != byNumber[right].createdAt)
                return byNumber[left].createdAt < byNumber[right].createdAt;
            return left < right;
        })(available);

        long[] batch;
        foreach (candidate; available)
        {
            bool compatible = true;
            foreach (selected; batch)
                if (selected in conflicts[candidate])
                {
                    compatible = false;
                    break;
                }
            if (compatible)
                batch ~= candidate;
        }
        batches ~= batch;
        foreach (number; batch)
        {
            remaining.remove(number);
            placed[number] = true;
        }
    }
    return BatchResult(batches, cycles);
}

private RebaseEntry[] rebasePlan(long[][] batches, OrderingEdge[] ordering, ConflictEdge[] conflicts)
{
    size_t[long] batchOf;
    foreach (index, batch; batches)
        foreach (number; batch)
            batchOf[number] = index;
    bool[long][long] after;
    bool[string][long] reasons;
    void add(long pr, long predecessor, string reason)
    {
        after[pr][predecessor] = true;
        reasons[pr][reason] = true;
    }
    foreach (edge; ordering)
        if (edge.before in batchOf && edge.after in batchOf && batchOf[edge.before] < batchOf[edge.after])
            add(edge.after, edge.before, "stack-dependency");
    foreach (edge; conflicts)
    {
        if (edge.a !in batchOf || edge.b !in batchOf || batchOf[edge.a] == batchOf[edge.b])
            continue;
        if (batchOf[edge.a] < batchOf[edge.b])
            add(edge.b, edge.a, "pair-conflict");
        else
            add(edge.a, edge.b, "pair-conflict");
    }
    long[] numbers;
    foreach (number; after.byKey)
        numbers ~= number;
    sort!((left, right) => batchOf[left] != batchOf[right]
        ? batchOf[left] < batchOf[right]
        : left < right)(numbers);
    RebaseEntry[] result;
    foreach (number; numbers)
    {
        string[] entryReasons;
        if ("pair-conflict" in reasons[number])
            entryReasons ~= "pair-conflict";
        if ("stack-dependency" in reasons[number])
            entryReasons ~= "stack-dependency";
        result ~= RebaseEntry(number, sortedNumbers(after[number]), entryReasons);
    }
    return result;
}

Plan buildPlan(AnalysisInput input)
{
    sort!((left, right) => left.number < right.number)(input.prs);
    foreach (ref edge; input.conflictEdges)
        edge.paths = sortedUnique(edge.paths);
    sort!((left, right) => left.a != right.a ? left.a < right.a : left.b < right.b)(input.conflictEdges);

    ConflictEdge[] overlaps;
    foreach (leftIndex, ref left; input.prs)
        foreach (ref right; input.prs[leftIndex + 1 .. $])
        {
            bool[string] leftFiles;
            foreach (path; left.files)
                leftFiles[path] = true;
            string[] paths;
            foreach (path; right.files)
                if (path in leftFiles)
                    paths ~= path;
            paths = sortedUnique(paths);
            if (paths.length)
                overlaps ~= ConflictEdge(left.number, right.number, paths);
        }

    PullRequest[string] byHead;
    foreach (pr; input.prs)
        byHead[pr.headRef] = pr;
    OrderingEdge[string] orderingByPair;
    foreach (pr; input.prs)
    {
        auto predecessor = pr.baseRef in byHead;
        if (predecessor !is null && predecessor.number != pr.number)
        {
            auto edge = OrderingEdge(predecessor.number, pr.number, "base-ref");
            orderingByPair[format("%s:%s", edge.before, edge.after)] = edge;
        }
    }
    foreach (ancestry; input.ancestryEdges)
    {
        auto key = format("%s:%s", ancestry.before, ancestry.after);
        if (key !in orderingByPair)
            orderingByPair[key] = OrderingEdge(ancestry.before, ancestry.after, "ancestry");
    }
    OrderingEdge[] ordering;
    foreach (edge; orderingByPair.byValue)
        ordering ~= edge;
    sort!((left, right) => left.before != right.before
        ? left.before < right.before
        : left.after < right.after)(ordering);

    auto eventual = landingBatches(input.prs, ordering, input.conflictEdges);
    bool[long] heldNumbers;
    string[][long] heldReasons;
    foreach (pr; input.prs)
    {
        string[] reasons;
        if (pr.draft)
            reasons ~= "draft";
        if (pr.baseConflictPaths.length)
            reasons ~= "local-base-conflict";
        if (pr.mergeability == Mergeability.conflicting)
            reasons ~= "github-base-conflicting";
        if (reasons.length)
        {
            heldNumbers[pr.number] = true;
            heldReasons[pr.number] = reasons;
        }
    }
    bool changed = true;
    while (changed)
    {
        changed = false;
        foreach (edge; ordering)
            if (edge.before in heldNumbers && edge.after !in heldNumbers)
            {
                heldNumbers[edge.after] = true;
                heldReasons[edge.after] = [format("depends-on-held:#%s", edge.before)];
                changed = true;
            }
    }

    PullRequest[] eligible;
    foreach (pr; input.prs)
        if (pr.number !in heldNumbers)
            eligible ~= pr;
    bool[long] eligibleNumbers;
    foreach (pr; eligible)
        eligibleNumbers[pr.number] = true;
    auto readyConflicts = input.conflictEdges
        .filter!(edge => edge.a in eligibleNumbers && edge.b in eligibleNumbers).array;
    auto readyOrdering = ordering
        .filter!(edge => edge.before in eligibleNumbers && edge.after in eligibleNumbers).array;
    auto ready = landingBatches(eligible, readyOrdering, readyConflicts);

    HeldPullRequest[] held;
    foreach (number; sortedNumbers(heldNumbers))
        held ~= HeldPullRequest(number, heldReasons[number]);
    return Plan(
        input.repository,
        input.prs,
        input.conflictEdges,
        overlaps,
        ordering,
        buildStacks(ordering),
        eventual.batches,
        rebasePlan(eventual.batches, ordering, input.conflictEdges),
        ready.batches,
        ready.batches.length ? ready.batches[0] : [],
        held,
        eventual.cycles,
    );
}

private string quoted(string value)
{
    return JSONValue(value).toString();
}

private string jsonStrings(const string[] values)
{
    return "[" ~ values.map!(value => quoted(value)).join(", ") ~ "]";
}

private string jsonNumbers(const long[] values)
{
    return "[" ~ values.map!(value => value.to!string).join(", ") ~ "]";
}

private void startArray(ref Appender!string output, string key)
{
    output.put("  \"" ~ key ~ "\": [\n");
}

private void endArray(ref Appender!string output, bool comma = true)
{
    output.put(comma ? "  ],\n" : "  ]\n");
}

private void writeConflictEdges(ref Appender!string output, string key, const ConflictEdge[] edges)
{
    startArray(output, key);
    foreach (index, edge; edges)
    {
        output.put("    {\n");
        output.put(format("      \"a\": %s,\n", edge.a));
        output.put(format("      \"b\": %s,\n", edge.b));
        output.put("      \"paths\": " ~ jsonStrings(edge.paths) ~ "\n");
        output.put(index + 1 == edges.length ? "    }\n" : "    },\n");
    }
    endArray(output);
}

private void writeNumberBatches(ref Appender!string output, string key, const long[][] batches)
{
    startArray(output, key);
    foreach (index, batch; batches)
        output.put("    " ~ jsonNumbers(batch) ~ (index + 1 == batches.length ? "\n" : ",\n"));
    endArray(output);
}

string renderJson(const Plan plan)
{
    auto output = appender!string;
    output.put("{\n");
    output.put("  \"repository\": " ~ quoted(plan.repository) ~ ",\n");
    startArray(output, "nodes");
    foreach (index, pr; plan.nodes)
    {
        output.put("    {\n");
        output.put(format("      \"pr\": %s,\n", pr.number));
        output.put("      \"title\": " ~ quoted(pr.title) ~ ",\n");
        output.put("      \"author\": " ~ quoted(pr.hasAuthor ? pr.author : "unknown") ~ ",\n");
        output.put("      \"head_ref\": " ~ quoted(pr.headRef) ~ ",\n");
        output.put("      \"base_ref\": " ~ quoted(pr.baseRef) ~ ",\n");
        output.put("      \"draft\": " ~ (pr.draft ? "true" : "false") ~ ",\n");
        output.put("      \"mergeable\": " ~ quoted(mergeabilityName(pr.mergeability)) ~ ",\n");
        output.put("      \"review_decision\": " ~ quoted(reviewDecisionName(pr.reviewDecision)) ~ ",\n");
        output.put(format("      \"additions\": %s,\n", pr.additions));
        output.put(format("      \"deletions\": %s,\n", pr.deletions));
        output.put(format("      \"files_count\": %s,\n", sortedUnique(pr.files).length));
        output.put("      \"base_conflict_paths\": " ~ jsonStrings(sortedUnique(pr.baseConflictPaths)) ~ "\n");
        output.put(index + 1 == plan.nodes.length ? "    }\n" : "    },\n");
    }
    endArray(output);
    writeConflictEdges(output, "conflict_edges", plan.conflictEdges);
    writeConflictEdges(output, "file_overlap_edges", plan.fileOverlapEdges);
    startArray(output, "ordering_edges");
    foreach (index, edge; plan.orderingEdges)
    {
        output.put("    {\n");
        output.put(format("      \"before\": %s,\n", edge.before));
        output.put(format("      \"after\": %s,\n", edge.after));
        output.put("      \"reason\": " ~ quoted(edge.reason) ~ "\n");
        output.put(index + 1 == plan.orderingEdges.length ? "    }\n" : "    },\n");
    }
    endArray(output);
    writeNumberBatches(output, "stacks", plan.stacks);
    writeNumberBatches(output, "suggested_landing_batches", plan.suggestedLandingBatches);
    startArray(output, "suggested_rebase_plan");
    foreach (index, entry; plan.suggestedRebasePlan)
    {
        output.put("    {\n");
        output.put(format("      \"pr\": %s,\n", entry.pr));
        output.put("      \"after\": " ~ jsonNumbers(entry.after) ~ ",\n");
        output.put("      \"reasons\": " ~ jsonStrings(entry.reasons) ~ "\n");
        output.put(index + 1 == plan.suggestedRebasePlan.length ? "    }\n" : "    },\n");
    }
    endArray(output);
    writeNumberBatches(output, "ready_landing_batches", plan.readyLandingBatches);
    output.put("  \"ready_now\": " ~ jsonNumbers(plan.readyNow) ~ ",\n");
    startArray(output, "held_prs");
    foreach (index, entry; plan.heldPrs)
    {
        output.put("    {\n");
        output.put(format("      \"pr\": %s,\n", entry.pr));
        output.put("      \"reasons\": " ~ jsonStrings(entry.reasons) ~ "\n");
        output.put(index + 1 == plan.heldPrs.length ? "    }\n" : "    },\n");
    }
    endArray(output);
    output.put("  \"ordering_cycles\": " ~ jsonNumbers(plan.orderingCycles) ~ "\n");
    output.put("}\n");
    return output.data;
}

string renderHuman(const Plan plan)
{
    auto ready = plan.readyNow.map!(number => "#" ~ number.to!string).join(", ");
    return format(
        "%s: %s PRs, %s conflicts, ready %s\n",
        plan.repository,
        plan.nodes.length,
        plan.conflictEdges.length,
        ready,
    );
}

private enum usageText =
    "Usage:\n" ~
    "  pr-plan pure --input FILE [--human]\n" ~
    "  pr-plan git --input FILE --git-dir DIR [--human]\n\n" ~
    "Build deterministic pull-request conflict and landing plans.\n";

private struct Options
{
    string mode;
    string input;
    string gitDir;
    bool human;
}

private Options parseOptions(string[] arguments)
{
    if (arguments.length == 0)
        throw new InputException("missing mode");
    Options options;
    options.mode = arguments[0];
    if (options.mode != "pure" && options.mode != "git")
        throw new InputException("unknown mode " ~ quoted(options.mode));
    size_t index = 1;
    while (index < arguments.length)
    {
        auto argument = arguments[index++];
        if (argument == "--human")
        {
            if (options.human)
                throw new InputException("--human may only be specified once");
            options.human = true;
        }
        else if (argument == "--input" || argument == "--git-dir")
        {
            if (index >= arguments.length)
                throw new InputException(argument ~ " requires a value");
            auto value = arguments[index++];
            if (value.length == 0)
                throw new InputException(argument ~ " requires a nonempty value");
            if (argument == "--input")
            {
                if (options.input.length)
                    throw new InputException("--input may only be specified once");
                options.input = value;
            }
            else
            {
                if (options.gitDir.length)
                    throw new InputException("--git-dir may only be specified once");
                options.gitDir = value;
            }
        }
        else
            throw new InputException("unexpected argument " ~ quoted(argument));
    }
    if (options.input.length == 0)
        throw new InputException("--input is required");
    if (options.mode == "git" && options.gitDir.length == 0)
        throw new InputException("--git-dir is required in git mode");
    if (options.mode == "pure" && options.gitDir.length)
        throw new InputException("--git-dir is only valid in git mode");
    return options;
}

int run(string[] arguments)
{
    if (arguments.length && (arguments[0] == "--help" || arguments[0] == "-h"))
    {
        stdout.write(usageText);
        return 0;
    }
    Options options;
    try
    {
        options = parseOptions(arguments);
    }
    catch (InputException error)
    {
        stderr.writefln("pr-plan: error: %s", error.msg);
        stderr.write(usageText);
        return 2;
    }
    try
    {
        auto input = parseInput(readText(options.input), options.mode == "git");
        if (options.mode == "git")
            input = analyzeRepository(input, options.gitDir);
        auto plan = buildPlan(input);
        stdout.write(options.human ? renderHuman(plan) : renderJson(plan));
        return 0;
    }
    catch (InputException error)
    {
        stderr.writefln("pr-plan: input error: %s", error.msg);
        return 2;
    }
    catch (Exception error)
    {
        stderr.writefln("pr-plan: error: %s", error.msg);
        return 1;
    }
}

version (unittest)
{
    private bool rejectsInput(string source, bool gitMode)
    {
        try
            parseInput(source, gitMode);
        catch (InputException)
            return true;
        return false;
    }

    unittest
    {
        auto source = q{
        {
          "schema_version": 1,
          "repository": "test/repo",
          "prs": [
            {
              "number": 1, "title": "One", "author": null,
              "head_ref": "one", "base_ref": "main", "draft": false,
              "mergeable": "MERGEABLE", "review_decision": "APPROVED",
              "created_at": "2026-01-01T00:00:00Z", "updated_at": "2026-01-02T00:00:00Z",
              "additions": 1, "deletions": 0, "files": ["z", "a"],
              "base_conflict_paths": []
            },
            {
              "number": 2, "title": "Two", "author": "alice",
              "head_ref": "two", "base_ref": "one", "draft": false,
              "mergeable": "MERGEABLE", "review_decision": "NONE",
              "created_at": "2026-01-02T00:00:00Z", "updated_at": "2026-01-03T00:00:00Z",
              "additions": 1, "deletions": 0, "files": ["a"],
              "base_conflict_paths": []
            }
          ],
          "conflict_edges": [],
          "ancestry_edges": []
        }
        };
        auto plan = buildPlan(parseInput(source, false));
        assert(plan.stacks == [[1L, 2L]]);
        assert(plan.fileOverlapEdges == [ConflictEdge(1, 2, ["a"])]);
        assert(plan.readyNow == [1L]);
        assert(renderJson(plan) == renderJson(plan));
        assert(renderHuman(plan) == "test/repo: 2 PRs, 0 conflicts, ready #1\n");
    }

    unittest
    {
        bool rejected;
        try
            parseInput(`{"schema_version":1,"repository":7,"prs":[],"conflict_edges":[],"ancestry_edges":[]}`, false);
        catch (InputException)
            rejected = true;
        assert(rejected, "incorrectly typed repository must be rejected");

        rejected = false;
        try
            parseInput(`{"schema_version":1,"repository":"x","prs":[],"conflict_edges":[],"ancestry_edges":[],"extra":true}`, false);
        catch (InputException)
            rejected = true;
        assert(rejected, "unexpected fields must be rejected");
    }

    unittest
    {
        auto validPure = q{
        {
          "schema_version": 1,
          "repository": "test/validation",
          "prs": [{
            "number": 1, "title": "One", "author": null,
            "head_ref": "one", "base_ref": "main", "draft": false,
            "mergeable": "MERGEABLE", "review_decision": "APPROVED",
            "created_at": "2024-02-29T23:59:60.123+23:59",
            "updated_at": "2024-03-01T00:00:00Z",
            "additions": 1, "deletions": 0,
            "files": ["a"], "base_conflict_paths": ["b"]
          }, {
            "number": 2, "title": "Two", "author": null,
            "head_ref": "two", "base_ref": "main", "draft": false,
            "mergeable": "MERGEABLE", "review_decision": "APPROVED",
            "created_at": "2024-03-01T00:00:00Z",
            "updated_at": "2024-03-01T00:00:00Z",
            "additions": 0, "deletions": 0,
            "files": ["d"], "base_conflict_paths": []
          }],
          "conflict_edges": [],
          "ancestry_edges": []
        }
        };
        parseInput(validPure, false);

        foreach (invalid; [
            "2023-02-29T23:59:59Z",
            "2024-13-01T00:00:00Z",
            "2024-02-29 23:59:59Z",
            "2024-02-29T23:59:59",
            "2024-02-29T23:59:59.Z",
            "2024-02-29T23:59:59+24:00",
            "2024-02-29T23:59:59Zjunk",
        ])
        {
            auto source = validPure.replace("2024-02-29T23:59:60.123+23:59", invalid);
            assert(rejectsInput(source, false), "invalid RFC 3339 timestamp was accepted: " ~ invalid);
        }

        assert(rejectsInput(
            validPure.replace(`"files": ["a"]`, `"files": ["a", "a"]`),
            false,
        ), "duplicate files must be rejected");
        assert(rejectsInput(
            validPure.replace(`"base_conflict_paths": ["b"]`, `"base_conflict_paths": ["b", "b"]`),
            false,
        ), "duplicate base-conflict paths must be rejected");
        assert(rejectsInput(
            validPure.replace(`"conflict_edges": []`,
                `"conflict_edges": [{"a": 1, "b": 2, "paths": ["x", "x"]}]`),
            false,
        ), "duplicate conflict paths must be rejected");
    }

    unittest
    {
        auto validGit = q{
        {
          "schema_version": 1,
          "repository": "test/git-validation",
          "prs": [{
            "number": 1, "title": "One", "author": null,
            "head_ref": "one", "base_ref": "main", "draft": false,
            "mergeable": "MERGEABLE", "review_decision": "APPROVED",
            "created_at": "2024-01-01T00:00:00Z",
            "updated_at": "2024-01-01T00:00:00Z",
            "additions": 1, "deletions": 0,
            "git_head": "main", "git_base": "main"
          }]
        }
        };
        assert(rejectsInput(validGit.replace(`"git_head": "main"`, `"git_head": "--help"`), true),
            "option-like Git revisions must be rejected");
        assert(rejectsInput(validGit.replace(`"git_base": "main"`, `"git_base": "main\nother"`), true),
            "Git revisions containing control characters must be rejected");

        auto input = parseInput(validGit, true);
        input.prs[0].gitHead = "--help";
        bool rejectedBeforeGit;
        try
            analyzeRepository(input, "/definitely/not/a/repository");
        catch (InputException)
            rejectedBeforeGit = true;
        assert(rejectedBeforeGit, "unsafe revisions must be rejected before repository access");
    }

    unittest
    {
        import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
        import std.path : buildPath;
        import std.process : thisProcessID;

        auto directory = buildPath(tempDir(), "pr-plan-d-test-" ~ thisProcessID.to!string);
        mkdirRecurse(directory);
        scope (exit)
            rmdirRecurse(directory);
        auto left = buildPath(directory, "left");
        auto right = buildPath(directory, "right");
        write(left, "left\n");
        write(right, "right\n");
        auto difference = runGit(".", ["diff", "--quiet", "--no-index", left, right], [0, 1]);
        assert(difference.status == 1);
        bool failed;
        try
            runGit(".", ["definitely-not-a-git-subcommand"]);
        catch (GitException)
            failed = true;
        assert(failed, "unexpected Git status must fail");

        auto redirect = buildPath(directory, "redirect");
        mkdirRecurse(redirect);
        runGit(redirect, ["init", "--quiet"]);
        auto inheritedGitDir = environment.get("GIT_DIR");
        scope (exit)
            environment["GIT_DIR"] = inheritedGitDir;
        environment["GIT_DIR"] = buildPath(redirect, ".git");

        auto repository = buildPath(directory, "repository");
        mkdirRecurse(repository);
        bool invalidRepositoryRejected;
        try
            analyzeRepository(AnalysisInput("test/empty", [], [], []), repository);
        catch (GitException)
            invalidRepositoryRejected = true;
        assert(invalidRepositoryRejected,
            "empty Git input must validate --git-dir independently of inherited GIT_DIR");

        runGit(repository, ["init", "--quiet"]);
        auto analyzed = analyzeRepository(AnalysisInput("test/empty", [], [], []), repository);
        assert(analyzed.prs.length == 0, "empty input must work with a valid repository");
    }
}
else
{
    void main(string[] arguments)
    {
        import core.stdc.stdlib : exit;

        exit(run(arguments[1 .. $]));
    }
}
