// Pristine fork: tests for pristineDataDir. Fork-only file; see CHANGES-FORK.md.

package main

import (
	"path/filepath"
	"testing"
)

func TestPristineDataDir(t *testing.T) {
	cases := map[string]string{
		"":                  "",
		"relative/dir":      "",
		"/":                 "",
		"/a/../b":           "",
		"/a/./b":            "",
		"/a\nb":             "",
		"/Users/x/Caches/e": "/Users/x/Caches/e",
		"/Users/x/Caches/":  "/Users/x/Caches",
	}
	for value, want := range cases {
		t.Setenv("PRISTINE_CACHE_DIR", value)
		if got := pristineDataDir("PRISTINE_CACHE_DIR"); got != want {
			t.Errorf("pristineDataDir(%q) = %q, want %q", value, got, want)
		}
	}
}

func TestMoleCacheRootHonoursOverride(t *testing.T) {
	home := t.TempDir()
	if got, want := moleCacheRoot(home), filepath.Join(home, ".cache", "mole"); got != want {
		t.Fatalf("default root = %q, want %q", got, want)
	}
	dir := filepath.Join(home, "Library", "Caches", "host", "engine")
	t.Setenv("PRISTINE_CACHE_DIR", dir)
	if got := moleCacheRoot(home); got != dir {
		t.Fatalf("override root = %q, want %q", got, dir)
	}
}
