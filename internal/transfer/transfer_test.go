package transfer

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/moudlajs/star-traders-sync/internal/logx"
)

func TestSnippetsMatchTheScript(t *testing.T) {
	src, err := os.ReadFile("../../bin/star-traders-sync")
	if err != nil {
		t.Fatal(err)
	}
	body := func(fn string) []byte {
		return regexp.MustCompile(`(?ms)^` + fn + `\(\) \{\n.*?^\}\n`).Find(src)
	}
	for _, c := range []struct{ fn, snip, close string }{
		{"snapshot_hub", snapshotHubScript, "    '"},
		{"preserve_excluded_hub", carryHubScript, "    '"},
		{"push_local_to_hub", sweepHubScript, "    '"},
		{"push_local_to_hub", swapHubScript, "        '"},
	} {
		if b := body(c.fn); b == nil || !bytes.Contains(b, []byte("'"+c.snip+c.close)) {
			t.Errorf("a hub-side snippet in %s differs from snippets.go: regenerate it", c.fn)
		}
	}
	for _, one := range []string{stageHubScript, mkdirHubScript} {
		if !bytes.Contains(src, []byte("hub_exec_args '"+one+"'")) {
			t.Errorf("%q is no longer in the script", one)
		}
	}
}

// The two renames are never split, and nothing staged is swept while they run.
func TestAnInterruptWaitsForTheSwap(t *testing.T) {
	var g Guard
	staged := t.TempDir() + "/staged"
	if err := os.Mkdir(staged, 0o755); err != nil {
		t.Fatal(err)
	}
	g.Later(staged)
	var order []string
	_ = g.Swapping(func() error {
		order = append(order, "first rename")
		g.Interrupt(func() { order = append(order, "exit") })
		g.Cleanup() // what an interrupt's exit path runs, mid-swap
		if _, err := os.Stat(staged); err != nil {
			t.Error("staging was swept in the middle of the swap")
		}
		order = append(order, "second rename")
		return nil
	})
	if want := "first rename,second rename,exit"; strings.Join(order, ",") != want {
		t.Fatalf("order %v, want %s", order, want)
	}
	ran := false
	g.Interrupt(func() { ran = true })
	if !ran {
		t.Fatal("outside a swap an interrupt runs at once")
	}
}

// An exiting interrupt removes the staging, so no swap may start afterwards.
func TestNoSwapStartsOnceAnInterruptIsExiting(t *testing.T) {
	var g Guard
	g.Interrupt(func() {})
	called := false
	if err := g.Swapping(func() error { called = true; return nil }); err != ErrClosed || called {
		t.Fatalf("a swap started after the exit began (err=%v, ran=%v)", err, called)
	}
}

func TestAFailedRestoreSaysWhereTheSavesAre(t *testing.T) {
	dir := t.TempDir()
	target, tmp := dir+"/local", dir+"/staged"
	for _, d := range []string{target, tmp} {
		if err := os.Mkdir(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	defer func(r func(string, string) error) { rename = r }(rename)
	calls := 0
	rename = func(a, b string) error {
		calls++
		if calls == 1 {
			return os.Rename(a, b) // target aside
		}
		return errors.New("refused") // neither the staged copy nor the original goes in
	}
	tr := &T{Pid: 42, Guard: &Guard{}}
	f := tr.SwapIntoPlace(tmp, target)
	if f == nil || !strings.Contains(f.Msg, "intact at "+target+".sts-old-42") || strings.Contains(f.Msg, "was restored") {
		t.Fatalf("got %+v", f)
	}
	if _, err := os.Stat(target + ".sts-old-42"); err != nil {
		t.Fatal("the saves are not where the message says")
	}
}

func TestALeftoverParkedGenerationIsKept(t *testing.T) {
	dir := t.TempDir()
	target, tmp, old := dir+"/local", dir+"/staged", dir+"/local.sts-old-42"
	for _, d := range []string{target, tmp, old} {
		if err := os.Mkdir(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(old+"/game_1.db", []byte("only copy"), 0o644); err != nil {
		t.Fatal(err)
	}
	tr := &T{Pid: 42, Guard: &Guard{}, Now: time.Now, Log: &logx.Logger{File: dir + "/log"}}
	if f := tr.SwapIntoPlace(tmp, target); f != nil {
		t.Fatal(f)
	}
	kept, _ := filepath.Glob(old + ".*/game_1.db")
	if len(kept) != 1 {
		t.Fatalf("the leftover's save is gone (found %v)", kept)
	}
	if b, _ := os.ReadFile(kept[0]); string(b) != "only copy" {
		t.Fatal("the leftover's save changed")
	}
}

// A short snapshot stays hidden as .partial-: never listed, counted or pruned.
func TestAnIncompleteSnapshotStaysHidden(t *testing.T) {
	dir := t.TempDir()
	saves := dir + "/local"
	if err := os.Mkdir(saves, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, f := range []string{"core.db", "game_1.db"} {
		if err := os.WriteFile(saves+"/"+f, []byte(f), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	defer func(c func(string, string) error) { copyFileFn = c }(copyFileFn)
	copyFileFn = func(src, dst string) error {
		if strings.HasSuffix(src, "game_1.db") {
			return errors.New("I/O error")
		}
		return copyFile(src, dst)
	}
	tr := &T{Pid: 1, Keep: 3, Now: time.Now, Log: &logx.Logger{File: dir + "/log"}, Guard: &Guard{}}
	if _, f := tr.SnapshotLocal(saves, true); f == nil || f.Code != 63 {
		t.Fatalf("got %v, want a 63 refusal", f)
	}
	if got := listed(dir + "/star-traders-sync-snapshots"); len(got) != 0 {
		t.Fatalf("an incomplete snapshot is listed: %v", got)
	}
	if partial, _ := filepath.Glob(dir + "/star-traders-sync-snapshots/.partial-*"); len(partial) != 1 {
		t.Fatalf("the partial copy is not kept aside: %v", partial)
	}
}
