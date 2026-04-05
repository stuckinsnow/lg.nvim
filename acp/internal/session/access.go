package session

import (
	"path/filepath"
	"strings"
)

// Sensitive filename patterns — blocked regardless of mode.
var sensitivePatterns = []string{
	".env",
	".env.*",
	"*.pem",
	"*.key",
	"*.p12",
	"*.pfx",
	"*.jks",
	"*.keystore",
	"id_rsa",
	"id_ed25519",
	"id_ecdsa",
	"id_dsa",
	"*.secret",
	"secrets.*",
	"credentials",
	".netrc",
	".npmrc",
	".pypirc",
}

// AccessGuard checks whether file access is allowed.
type AccessGuard struct {
	cwd string
}

func NewAccessGuard(cwd string) *AccessGuard {
	return &AccessGuard{cwd: cwd}
}

func (g *AccessGuard) IsOutsideCWD(path string) bool {
	abs, err := filepath.Abs(path)
	if err != nil {
		return true
	}
	rel, err := filepath.Rel(g.cwd, abs)
	if err != nil {
		return true
	}
	return strings.HasPrefix(rel, "..")
}

func isSensitive(path string) bool {
	base := strings.ToLower(filepath.Base(path))
	for _, p := range sensitivePatterns {
		if matched, _ := filepath.Match(p, base); matched {
			return true
		}
	}
	return false
}

// CheckAccess returns "" if allowed, or a denial reason.
func (g *AccessGuard) CheckAccess(path string) string {
	if isSensitive(path) {
		return "blocked: sensitive file"
	}
	if g.IsOutsideCWD(path) {
		return "blocked: outside project directory"
	}
	return ""
}

// ExtractPathFromTitle pulls a file path from permission titles like
// "Reading /foo/bar:1", "Reading listing /foo", "Creating /foo/bar".
// Returns "" if no absolute path can be extracted (relative paths are unreliable).
func ExtractPathFromTitle(title string) string {
	for _, prefix := range []string{"Reading listing ", "Finding ", "Reading ", "Creating ", "Deleting "} {
		if strings.HasPrefix(title, prefix) {
			p := strings.TrimPrefix(title, prefix)
			// "Finding **/init.lua in .dotfiles" → extract the "in <path>" part
			if strings.HasPrefix(prefix, "Finding") {
				if idx := strings.LastIndex(p, " in "); idx >= 0 {
					p = p[idx+4:]
				}
			}
			// Strip trailing :linerange (e.g. ":1", ":1-2", ":100-200")
			if i := strings.LastIndex(p, ":"); i > 0 {
				suffix := p[i+1:]
				isLineRange := true
				for _, c := range suffix {
					if (c < '0' || c > '9') && c != '-' {
						isLineRange = false
						break
					}
				}
				if isLineRange && len(suffix) > 0 {
					p = p[:i]
				}
			}
			// Only trust absolute paths — relative ones can't be verified
			if strings.HasPrefix(p, "/") {
				return p
			}
			return ""
		}
	}
	return ""
}

// isFileOperation returns true if the title looks like a file read/write/find operation.
func isFileOperation(title string) bool {
	for _, prefix := range []string{"Reading ", "Finding ", "Creating ", "Deleting "} {
		if strings.HasPrefix(title, prefix) {
			return true
		}
	}
	return false
}
