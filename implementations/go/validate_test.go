package main

import (
	"strings"
	"testing"
)

const validPureDocument = `{
  "schema_version": 1,
  "repository": "acme/widgets",
  "prs": [{
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
    "files": [],
    "base_conflict_paths": []
  }],
  "conflict_edges": [],
  "ancestry_edges": []
}`

func decodeTestDocument(t *testing.T, source, mode string) (AnalysisInput, error) {
	t.Helper()
	value, err := decodeJSON([]byte(source))
	if err != nil {
		return AnalysisInput{}, err
	}
	return decodeDocument(value, mode)
}

func TestStrictValidationAcceptsOptionalAuthor(t *testing.T) {
	document, err := decodeTestDocument(t, validPureDocument, "pure")
	if err != nil {
		t.Fatalf("decode valid document: %v", err)
	}
	if document.PRs[0].Author != nil {
		t.Fatalf("author = %v, want nil", document.PRs[0].Author)
	}
}

func TestStrictValidationRejectsMalformedBoundaries(t *testing.T) {
	tests := []struct {
		name    string
		source  string
		message string
	}{
		{
			name:    "string number",
			source:  strings.Replace(validPureDocument, `"number": 1`, `"number": "1"`, 1),
			message: "number: expected an integer",
		},
		{
			name:    "boolean additions",
			source:  strings.Replace(validPureDocument, `"additions": 1`, `"additions": true`, 1),
			message: "additions: expected an integer",
		},
		{
			name:    "wrong author type",
			source:  strings.Replace(validPureDocument, `"author": null`, `"author": {"login":"alice"}`, 1),
			message: "author: expected a string",
		},
		{
			name:    "invalid enum",
			source:  strings.Replace(validPureDocument, `"mergeable": "MERGEABLE"`, `"mergeable": "YES"`, 1),
			message: "mergeable: expected one of",
		},
		{
			name:    "invalid timestamp",
			source:  strings.Replace(validPureDocument, `"created_at": "2026-01-01T00:00:00Z"`, `"created_at": "yesterday"`, 1),
			message: "created_at: expected an RFC 3339 timestamp",
		},
		{
			name:    "unknown field",
			source:  strings.Replace(validPureDocument, `"schema_version": 1,`, `"schema_version": 1, "extra": true,`, 1),
			message: "unknown field(s): extra",
		},
		{
			name:    "duplicate field",
			source:  strings.Replace(validPureDocument, `"repository": "acme/widgets",`, `"repository": "acme/widgets", "repository": "other",`, 1),
			message: "repository: duplicate field",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, err := decodeTestDocument(t, test.source, "pure")
			if err == nil || !strings.Contains(err.Error(), test.message) {
				t.Fatalf("error = %v, want substring %q", err, test.message)
			}
		})
	}
}

func TestValidationRejectsUnsafeGitRevision(t *testing.T) {
	source := strings.NewReplacer(
		`"files": []`, `"git_head": "--upload-pack=bad"`,
		`"base_conflict_paths": []`, `"git_base": "main"`,
	).Replace(validPureDocument)
	source = strings.Replace(source, ",\n  \"conflict_edges\": [],\n  \"ancestry_edges\": []", "", 1)
	_, err := decodeTestDocument(t, source, "git")
	if err == nil || !strings.Contains(err.Error(), "revision must not start with '-'") {
		t.Fatalf("error = %v, want unsafe revision error", err)
	}
}

func TestValidationRejectsDuplicatePaths(t *testing.T) {
	source := strings.Replace(validPureDocument, `"files": []`, `"files": ["same", "same"]`, 1)
	_, err := decodeTestDocument(t, source, "pure")
	if err == nil || !strings.Contains(err.Error(), "paths must be unique") {
		t.Fatalf("error = %v, want duplicate path error", err)
	}
}
