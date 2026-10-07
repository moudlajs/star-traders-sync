package cli

import (
	"bytes"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/moudlajs/star-traders-sync/internal/fail"
	"github.com/moudlajs/star-traders-sync/internal/logx"
)

// A remote hub runs the script's own text, so doctor sends it verbatim.
func TestDoctorSnippetsMatchTheScript(t *testing.T) {
	src, err := os.ReadFile("../../bin/star-traders-sync")
	if err != nil {
		t.Fatal(err)
	}
	body := func(fn string) []byte {
		return regexp.MustCompile(`(?ms)^` + fn + `\(\) \{\n.*?^\}\n`).Find(src)
	}
	for _, c := range []struct{ fn, want string }{
		{"doc_ssh", "probe=\"$(hub_exec_args '" + doctorProbeScript + "' \"$CFG_HUB_PATH\""},
		{"doc_ssh", "hub_exec_args '" + doctorMkdirScript + "' \"$CFG_HUB_PATH\""},
		{"hub_is_busy", "hub_exec_args '" + doctorBusyScript + "' \"$lock\""},
	} {
		if b := body(c.fn); b == nil || !bytes.Contains(b, []byte(c.want)) {
			t.Errorf("a hub-side snippet in %s differs from doctor.go", c.fn)
		}
	}
}

func TestRefusalLines(t *testing.T) {
	got := refusalLines(&fail.Failure{Msg: "x is wrong"})
	if len(got) != 1 || got[0] != "x is wrong" {
		t.Errorf("got %q", got)
	}
}

// --fix never clears a local lock while a run holds the flock, however
// stale the script-visible lock looks: the run may be between its stale
// check and its own mkdir.
func TestDoctorLeavesAFlockedLock(t *testing.T) {
	state := t.TempDir()
	fl, err := os.OpenFile(filepath.Join(state, "local.lock.flock"), os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	defer fl.Close()
	if err := syscall.Flock(int(fl.Fd()), syscall.LOCK_EX); err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(state, "local.lock.d")
	if err := os.Mkdir(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-time.Hour)
	_ = os.Chtimes(dir, old, old)
	_ = os.WriteFile(filepath.Join(state, "local.lock"), []byte("99999\n"), 0o644)

	var out bytes.Buffer
	d := &doctor{out: &out, fix: true, p: paths{stateDir: state, configFile: filepath.Join(state, "cfg", "config"),
		logFile: filepath.Join(state, "logs", "log")}, log: &logx.Logger{File: filepath.Join(state, "log")}}
	d.stateDirs()
	if _, err := os.Stat(dir); err != nil {
		t.Errorf("cleared a lock another run holds:\n%s", out.String())
	}
	if !strings.Contains(out.String(), "another sts is running right now (pid 99999)") {
		t.Errorf("did not say why:\n%s", out.String())
	}
}
