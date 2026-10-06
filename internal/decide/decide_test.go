package decide

import (
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"testing"
)

// The script's decide() and effective_decision(), sourced from the script
// itself and run by bash, are the reference.
func bashFunctions(t *testing.T) string {
	t.Helper()
	src, err := os.ReadFile("../../bin/star-traders-sync")
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, name := range []string{"decide", "effective_decision"} {
		m := regexp.MustCompile(`(?ms)^` + name + `\(\) \{\n.*?^\}\n`).Find(src)
		if m == nil {
			t.Fatalf("%s() not found in the script", name)
		}
		out = append(out, string(m))
	}
	return strings.Join(out, "\n")
}

// ansiC quotes s for bash as $'...', where \t is a real tab (Go's %q
// makes "\t", which bash double quotes keep as a backslash and a t).
func ansiC(s string) string {
	return "$'" + strings.NewReplacer(`\`, `\\`, "'", `\'`, "\t", `\t`).Replace(s) + "'"
}

func stateLine(st State) string {
	if st.FirstRun {
		return "FIRSTRUN"
	}
	return strings.Join([]string{st.Direction, st.Epoch, st.LocalFP, st.HubFP}, "\t")
}

// Every reachable combination: each side's fingerprint is one of a few
// values, each count zero or not, and the state either a first run or a
// record whose fingerprints each match a side or not.
func TestEveryCombinationMatchesTheScript(t *testing.T) {
	fns := bashFunctions(t)
	fps := []string{"aaa", "bbb", "empty"}
	counts := []int{0, 3}
	states := []State{{FirstRun: true}}
	for _, sl := range append(fps, "ccc") {
		for _, sh := range append(fps, "ddd") {
			states = append(states, State{Direction: "push", Epoch: "1790000000", LocalFP: sl, HubFP: sh})
		}
	}
	var script strings.Builder
	script.WriteString(fns + "\n")
	type row struct {
		l, h Side
		st   State
	}
	var rows []row
	for _, lfp := range fps {
		for _, hfp := range fps {
			for _, lc := range counts {
				for _, hc := range counts {
					for _, st := range states {
						r := row{Side{lfp, lc}, Side{hfp, hc}, st}
						rows = append(rows, r)
						sq := ansiC(stateLine(st))
						fmt.Fprintf(&script, "printf '%%s %%s\\n' \"$(decide %q %q %d %d %s)\" \"$(effective_decision %q %q %d %d %s)\"\n",
							lfp, hfp, lc, hc, sq, lfp, hfp, lc, hc, sq)
					}
				}
			}
		}
	}
	out, err := exec.Command("/bin/bash", "-c", script.String()).Output()
	if err != nil {
		t.Fatalf("bash: %v", err)
	}
	lines := strings.Split(strings.TrimSuffix(string(out), "\n"), "\n")
	if len(lines) != len(rows) {
		t.Fatalf("bash gave %d answers for %d rows", len(lines), len(rows))
	}
	seen := map[Decision]bool{}
	for i, r := range rows {
		got := fmt.Sprintf("%s %s", Decide(r.l, r.h, r.st), Effective(r.l, r.h, r.st))
		if got != lines[i] {
			t.Errorf("local=%v hub=%v state=%q: go %q, bash %q", r.l, r.h, stateLine(r.st), got, lines[i])
		}
		seen[Effective(r.l, r.h, r.st)] = true
	}
	for _, d := range []Decision{InSync, HubOnly, LocalOnly, BothChanged, FirstRunConflict, FirstSeed, HubEmpty, DivergedState, LocalEmptied} {
		if !seen[d] {
			t.Errorf("no combination reached %s: the table is missing a case", d)
		}
	}
	t.Logf("%d combinations agree", len(rows))
}
