package transfer

import (
	"bytes"
	"os"
	"regexp"
	"strings"
	"testing"
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

// An interrupt during the swap waits for it: the two renames are never
// split, and nothing staged is swept while they run.
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
