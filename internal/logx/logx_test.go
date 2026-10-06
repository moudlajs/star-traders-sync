package logx

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestFormatThresholdAndRotation(t *testing.T) {
	dir := t.TempDir()
	l := &Logger{File: filepath.Join(dir, "logs", "s.log"), Level: "INFO", MaxBytes: 120, Keep: 2,
		Now: func() time.Time { return time.Date(2026, 10, 6, 12, 0, 0, 0, time.UTC) }}
	l.Log("DEBUG", "x", "hidden")
	l.Log("INFO", "start", "command=%s", "pull")
	got, _ := os.ReadFile(l.File)
	if want := "2026-10-06T12:00:00Z INFO  start          command=pull\n"; string(got) != want {
		t.Fatalf("line = %q, want %q (the script's printf '%%s %%-5s %%-14s %%s')", got, want)
	}
	for i := 0; i < 10; i++ {
		l.Log("WARN", "w", "line %d", i)
	}
	for _, f := range []string{"s.log", "s.log.1", "s.log.2"} {
		if _, err := os.Stat(filepath.Join(dir, "logs", f)); err != nil {
			t.Errorf("%s missing after rotation", f)
		}
	}
	if _, err := os.Stat(filepath.Join(dir, "logs", "s.log.3")); err == nil {
		t.Error("kept more than LOG_KEEP")
	}
	cur, _ := os.ReadFile(l.File)
	if !strings.Contains(string(cur), "line 9") {
		t.Error("the newest line is in the live log")
	}
}
