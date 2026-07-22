package main

import (
	"bytes"
	"context"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"
	"unicode/utf8"
)

type GitError struct {
	Message string
}

func (e *GitError) Error() string { return e.Message }

type commandResult struct {
	Status int
	Stdout []byte
	Stderr []byte
}

type gitRepository struct {
	path    string
	timeout time.Duration
}

func openGitRepository(path string) (*gitRepository, error) {
	absolute, err := filepath.Abs(path)
	if err != nil {
		return nil, &GitError{Message: fmt.Sprintf("%s: %v", path, err)}
	}
	resolved, err := filepath.EvalSymlinks(absolute)
	if err != nil {
		return nil, &GitError{Message: fmt.Sprintf("%s: %v", path, err)}
	}
	info, err := os.Stat(resolved)
	if err != nil {
		return nil, &GitError{Message: fmt.Sprintf("%s: %v", path, err)}
	}
	if !info.IsDir() {
		return nil, &GitError{Message: fmt.Sprintf("%s: Git directory must be a directory", path)}
	}
	repository := &gitRepository{path: resolved, timeout: 30 * time.Second}
	if _, err := repository.run([]string{"rev-parse", "--git-dir"}, 0); err != nil {
		return nil, err
	}
	return repository, nil
}

var blockedGitEnvironment = map[string]struct{}{
	"GIT_ALTERNATE_OBJECT_DIRECTORIES": {},
	"GIT_COMMON_DIR":                   {},
	"GIT_CONFIG_COUNT":                 {},
	"GIT_CONFIG_PARAMETERS":            {},
	"GIT_DIR":                          {},
	"GIT_INDEX_FILE":                   {},
	"GIT_OBJECT_DIRECTORY":             {},
	"GIT_WORK_TREE":                    {},
}

func gitEnvironment() []string {
	result := make([]string, 0, len(os.Environ())+5)
	for _, entry := range os.Environ() {
		name, _, _ := strings.Cut(entry, "=")
		if _, blocked := blockedGitEnvironment[name]; !blocked {
			result = append(result, entry)
		}
	}
	result = append(result,
		"GIT_CONFIG_NOSYSTEM=1",
		"GIT_CONFIG_GLOBAL="+os.DevNull,
		"GIT_OPTIONAL_LOCKS=0",
		"GIT_TERMINAL_PROMPT=0",
		"LC_ALL=C",
	)
	return result
}

func statusAllowed(status int, allowed []int) bool {
	for _, value := range allowed {
		if status == value {
			return true
		}
	}
	return false
}

func (repository *gitRepository) run(arguments []string, allowed ...int) (commandResult, error) {
	if len(arguments) == 0 {
		return commandResult{}, &GitError{Message: "internal error: empty Git command"}
	}
	ctx, cancel := context.WithTimeout(context.Background(), repository.timeout)
	defer cancel()
	commandArguments := append([]string{"-C", repository.path}, arguments...)
	command := exec.CommandContext(ctx, "git", commandArguments...)
	command.Env = gitEnvironment()
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr
	err := command.Run()
	result := commandResult{Status: 0, Stdout: stdout.Bytes(), Stderr: stderr.Bytes()}
	if ctx.Err() == context.DeadlineExceeded {
		return result, &GitError{Message: fmt.Sprintf("git %s timed out after %s", arguments[0], repository.timeout)}
	}
	if err != nil {
		var exitError *exec.ExitError
		if errors.As(err, &exitError) {
			result.Status = exitError.ExitCode()
		} else {
			return result, &GitError{Message: fmt.Sprintf("could not run git %s: %v", arguments[0], err)}
		}
	}
	if len(allowed) == 0 {
		allowed = []int{0}
	}
	if !statusAllowed(result.Status, allowed) {
		detail := strings.TrimSpace(string(result.Stderr))
		if detail == "" {
			detail = strings.TrimSpace(string(result.Stdout))
		}
		suffix := ""
		if detail != "" {
			suffix = ": " + detail
		}
		return result, &GitError{Message: fmt.Sprintf("git %s exited with status %d%s", arguments[0], result.Status, suffix)}
	}
	return result, nil
}

func validObjectID(value string) bool {
	if len(value) != 40 && len(value) != 64 {
		return false
	}
	_, err := hex.DecodeString(value)
	return err == nil
}

func (repository *gitRepository) resolveCommit(revision GitRevision) (string, error) {
	result, err := repository.run([]string{"rev-parse", "--verify", string(revision) + "^{commit}"}, 0)
	if err != nil {
		return "", err
	}
	objectID := strings.TrimSpace(string(result.Stdout))
	if !validObjectID(objectID) {
		return "", &GitError{Message: "git rev-parse returned an invalid commit ID"}
	}
	return strings.ToLower(objectID), nil
}

func (repository *gitRepository) mergeBase(left, right string) (string, error) {
	result, err := repository.run([]string{"merge-base", left, right}, 0)
	if err != nil {
		return "", err
	}
	objectID := strings.TrimSpace(string(result.Stdout))
	if !validObjectID(objectID) {
		return "", &GitError{Message: "git merge-base returned an invalid commit ID"}
	}
	return strings.ToLower(objectID), nil
}

func nulPaths(output []byte) ([]string, error) {
	seen := make(map[string]struct{})
	paths := make([]string, 0)
	for _, record := range bytes.Split(output, []byte{0}) {
		if len(record) == 0 {
			continue
		}
		if !utf8.Valid(record) {
			return nil, &GitError{Message: "git returned a path that is not valid UTF-8"}
		}
		path := string(record)
		if _, exists := seen[path]; !exists {
			seen[path] = struct{}{}
			paths = append(paths, path)
		}
	}
	sort.Strings(paths)
	return paths, nil
}

func (repository *gitRepository) changedFiles(base, head string) ([]string, error) {
	common, err := repository.mergeBase(base, head)
	if err != nil {
		return nil, err
	}
	result, err := repository.run([]string{"diff", "--name-only", "-z", common, head, "--"}, 0)
	if err != nil {
		return nil, err
	}
	return nulPaths(result.Stdout)
}

func (repository *gitRepository) conflictPaths(left, right string) ([]string, error) {
	result, err := repository.run([]string{
		"merge-tree", "--write-tree", "--name-only", "--no-messages", "-z", left, right,
	}, 0, 1)
	if err != nil {
		return nil, err
	}
	if result.Status == 0 {
		return []string{}, nil
	}
	records := bytes.Split(result.Stdout, []byte{0})
	if len(records) == 0 {
		return nil, &GitError{Message: "git merge-tree returned malformed conflict output"}
	}
	return nulPaths(bytes.Join(records[1:], []byte{0}))
}

func (repository *gitRepository) isAncestor(before, after string) (bool, error) {
	result, err := repository.run([]string{"merge-base", "--is-ancestor", before, after}, 0, 1)
	if err != nil {
		return false, err
	}
	return result.Status == 0, nil
}

func analyzeRepository(data AnalysisInput, path string) (AnalysisInput, error) {
	repository, err := openGitRepository(path)
	if err != nil {
		return AnalysisInput{}, err
	}
	resolvedHeads := make(map[PRNumber]string, len(data.PRs))
	analyzed := make([]PullRequest, 0, len(data.PRs))
	for _, inputPR := range data.PRs {
		pr := inputPR
		if pr.GitHead == nil || pr.GitBase == nil {
			return AnalysisInput{}, &GitError{Message: fmt.Sprintf("internal error: missing Git revisions for PR #%d", pr.Number)}
		}
		head, err := repository.resolveCommit(*pr.GitHead)
		if err != nil {
			return AnalysisInput{}, err
		}
		base, err := repository.resolveCommit(*pr.GitBase)
		if err != nil {
			return AnalysisInput{}, err
		}
		pr.Files, err = repository.changedFiles(base, head)
		if err != nil {
			return AnalysisInput{}, err
		}
		pr.BaseConflictPaths, err = repository.conflictPaths(base, head)
		if err != nil {
			return AnalysisInput{}, err
		}
		resolvedHeads[pr.Number] = head
		analyzed = append(analyzed, pr)
	}

	conflicts := make([]ConflictEdge, 0)
	ancestry := make([]AncestryEdge, 0)
	for leftIndex, left := range analyzed {
		leftHead := resolvedHeads[left.Number]
		for _, right := range analyzed[leftIndex+1:] {
			rightHead := resolvedHeads[right.Number]
			paths, err := repository.conflictPaths(leftHead, rightHead)
			if err != nil {
				return AnalysisInput{}, err
			}
			if len(paths) != 0 {
				conflicts = append(conflicts, ConflictEdge{A: left.Number, B: right.Number, Paths: paths})
			}
			if leftHead == rightHead {
				continue
			}
			leftBeforeRight, err := repository.isAncestor(leftHead, rightHead)
			if err != nil {
				return AnalysisInput{}, err
			}
			if leftBeforeRight {
				ancestry = append(ancestry, AncestryEdge{Before: left.Number, After: right.Number})
				continue
			}
			rightBeforeLeft, err := repository.isAncestor(rightHead, leftHead)
			if err != nil {
				return AnalysisInput{}, err
			}
			if rightBeforeLeft {
				ancestry = append(ancestry, AncestryEdge{Before: right.Number, After: left.Number})
			}
		}
	}
	return AnalysisInput{
		Repository: data.Repository, PRs: analyzed, ConflictEdges: conflicts, AncestryEdges: ancestry,
	}, nil
}
