package exitcode

import (
	"os"
	"regexp"
	"strconv"
	"testing"
)

// The bash script is the reference until the cutover (#26): every code it
// defines must exist here with the same number, and nothing extra.
func TestMatchesTheBashScript(t *testing.T) {
	src, err := os.ReadFile("../../bin/star-traders-sync")
	if err != nil {
		t.Fatal(err)
	}
	re := regexp.MustCompile(`(?m)^readonly (EX_[A-Z_]+)=([0-9]+)`)
	found := re.FindAllStringSubmatch(string(src), -1)
	if len(found) < 30 {
		t.Fatalf("found only %d codes in the script: the pattern no longer matches", len(found))
	}
	seen := map[string]bool{}
	for _, m := range found {
		n, _ := strconv.Atoi(m[2])
		got, ok := ByScriptName[m[1]]
		if !ok {
			t.Errorf("%s=%d is in the script but not here", m[1], n)
			continue
		}
		if int(got) != n {
			t.Errorf("%s: script says %d, Go says %d", m[1], n, got)
		}
		seen[m[1]] = true
	}
	for name := range ByScriptName {
		if !seen[name] {
			t.Errorf("%s is here but not in the script", name)
		}
	}
}
