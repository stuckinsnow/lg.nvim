// Package linematch provides content-based line finding that handles line shifts.
package linematch

import "strings"

// FindNearestLine finds the line closest to hintLine that contains match.
// lines is 0-indexed file content, hintLine is 0-indexed.
// Returns the 0-indexed line number, column start, column end, and ok.
func FindNearestLine(lines []string, hintLine int, match string) (line, col, endCol int, ok bool) {
	best := -1
	bestDist := int(^uint(0) >> 1)
	for i, l := range lines {
		if strings.Contains(l, match) {
			dist := hintLine - i
			if dist < 0 {
				dist = -dist
			}
			if dist < bestDist {
				bestDist = dist
				best = i
			}
		}
	}
	if best < 0 {
		return 0, 0, 0, false
	}
	idx := strings.Index(lines[best], match)
	return best, idx, idx + len(match), true
}
