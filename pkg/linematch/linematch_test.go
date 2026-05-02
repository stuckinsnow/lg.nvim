package linematch

import "testing"

func TestFindNearestLine(t *testing.T) {
	lines := []string{
		"func foo() {",       // 0
		"    x := 1",         // 1
		"    y := 2",         // 2
		"}",                  // 3
		"",                   // 4
		"func bar() {",       // 5
		"    x := 1",         // 6 - duplicate of line 1
		"    z := 3",         // 7
		"}",                  // 8
	}

	tests := []struct {
		name     string
		hintLine int
		match    string
		wantLine int
		wantOk   bool
	}{
		{"exact match", 1, "x := 1", 1, true},
		{"shifted down, finds nearest", 3, "x := 1", 1, true},
		{"duplicate, closer to second", 5, "x := 1", 6, true},
		{"duplicate, equidistant prefers first", 3, "x := 1", 1, true}, // dist 2 vs 3
		{"not found", 0, "nothere", 0, false},
		{"unique match far away", 0, "z := 3", 7, true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			line, _, _, ok := FindNearestLine(lines, tt.hintLine, tt.match)
			if ok != tt.wantOk {
				t.Fatalf("ok = %v, want %v", ok, tt.wantOk)
			}
			if ok && line != tt.wantLine {
				t.Fatalf("line = %d, want %d", line, tt.wantLine)
			}
		})
	}
}

func TestFindNearestLineColumns(t *testing.T) {
	lines := []string{"  hello world  "}
	line, col, endCol, ok := FindNearestLine(lines, 0, "hello")
	if !ok || line != 0 || col != 2 || endCol != 7 {
		t.Fatalf("got line=%d col=%d endCol=%d ok=%v, want 0,2,7,true", line, col, endCol, ok)
	}
}
