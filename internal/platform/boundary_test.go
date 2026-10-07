package platform

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Nothing outside this package names a macOS command, path or unix-only
// syscall: that is what makes a port a new file here rather than edits
// everywhere (#24). Comments and tests are not code that runs, so they may.
func TestNoPlatformCodeOutside(t *testing.T) {
	banned := []string{`"pgrep"`, `"scutil"`, `"launchctl"`, `"diskutil"`, `"open"`, `"hostname"`,
		"/Applications/", "Library/", "/Volumes", "xcode-select", "steam://",
		"syscall.Flock", "syscall.Kill", "syscall.Stat_t", "syscall.Access", "SIGHUP", "SIGPIPE", `"/bin/bash"`}
	for _, root := range []string{"../../internal", "../../cmd"} {
		err := filepath.WalkDir(root, func(p string, d os.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if d.IsDir() && d.Name() == "platform" {
				return filepath.SkipDir
			}
			if d.IsDir() || !strings.HasSuffix(p, ".go") || strings.HasSuffix(p, "_test.go") {
				return nil
			}
			b, err := os.ReadFile(p)
			if err != nil {
				return err
			}
			for i, line := range strings.Split(string(b), "\n") {
				code := line
				if strings.HasPrefix(strings.TrimSpace(code), "//") {
					continue
				}
				if i := strings.Index(code, " // "); i >= 0 {
					code = code[:i]
				}
				{
					for _, w := range banned {
						if strings.Contains(code, w) {
							t.Errorf("%s:%d names %s outside internal/platform", p, i+1, w)
						}
					}
				}
			}
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
	}
}
