package session

import "testing"

func TestModeFilter_IgnoresKiroAndOpencode(t *testing.T) {
	// Kiro and opencode handle tool filtering themselves; we don't interfere.
	for _, p := range []string{"kiro", "opencode", ""} {
		if got := ModeFilter(p, "reviewer", "anything"); got != DecisionUnknown {
			t.Errorf("provider=%q should be DecisionUnknown, got %v", p, got)
		}
	}
}

func TestModeFilter_ReviewerMode(t *testing.T) {
	cases := []struct {
		title string
		want  ModeDecision
	}{
		{"Reading foo.lua:1", DecisionAllow},
		{"grep bar", DecisionAllow},
		{"glob **/*.lua", DecisionAllow},
		{"@lg-hint/lg_hint", DecisionAllow},
		{"lg-hint-lg_hint: lg_hint", DecisionAllow},
		// Writes must be denied in reviewer mode
		{"Editing foo.lua", DecisionDeny},
		{"Creating bar.txt", DecisionDeny},
		{"@lg/paint_edit", DecisionDeny},
		{"lg-paint_edit: paint_edit", DecisionDeny},
		{"Running npm install", DecisionDeny},
	}
	for _, tc := range cases {
		if got := ModeFilter("cursor", "reviewer", tc.title); got != tc.want {
			t.Errorf("reviewer: %q → %v, want %v", tc.title, got, tc.want)
		}
	}
}

func TestModeFilter_LgMode(t *testing.T) {
	cases := []struct {
		title string
		want  ModeDecision
	}{
		// Full lg mode allows paint_edit via lg MCP
		{"@lg/paint_edit", DecisionAllow},
		{"lg-paint_edit: paint_edit", DecisionAllow},
		{"@lg-hint/lg_hint", DecisionAllow},
		{"@lg-git/git_log", DecisionAllow},
		{"Reading foo.lua", DecisionAllow},
		{"grep bar", DecisionAllow},
		// File writes MUST go through paint_edit — native writes denied
		{"Editing foo.lua", DecisionDeny},
		{"Writing foo.lua", DecisionDeny},
		{"Creating bar.txt", DecisionDeny},
		{"write_text_file", DecisionDeny},
		// Shell falls through for user approval
		{"Running npm install", DecisionUnknown},
	}
	for _, tc := range cases {
		if got := ModeFilter("cursor", "lg", tc.title); got != tc.want {
			t.Errorf("lg: %q → %v, want %v", tc.title, got, tc.want)
		}
	}
}

func TestModeFilter_AskerMode(t *testing.T) {
	cases := []struct {
		title string
		want  ModeDecision
	}{
		{"Reading foo.lua", DecisionAllow},
		{"grep", DecisionAllow},
		{"glob", DecisionAllow},
		// Asker is strictly read-only — no lg-hint either
		{"@lg-hint/lg_hint", DecisionDeny},
		{"@lg/paint_edit", DecisionDeny},
		{"Running ls", DecisionDeny},
	}
	for _, tc := range cases {
		if got := ModeFilter("cursor", "asker", tc.title); got != tc.want {
			t.Errorf("asker: %q → %v, want %v", tc.title, got, tc.want)
		}
	}
}

func TestModeFilter_UnknownMode(t *testing.T) {
	// Unknown lg mode should fall through rather than over-restrict
	if got := ModeFilter("cursor", "some-custom-mode", "anything"); got != DecisionUnknown {
		t.Errorf("unknown mode should be DecisionUnknown, got %v", got)
	}
}

func TestShouldBlockDirectWrite(t *testing.T) {
	cases := []struct {
		provider, mode string
		want           bool
	}{
		// Cursor in constrained modes: block direct writes
		{"cursor", "lg", true},
		{"cursor", "lg-chat", true},
		{"cursor", "lg-oneshot", true},
		{"cursor", "reviewer", true},
		{"cursor", "suggester", true},
		{"cursor", "asker", true},
		{"cursor", "lg-info", true},
		{"cursor", "lg-plan", true},
		{"cursor", "devlens", true},
		// Cursor fullstack: allow direct writes (unconstrained by design)
		{"cursor", "fullstack", false},
		{"cursor", "kiro_default", false},
		// Non-cursor: never block (kiro/opencode have their own mechanisms)
		{"kiro", "reviewer", false},
		{"opencode", "reviewer", false},
		// Empty logical mode: fall through
		{"cursor", "", false},
	}
	for _, tc := range cases {
		if got := ShouldBlockDirectWrite(tc.provider, tc.mode); got != tc.want {
			t.Errorf("ShouldBlockDirectWrite(%q, %q) = %v, want %v", tc.provider, tc.mode, got, tc.want)
		}
	}
}
