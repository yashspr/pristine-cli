// Pristine fork: relocatable data directories (see lib/pristine/paths.sh).
// Fork-only file; see CHANGES-FORK.md.

package main

import (
	"os"
	"path/filepath"
	"strings"
)

// pristineDataDir returns the directory named by env (PRISTINE_CONFIG_DIR or
// PRISTINE_CACHE_DIR) when it holds a clean absolute path, or "" so the caller
// falls back to the upstream location. The shell side applies the same rule.
func pristineDataDir(env string) string {
	value := strings.TrimSuffix(os.Getenv(env), "/")
	if value == "" || !filepath.IsAbs(value) || filepath.Clean(value) != value {
		return ""
	}
	if strings.ContainsFunc(value, func(r rune) bool { return r < 0x20 || r == 0x7f }) {
		return ""
	}
	return value
}
