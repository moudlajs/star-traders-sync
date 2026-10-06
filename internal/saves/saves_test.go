package saves

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/moudlajs/star-traders-sync/internal/exitcode"
	"github.com/moudlajs/star-traders-sync/internal/logx"
)

func logger(t *testing.T) *logx.Logger {
	return &logx.Logger{File: filepath.Join(t.TempDir(), "log"), Level: "DEBUG"}
}

// status reports staging directories and never removes one, however old;
// a sync sweeps only the stale ones.
func TestStatusNeverSweepsAndASyncSweepsOnlyStale(t *testing.T) {
	root := t.TempDir()
	saves := filepath.Join(root, "local")
	young, old := filepath.Join(root, ".sts-incoming-1"), filepath.Join(root, ".sts-incoming-2")
	for _, d := range []string{saves, young, old} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	ago := time.Now().Add(-time.Hour)
	os.Chtimes(old, ago, ago)

	if f := RecoverOrphans(saves, false, time.Now(), logger(t)); f != nil {
		t.Fatal(f)
	}
	for _, d := range []string{young, old} {
		if _, err := os.Stat(d); err != nil {
			t.Fatalf("status removed %s", d)
		}
	}
	if f := RecoverOrphans(saves, true, time.Now(), logger(t)); f != nil {
		t.Fatal(f)
	}
	if _, err := os.Stat(young); err != nil {
		t.Fatal("a sync removed a recent staging directory")
	}
	if _, err := os.Stat(old); err == nil {
		t.Fatal("a sync left a stale staging directory")
	}
}

func TestAnInterruptedSwapRefuses(t *testing.T) {
	root := t.TempDir()
	saves := filepath.Join(root, "sav[e]s")                      // glob characters stay literal
	if err := os.Mkdir(saves+".sts-old-42", 0o755); err != nil { // the saves, parked
		t.Fatal(err)
	}
	f := RecoverOrphans(saves, false, time.Now(), logger(t))
	if f == nil || f.Code != exitcode.LocalSaveBad || !strings.Contains(strings.Join(f.Lines, "\n"), "mv "+saves+".sts-old-42 "+saves) {
		t.Fatalf("got %+v", f)
	}
}
