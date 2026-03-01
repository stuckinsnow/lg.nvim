package search

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os/exec"
	"strings"
)

var IndexURL string

func detectGitInfo() (repo, branch, head string) {
	if out, err := exec.Command("git", "remote", "get-url", "origin").Output(); err == nil {
		s := strings.TrimSpace(string(out))
		if i := strings.LastIndex(s, "/"); i >= 0 {
			repo = strings.TrimSuffix(s[i+1:], ".git")
		}
	}
	if out, err := exec.Command("git", "branch", "--show-current").Output(); err == nil {
		branch = strings.TrimSpace(string(out))
	}
	if branch != "" {
		if out, err := exec.Command("git", "rev-parse", "origin/"+branch).Output(); err == nil {
			head = strings.TrimSpace(string(out))
		}
	}
	return
}

func SearchIndex(query string, topN int) (string, error) {
	repo, branch, head := detectGitInfo()
	if repo == "" {
		return "", fmt.Errorf("cannot detect git repo")
	}
	if topN == 0 {
		topN = 15
	}
	body, _ := json.Marshal(map[string]any{
		"repo": repo, "branch": branch, "query": query, "top_n": topN, "head": head,
	})
	resp, err := http.Post(IndexURL+"/find", "application/json", bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	defer func() { _ = resp.Body.Close() }()
	data, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 {
		return "", fmt.Errorf("index API: %s", string(data))
	}
	var results []struct {
		File      string  `json:"file"`
		StartLine int     `json:"start_line"`
		EndLine   int     `json:"end_line"`
		Score     float64 `json:"score"`
		Content   string  `json:"content"`
	}
	if err := json.Unmarshal(data, &results); err != nil {
		return "", err
	}
	if len(results) == 0 {
		return "No results found.", nil
	}
	var sb strings.Builder
	fullCount := 5
	fullCount = min(fullCount, len(results))
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
	return sb.String(), nil
}
