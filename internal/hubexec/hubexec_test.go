package hubexec

import (
	"os/exec"
	"testing"
)

// Quote must read back as the same single word in a shell, whatever it
// holds - it is what keeps a config value from becoming code on the hub.
func TestQuoteRoundTrips(t *testing.T) {
	for _, s := range []string{"", "plain", "a b", "it's", "''", "$(rm -rf /)", "`x`", "a\nb", `back\slash`, "%s", "*", `"dq"`} {
		out, err := exec.Command("/bin/sh", "-c", "printf '%s' "+Quote(s)).Output()
		if err != nil || string(out) != s {
			t.Errorf("%q came back as %q (%v)", s, out, err)
		}
	}
}

func TestLocalRunsWithPositionalArgs(t *testing.T) {
	out, err := Local{}.Run(`printf '%s|%s' "$1" "$2"`, "a b", "it's")
	if err != nil || out != "a b|it's" {
		t.Fatalf("%q %v", out, err)
	}
}
