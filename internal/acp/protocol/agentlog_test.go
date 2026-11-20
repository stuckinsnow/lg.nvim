package protocol

import "testing"

func TestParseAgentError(t *testing.T) {
	cases := []struct {
		line    string
		sid     string
		msg     string
		matched bool
	}{
		{
			line:    `timestamp=2026-11-15T11:15:16.258Z level=ERROR run=69116198 message="stream error" providerID=opencode modelID=big-pickle session.id=ses_abc small=false agent=lg mode=all error.error="AI_APICallError: Free usage limit reached. Subscribe: https://opencode.ai/go"`,
			sid:     "ses_abc",
			msg:     "AI_APICallError: Free usage limit reached. Subscribe: https://opencode.ai/go",
			matched: true,
		},
		{
			line:    `level=ERROR session.id=ses_q error.error="said \"no\""`,
			sid:     "ses_q",
			msg:     `said "no"`,
			matched: true,
		},
		{line: `level=ERROR session.id=ses_t small=true error.error="title failed"`},
		{line: `level=INFO session.id=ses_x message=loop step=0`},
		{line: `level=ERROR message="no session here" error.error=boom`},
		{line: `Error handling request {`},
	}
	for _, c := range cases {
		sid, msg, ok := ParseAgentError(c.line)
		if ok != c.matched || sid != c.sid || msg != c.msg {
			t.Errorf("ParseAgentError(%q) = (%q, %q, %v), want (%q, %q, %v)", c.line, sid, msg, ok, c.sid, c.msg, c.matched)
		}
	}
}
