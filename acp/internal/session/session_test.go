package session

import "testing"

func TestSliceLines(t *testing.T) {
	content := "a\nb\nc\n"
	cases := []struct {
		line, limit int
		want        string
	}{
		{0, 0, content},
		{1, 0, content},
		{1, 2001, content},
		{2, 0, "b\nc\n"},
		{2, 1, "b\n"},
		{9, 1, ""},
	}
	for _, c := range cases {
		if got := sliceLines(content, c.line, c.limit); got != c.want {
			t.Errorf("sliceLines(line=%d, limit=%d) = %q, want %q", c.line, c.limit, got, c.want)
		}
	}
}
