package cli

import (
	"bytes"
	"os"
	"regexp"
	"testing"

	"github.com/moudlajs/star-traders-sync/internal/fail"
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
