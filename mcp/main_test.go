package main

import (
	"fmt"
	"strings"
	"testing"
)

func TestSearchFormatting(t *testing.T) {
	results := []struct {
		File      string
		StartLine int
		EndLine   int
		Score     float64
		Content   string
	}{
		{File: "src/auth.go", StartLine: 10, EndLine: 25, Score: 0.85, Content: "func Login(user, pass string) error {\n\treturn nil\n}"},
		{File: "src/session.go", StartLine: 1, EndLine: 20, Score: 0.78, Content: "type Session struct {\n\tToken string\n}"},
		{File: "pkg/middleware.ts", StartLine: 1, EndLine: 15, Score: 0.72, Content: "export function authMiddleware(req: Request) {\n  return next()\n}"},
		{File: "src/handler.go", StartLine: 30, EndLine: 50, Score: 0.65, Content: "func HandleLogin(w http.ResponseWriter, r *http.Request) {}"},
		{File: "Makefile", StartLine: 5, EndLine: 8, Score: 0.55, Content: "build:\n\tgo build -o bin/app ."},
		// These should appear as refs only (no content)
		{File: "src/config.go", StartLine: 1, EndLine: 10, Score: 0.48, Content: "var defaultConfig = ..."},
		{File: "src/db.go", StartLine: 20, EndLine: 35, Score: 0.35, Content: "func Connect() {}"},
		// Below 0.3 threshold — should be excluded
		{File: "README.md", StartLine: 1, EndLine: 5, Score: 0.25, Content: "# My App"},
	}

	var sb strings.Builder
	fullCount := 5
	if fullCount > len(results) {
		fullCount = len(results)
	}
	for i := 0; i < fullCount; i++ {
		r := results[i]
		ext := ""
		if j := strings.LastIndex(r.File, "."); j >= 0 {
			ext = r.File[j+1:]
		}
		fmt.Fprintf(&sb, "### %s (lines %d-%d, score: %.2f)\n```%s\n%s\n```\n\n", r.File, r.StartLine, r.EndLine, r.Score, ext, r.Content)
	}
	var refs []string
	for i := fullCount; i < len(results); i++ {
		r := results[i]
		if r.Score < 0.3 {
			break
		}
		refs = append(refs, fmt.Sprintf("- %s (lines %d-%d, score: %.2f)", r.File, r.StartLine, r.EndLine, r.Score))
	}
	if len(refs) > 0 {
		sb.WriteString("### Also relevant\n")
		sb.WriteString(strings.Join(refs, "\n"))
		sb.WriteString("\n")
	}
	got := sb.String()

	// Top 5 should have full content
	for _, exp := range []string{
		"### src/auth.go (lines 10-25, score: 0.85)\n```go\n",
		"func Login(user, pass string)",
		"### Makefile (lines 5-8, score: 0.55)\n```\n",
	} {
		if !strings.Contains(got, exp) {
			t.Errorf("missing full result: %q", exp)
		}
	}

	// Refs section should list files without content
	if !strings.Contains(got, "### Also relevant") {
		t.Error("missing 'Also relevant' section")
	}
	if !strings.Contains(got, "- src/config.go (lines 1-10, score: 0.48)") {
		t.Error("missing config.go ref")
	}
	if !strings.Contains(got, "- src/db.go (lines 20-35, score: 0.35)") {
		t.Error("missing db.go ref")
	}

	// Below threshold should be excluded
	if strings.Contains(got, "README.md") {
		t.Error("README.md should be excluded (score < 0.3)")
	}

	// Refs should NOT contain code
	if strings.Contains(got, "var defaultConfig") {
		t.Error("refs should not contain code content")
	}

	t.Logf("Formatted output:\n%s", got)
}
