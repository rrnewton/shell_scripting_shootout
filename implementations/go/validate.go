package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"
)

type InputError struct {
	Message string
}

func (e *InputError) Error() string { return e.Message }

func inputError(path, format string, args ...any) error {
	return &InputError{Message: path + ": " + fmt.Sprintf(format, args...)}
}

func fieldPath(path, field string) string {
	for index, character := range field {
		if !((character >= 'a' && character <= 'z') ||
			(character >= 'A' && character <= 'Z') || character == '_' ||
			(index > 0 && character >= '0' && character <= '9')) {
			return fmt.Sprintf("%s[%q]", path, field)
		}
	}
	return path + "." + field
}

// decodeJSON walks the token stream so duplicate object fields are not lost.
func decodeJSON(data []byte) (any, error) {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	value, err := decodeJSONValue(decoder, "$")
	if err != nil {
		return nil, err
	}
	if _, err := decoder.Token(); err != io.EOF {
		if err == nil {
			return nil, inputError("$", "unexpected data after the JSON document")
		}
		return nil, inputError("$", "invalid JSON: %v", err)
	}
	return value, nil
}

func decodeJSONValue(decoder *json.Decoder, path string) (any, error) {
	token, err := decoder.Token()
	if err != nil {
		return nil, inputError(path, "invalid JSON: %v", err)
	}
	delimiter, isDelimiter := token.(json.Delim)
	if !isDelimiter {
		return token, nil
	}
	switch delimiter {
	case '{':
		result := make(map[string]any)
		for decoder.More() {
			keyToken, err := decoder.Token()
			if err != nil {
				return nil, inputError(path, "invalid JSON object: %v", err)
			}
			key, ok := keyToken.(string)
			if !ok {
				return nil, inputError(path, "object field name is not a string")
			}
			childPath := fieldPath(path, key)
			if _, exists := result[key]; exists {
				return nil, inputError(childPath, "duplicate field")
			}
			value, err := decodeJSONValue(decoder, childPath)
			if err != nil {
				return nil, err
			}
			result[key] = value
		}
		closing, err := decoder.Token()
		if err != nil || closing != json.Delim('}') {
			return nil, inputError(path, "invalid JSON object")
		}
		return result, nil
	case '[':
		result := make([]any, 0)
		for index := 0; decoder.More(); index++ {
			value, err := decodeJSONValue(decoder, fmt.Sprintf("%s[%d]", path, index))
			if err != nil {
				return nil, err
			}
			result = append(result, value)
		}
		closing, err := decoder.Token()
		if err != nil || closing != json.Delim(']') {
			return nil, inputError(path, "invalid JSON array")
		}
		return result, nil
	default:
		return nil, inputError(path, "unexpected JSON delimiter %q", delimiter)
	}
}

var commonPRKeys = []string{
	"additions", "author", "base_ref", "created_at", "deletions", "draft",
	"head_ref", "mergeable", "number", "review_decision", "title", "updated_at",
}

func keySet(keys ...string) map[string]struct{} {
	result := make(map[string]struct{}, len(keys))
	for _, key := range keys {
		result[key] = struct{}{}
	}
	return result
}

func appendKeys(keys []string, extra ...string) map[string]struct{} {
	all := append(append([]string(nil), keys...), extra...)
	return keySet(all...)
}

var (
	pureRootKeys = keySet("ancestry_edges", "conflict_edges", "prs", "repository", "schema_version")
	gitRootKeys  = keySet("prs", "repository", "schema_version")
	purePRKeys   = appendKeys(commonPRKeys, "base_conflict_paths", "files")
	gitPRKeys    = appendKeys(commonPRKeys, "git_base", "git_head")
)

func asObject(value any, path string) (map[string]any, error) {
	result, ok := value.(map[string]any)
	if !ok {
		return nil, inputError(path, "expected an object")
	}
	return result, nil
}

func asArray(value any, path string) ([]any, error) {
	result, ok := value.([]any)
	if !ok {
		return nil, inputError(path, "expected an array")
	}
	return result, nil
}

func exactKeys(value map[string]any, expected map[string]struct{}, path string) error {
	missing := make([]string, 0)
	unknown := make([]string, 0)
	for key := range expected {
		if _, ok := value[key]; !ok {
			missing = append(missing, key)
		}
	}
	for key := range value {
		if _, ok := expected[key]; !ok {
			unknown = append(unknown, key)
		}
	}
	sort.Strings(missing)
	sort.Strings(unknown)
	if len(missing) != 0 {
		return inputError(path, "missing field(s): %s", strings.Join(missing, ", "))
	}
	if len(unknown) != 0 {
		return inputError(path, "unknown field(s): %s", strings.Join(unknown, ", "))
	}
	return nil
}

func asString(value any, path string, nonempty bool) (string, error) {
	result, ok := value.(string)
	if !ok {
		return "", inputError(path, "expected a string")
	}
	if nonempty && result == "" {
		return "", inputError(path, "must not be empty")
	}
	if strings.ContainsRune(result, 0) {
		return "", inputError(path, "must not contain NUL")
	}
	return result, nil
}

func asOptionalString(value any, path string) (*string, error) {
	if value == nil {
		return nil, nil
	}
	result, err := asString(value, path, true)
	if err != nil {
		return nil, err
	}
	return &result, nil
}

func asInteger(value any, path string, positive bool) (int64, error) {
	number, ok := value.(json.Number)
	if !ok {
		return 0, inputError(path, "expected an integer")
	}
	result, err := strconv.ParseInt(number.String(), 10, 64)
	if err != nil {
		return 0, inputError(path, "expected an integer")
	}
	if positive && result <= 0 {
		return 0, inputError(path, "must be positive")
	}
	if !positive && result < 0 {
		return 0, inputError(path, "must not be negative")
	}
	return result, nil
}

func asBoolean(value any, path string) (bool, error) {
	result, ok := value.(bool)
	if !ok {
		return false, inputError(path, "expected a boolean")
	}
	return result, nil
}

func asTimestamp(value any, path string) (string, error) {
	result, err := asString(value, path, true)
	if err != nil {
		return "", err
	}
	if _, err := time.Parse(time.RFC3339Nano, result); err != nil {
		return "", inputError(path, "expected an RFC 3339 timestamp")
	}
	return result, nil
}

func asEnum(value any, path string, allowed map[string]struct{}) (string, error) {
	result, err := asString(value, path, true)
	if err != nil {
		return "", err
	}
	if _, ok := allowed[result]; !ok {
		choices := make([]string, 0, len(allowed))
		for choice := range allowed {
			choices = append(choices, choice)
		}
		sort.Strings(choices)
		return "", inputError(path, "expected one of: %s", strings.Join(choices, ", "))
	}
	return result, nil
}

func asPaths(value any, path string) ([]string, error) {
	items, err := asArray(value, path)
	if err != nil {
		return nil, err
	}
	result := make([]string, 0, len(items))
	seen := make(map[string]struct{}, len(items))
	for index, item := range items {
		itemPath := fmt.Sprintf("%s[%d]", path, index)
		filePath, err := asString(item, itemPath, true)
		if err != nil {
			return nil, err
		}
		if strings.HasPrefix(filePath, "/") {
			return nil, inputError(itemPath, "expected a repository-relative path")
		}
		if _, exists := seen[filePath]; exists {
			return nil, inputError(path, "paths must be unique")
		}
		seen[filePath] = struct{}{}
		result = append(result, filePath)
	}
	sort.Strings(result)
	return result, nil
}

func asRevision(value any, path string) (*GitRevision, error) {
	result, err := asString(value, path, true)
	if err != nil {
		return nil, err
	}
	if strings.HasPrefix(result, "-") {
		return nil, inputError(path, "revision must not start with '-'")
	}
	for _, character := range result {
		if character < 0x20 || character == 0x7f {
			return nil, inputError(path, "revision must not contain control characters")
		}
	}
	revision := GitRevision(result)
	return &revision, nil
}

var (
	mergeableValues = keySet(string(MergeableYes), string(MergeableConflicting), string(MergeableUnknown))
	reviewValues    = keySet(string(ReviewApproved), string(ReviewChangesRequested), string(ReviewRequired), string(ReviewNone))
)

func decodePullRequest(value any, index int, mode string) (PullRequest, error) {
	path := fmt.Sprintf("$.prs[%d]", index)
	item, err := asObject(value, path)
	if err != nil {
		return PullRequest{}, err
	}
	expected := purePRKeys
	if mode == "git" {
		expected = gitPRKeys
	}
	if err := exactKeys(item, expected, path); err != nil {
		return PullRequest{}, err
	}
	number, err := asInteger(item["number"], path+".number", true)
	if err != nil {
		return PullRequest{}, err
	}
	title, err := asString(item["title"], path+".title", true)
	if err != nil {
		return PullRequest{}, err
	}
	author, err := asOptionalString(item["author"], path+".author")
	if err != nil {
		return PullRequest{}, err
	}
	headRef, err := asString(item["head_ref"], path+".head_ref", true)
	if err != nil {
		return PullRequest{}, err
	}
	baseRef, err := asString(item["base_ref"], path+".base_ref", true)
	if err != nil {
		return PullRequest{}, err
	}
	draft, err := asBoolean(item["draft"], path+".draft")
	if err != nil {
		return PullRequest{}, err
	}
	mergeable, err := asEnum(item["mergeable"], path+".mergeable", mergeableValues)
	if err != nil {
		return PullRequest{}, err
	}
	review, err := asEnum(item["review_decision"], path+".review_decision", reviewValues)
	if err != nil {
		return PullRequest{}, err
	}
	createdAt, err := asTimestamp(item["created_at"], path+".created_at")
	if err != nil {
		return PullRequest{}, err
	}
	updatedAt, err := asTimestamp(item["updated_at"], path+".updated_at")
	if err != nil {
		return PullRequest{}, err
	}
	additions, err := asInteger(item["additions"], path+".additions", false)
	if err != nil {
		return PullRequest{}, err
	}
	deletions, err := asInteger(item["deletions"], path+".deletions", false)
	if err != nil {
		return PullRequest{}, err
	}

	pr := PullRequest{
		Number: PRNumber(number), Title: title, Author: author, HeadRef: headRef,
		BaseRef: baseRef, Draft: draft, Mergeable: Mergeable(mergeable),
		ReviewDecision: ReviewDecision(review), CreatedAt: createdAt,
		UpdatedAt: updatedAt, Additions: additions, Deletions: deletions,
		Files: []string{}, BaseConflictPaths: []string{},
	}
	if mode == "pure" {
		pr.Files, err = asPaths(item["files"], path+".files")
		if err != nil {
			return PullRequest{}, err
		}
		pr.BaseConflictPaths, err = asPaths(item["base_conflict_paths"], path+".base_conflict_paths")
		if err != nil {
			return PullRequest{}, err
		}
	} else {
		pr.GitHead, err = asRevision(item["git_head"], path+".git_head")
		if err != nil {
			return PullRequest{}, err
		}
		pr.GitBase, err = asRevision(item["git_base"], path+".git_base")
		if err != nil {
			return PullRequest{}, err
		}
	}
	return pr, nil
}

func asKnownPR(value any, path string, known map[PRNumber]struct{}) (PRNumber, error) {
	number, err := asInteger(value, path, true)
	if err != nil {
		return 0, err
	}
	result := PRNumber(number)
	if _, ok := known[result]; !ok {
		return 0, inputError(path, "unknown pull request #%d", result)
	}
	return result, nil
}

type prPair struct {
	First  PRNumber
	Second PRNumber
}

func decodeConflictEdges(value any, known map[PRNumber]struct{}) ([]ConflictEdge, error) {
	items, err := asArray(value, "$.conflict_edges")
	if err != nil {
		return nil, err
	}
	result := make([]ConflictEdge, 0, len(items))
	seen := make(map[prPair]struct{}, len(items))
	for index, value := range items {
		path := fmt.Sprintf("$.conflict_edges[%d]", index)
		item, err := asObject(value, path)
		if err != nil {
			return nil, err
		}
		if err := exactKeys(item, keySet("a", "b", "paths"), path); err != nil {
			return nil, err
		}
		a, err := asKnownPR(item["a"], path+".a", known)
		if err != nil {
			return nil, err
		}
		b, err := asKnownPR(item["b"], path+".b", known)
		if err != nil {
			return nil, err
		}
		if a == b {
			return nil, inputError(path, "a conflict edge must join two different pull requests")
		}
		if b < a {
			a, b = b, a
		}
		pair := prPair{a, b}
		if _, exists := seen[pair]; exists {
			return nil, inputError(path, "duplicate conflict edge #%d/#%d", a, b)
		}
		seen[pair] = struct{}{}
		paths, err := asPaths(item["paths"], path+".paths")
		if err != nil {
			return nil, err
		}
		result = append(result, ConflictEdge{A: a, B: b, Paths: paths})
	}
	sort.Slice(result, func(i, j int) bool {
		if result[i].A != result[j].A {
			return result[i].A < result[j].A
		}
		return result[i].B < result[j].B
	})
	return result, nil
}

func decodeAncestryEdges(value any, known map[PRNumber]struct{}) ([]AncestryEdge, error) {
	items, err := asArray(value, "$.ancestry_edges")
	if err != nil {
		return nil, err
	}
	result := make([]AncestryEdge, 0, len(items))
	seen := make(map[prPair]struct{}, len(items))
	for index, value := range items {
		path := fmt.Sprintf("$.ancestry_edges[%d]", index)
		item, err := asObject(value, path)
		if err != nil {
			return nil, err
		}
		if err := exactKeys(item, keySet("after", "before"), path); err != nil {
			return nil, err
		}
		before, err := asKnownPR(item["before"], path+".before", known)
		if err != nil {
			return nil, err
		}
		after, err := asKnownPR(item["after"], path+".after", known)
		if err != nil {
			return nil, err
		}
		if before == after {
			return nil, inputError(path, "an ancestry edge must join two different pull requests")
		}
		pair := prPair{before, after}
		if _, exists := seen[pair]; exists {
			return nil, inputError(path, "duplicate ancestry edge #%d -> #%d", before, after)
		}
		seen[pair] = struct{}{}
		result = append(result, AncestryEdge{Before: before, After: after})
	}
	sort.Slice(result, func(i, j int) bool {
		if result[i].Before != result[j].Before {
			return result[i].Before < result[j].Before
		}
		return result[i].After < result[j].After
	})
	return result, nil
}

func decodeDocument(value any, mode string) (AnalysisInput, error) {
	if mode != "pure" && mode != "git" {
		return AnalysisInput{}, fmt.Errorf("unsupported mode %q", mode)
	}
	root, err := asObject(value, "$")
	if err != nil {
		return AnalysisInput{}, err
	}
	expected := pureRootKeys
	if mode == "git" {
		expected = gitRootKeys
	}
	if err := exactKeys(root, expected, "$"); err != nil {
		return AnalysisInput{}, err
	}
	version, err := asInteger(root["schema_version"], "$.schema_version", true)
	if err != nil {
		return AnalysisInput{}, err
	}
	if version != 1 {
		return AnalysisInput{}, inputError("$.schema_version", "only schema version 1 is supported")
	}
	repository, err := asString(root["repository"], "$.repository", true)
	if err != nil {
		return AnalysisInput{}, err
	}
	items, err := asArray(root["prs"], "$.prs")
	if err != nil {
		return AnalysisInput{}, err
	}
	prs := make([]PullRequest, 0, len(items))
	numbers := make(map[PRNumber]struct{}, len(items))
	headRefs := make(map[string]struct{}, len(items))
	for index, value := range items {
		pr, err := decodePullRequest(value, index, mode)
		if err != nil {
			return AnalysisInput{}, err
		}
		if _, exists := numbers[pr.Number]; exists {
			return AnalysisInput{}, inputError("$.prs", "pull request numbers must be unique")
		}
		if _, exists := headRefs[pr.HeadRef]; exists {
			return AnalysisInput{}, inputError("$.prs", "head_ref values must be unique")
		}
		numbers[pr.Number] = struct{}{}
		headRefs[pr.HeadRef] = struct{}{}
		prs = append(prs, pr)
	}
	sort.Slice(prs, func(i, j int) bool { return prs[i].Number < prs[j].Number })
	result := AnalysisInput{
		Repository: repository, PRs: prs, ConflictEdges: []ConflictEdge{}, AncestryEdges: []AncestryEdge{},
	}
	if mode == "pure" {
		result.ConflictEdges, err = decodeConflictEdges(root["conflict_edges"], numbers)
		if err != nil {
			return AnalysisInput{}, err
		}
		result.AncestryEdges, err = decodeAncestryEdges(root["ancestry_edges"], numbers)
		if err != nil {
			return AnalysisInput{}, err
		}
	}
	return result, nil
}

func loadDocument(path, mode string) (AnalysisInput, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return AnalysisInput{}, &InputError{Message: fmt.Sprintf("%s: %v", path, err)}
	}
	value, err := decodeJSON(data)
	if err != nil {
		return AnalysisInput{}, &InputError{Message: fmt.Sprintf("%s: %v", path, err)}
	}
	return decodeDocument(value, mode)
}
