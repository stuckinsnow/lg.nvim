package server

import (
	"strings"
	"testing"
)

func TestPreviewSessionValidation(t *testing.T) {
	if got := PreviewSession("kiro", ""); got != "" {
		t.Fatalf("empty sessionID = %q, want empty", got)
	}
	if got := PreviewSession("kiro", "../etc/passwd"); got != "" {
		t.Fatalf("traversal sessionID = %q, want empty", got)
	}
	if got := PreviewSession("unknown", "abc"); got != "" {
		t.Fatalf("unknown provider = %q, want empty", got)
	}
}

func TestCleanUserRequest(t *testing.T) {
	raw := "<USER_REQUEST>\nhello world\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\ntime\n</ADDITIONAL_METADATA>"
	if got := cleanUserRequest(raw); got != "hello world" {
		t.Fatalf("cleanUserRequest = %q, want %q", got, "hello world")
	}
	if got := cleanUserRequest("  plain prompt  "); got != "plain prompt" {
		t.Fatalf("cleanUserRequest plain = %q, want %q", got, "plain prompt")
	}
}

func TestFormatPreview(t *testing.T) {
	turns := []previewTurn{
		{Role: "User", Text: "hi"},
		{Role: "Assistant", Text: strings.Repeat("a", maxTurnChars+50)},
	}
	got := formatPreview(turns)
	if !strings.Contains(got, "**User:**\nhi") {
		t.Fatalf("missing user turn in %q", got)
	}
	if !strings.Contains(got, "\n\n---\n\n**Assistant:**\n") {
		t.Fatalf("missing separator/assistant turn in %q", got)
	}
	if !strings.HasSuffix(got, "...") {
		t.Fatalf("expected truncated suffix in %q", got)
	}
}

func TestFormatPreviewLast100Lines(t *testing.T) {
	var lines []string
	for i := 0; i < 150; i++ {
		lines = append(lines, "line")
	}
	got := formatPreview([]previewTurn{{Text: strings.Join(lines, "\n")}})
	if n := len(strings.Split(got, "\n")); n != maxPreviewLines {
		t.Fatalf("line count = %d, want %d", n, maxPreviewLines)
	}
}

func TestAppendTurnSlidingWindow(t *testing.T) {
	var turns []previewTurn
	for i := 0; i < 10; i++ {
		turns = appendTurn(turns, previewTurn{Text: string(rune('a' + i))})
	}
	if len(turns) != maxPreviewTurns {
		t.Fatalf("len = %d, want %d", len(turns), maxPreviewTurns)
	}
	if turns[0].Text != "e" || turns[len(turns)-1].Text != "j" {
		t.Fatalf("unexpected window: %+v", turns)
	}
}
