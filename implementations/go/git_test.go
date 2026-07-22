package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func testGit(t *testing.T, repository string, arguments ...string) string {
	t.Helper()
	commandArguments := append([]string{"-C", repository}, arguments...)
	command := exec.Command("git", commandArguments...)
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v\n%s", arguments, err, output)
	}
	return strings.TrimSpace(string(output))
}

func commitAll(t *testing.T, repository, message string) {
	t.Helper()
	testGit(t, repository, "add", "-A")
	testGit(t, repository, "-c", "user.name=Test User", "-c", "user.email=test@example.com", "commit", "-m", message)
}

func makeConflictRepository(t *testing.T) (string, string) {
	t.Helper()
	repository := t.TempDir()
	testGit(t, repository, "init", "--initial-branch=main")
	if err := os.WriteFile(filepath.Join(repository, "shared.txt"), []byte("base\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	commitAll(t, repository, "base")
	base := testGit(t, repository, "rev-parse", "HEAD")
	testGit(t, repository, "checkout", "-b", "left")
	if err := os.WriteFile(filepath.Join(repository, "shared.txt"), []byte("left\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repository, "left.txt"), []byte("left\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	commitAll(t, repository, "left")
	testGit(t, repository, "checkout", "-b", "right", base)
	if err := os.WriteFile(filepath.Join(repository, "shared.txt"), []byte("right\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	commitAll(t, repository, "right")
	return repository, base
}

func revision(value string) *GitRevision {
	revision := GitRevision(value)
	return &revision
}

func TestRealGitAnalysisAndExpectedStatus(t *testing.T) {
	repositoryPath, _ := makeConflictRepository(t)
	first := testPR(1)
	first.GitHead, first.GitBase = revision("refs/heads/left"), revision("refs/heads/main")
	second := testPR(2)
	second.GitHead, second.GitBase = revision("refs/heads/right"), revision("refs/heads/main")
	analyzed, err := analyzeRepository(AnalysisInput{Repository: "acme/widgets", PRs: []PullRequest{first, second}}, repositoryPath)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(analyzed.PRs[0].Files, []string{"left.txt", "shared.txt"}) {
		t.Fatalf("files = %v", analyzed.PRs[0].Files)
	}
	if !reflect.DeepEqual(analyzed.ConflictEdges, []ConflictEdge{{A: 1, B: 2, Paths: []string{"shared.txt"}}}) {
		t.Fatalf("conflicts = %v", analyzed.ConflictEdges)
	}
	repository, err := openGitRepository(repositoryPath)
	if err != nil {
		t.Fatal(err)
	}
	left, _ := repository.resolveCommit("refs/heads/left")
	right, _ := repository.resolveCommit("refs/heads/right")
	ancestor, err := repository.isAncestor(left, right)
	if err != nil || ancestor {
		t.Fatalf("isAncestor = %v, %v", ancestor, err)
	}
	if _, err := repository.run([]string{"merge-base", "--is-ancestor", left, right}, 0); err == nil || !strings.Contains(err.Error(), "status 1") {
		t.Fatalf("unexpected status error: %v", err)
	}
}

func TestInheritedGitDirCannotRedirectRepository(t *testing.T) {
	repositoryPath, base := makeConflictRepository(t)
	t.Setenv("GIT_DIR", "/definitely/not/the/repository")
	repository, err := openGitRepository(repositoryPath)
	if err != nil {
		t.Fatal(err)
	}
	got, err := repository.resolveCommit("refs/heads/main")
	if err != nil {
		t.Fatal(err)
	}
	if got != base {
		t.Fatalf("main = %s, want %s", got, base)
	}
}
