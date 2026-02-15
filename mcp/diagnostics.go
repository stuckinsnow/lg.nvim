package main

import (
	"encoding/json"
	"fmt"
	"strings"
)

type diagnostic struct {
	File     string `json:"file"`
	Line     int    `json:"line"`
	Col      int    `json:"col"`
	Severity string `json:"severity"`
	Message  string `json:"message"`
	Source   string `json:"source"`
}

func getDiagnostics(severity int) ([]diagnostic, error) {
	resp, err := sendToNeovim(map[string]any{"method": "get_diagnostics", "severity": severity})
	if err != nil {
		return nil, err
	}
	var diags []diagnostic
	if err := json.Unmarshal(resp, &diags); err != nil {
		return nil, err
	}
	return diags, nil
}

func formatDiagnostics(diags []diagnostic) string {
	if len(diags) == 0 {
		return "No diagnostics found."
	}
	grouped := map[string][]diagnostic{}
	var order []string
	for _, d := range diags {
		if _, ok := grouped[d.File]; !ok {
			order = append(order, d.File)
		}
		grouped[d.File] = append(grouped[d.File], d)
	}
	var sb strings.Builder
	for _, file := range order {
		fmt.Fprintf(&sb, "### %s\n", file)
		for _, d := range grouped[file] {
			src := ""
			if d.Source != "" {
				src = " [" + d.Source + "]"
			}
			fmt.Fprintf(&sb, "- L%d:%d %s: %s%s\n", d.Line, d.Col, d.Severity, d.Message, src)
		}
		sb.WriteString("\n")
	}
	return sb.String()
}
