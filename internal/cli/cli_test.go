package cli

import (
	"bytes"
	"errors"
	"os"
	"regexp"
	"testing"
)

func script(t *testing.T) string {
	t.Helper()
	b, err := os.ReadFile("../../bin/star-traders-sync")
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// A release bump has to change both while both exist.
func TestVersionMatchesTheBashScript(t *testing.T) {
	m := regexp.MustCompile(`(?m)^readonly STS_VERSION="([^"]+)"`).FindStringSubmatch(script(t))
	if m == nil || m[1] != Version {
		t.Fatalf("bin/star-traders-sync STS_VERSION=%v, Go Version=%s", m, Version)
	}
}

// usage.go is generated from the heredoc. Regenerate after changing it:
//
//	python3 -c 'import json,re;s=open("bin/star-traders-sync").read();t=re.search(r"^usage\(\) \{\ncat <<USAGE_EOF\n(.*?)^USAGE_EOF\n",s,re.S|re.M).group(1);print(json.dumps(t))'
func TestUsageMatchesTheBashScript(t *testing.T) {
	m := regexp.MustCompile(`(?ms)^usage\(\) \{\ncat <<USAGE_EOF\n(.*?)^USAGE_EOF\n`).FindStringSubmatch(script(t))
	if m == nil {
		t.Fatal("usage heredoc not found in the script")
	}
	if m[1] != usageTemplate {
		t.Fatal("internal/cli/usage.go is out of date with the script's --help text: regenerate it")
	}
}

func run(args ...string) (int, string, string) {
	var out, errb bytes.Buffer
	env := Env{Stdout: &out, Stderr: &errb,
		Getenv:   func(k string) string { return map[string]string{"HOME": "/nonexistent-home"}[k] },
		Geteuid:  func() int { return 501 },
		LookPath: func(string) (string, error) { return "", errors.New("not found") }}
	code := Main(args, env)
	return code, out.String(), errb.String()
}

func TestArgumentRefusals(t *testing.T) {
	cases := []struct {
		args []string
		code int
		err  string
	}{
		{nil, 2, "USAGE"},
		{[]string{"pull", "push"}, 2, "more than one command given: pull and push"},
		{[]string{"pull", "--force=local"}, 2, `--force=local makes no sense for "pull"`},
		{[]string{"push", "--force=hub"}, 2, `--force=hub makes no sense for "push"`},
		{[]string{"push", "--force=both"}, 2, `--force takes exactly "local" or "hub", got "both"`},
		{[]string{"push", "--force"}, 2, "--force needs a value"},
		{[]string{"status", "--fix"}, 2, `--fix only applies to "doctor"`},
		{[]string{"status", "--expect-decision=HUB_ONLY"}, 2, `--expect-decision only applies`},
		{[]string{"pull", "--expect-decision=hub"}, 2, `takes a decision name such as HUB_ONLY, got "hub"`},
		{[]string{"pull", "--json"}, 2, `--json only applies`},
		{[]string{"restore", "a", "b"}, 2, `unknown argument "b"`},
		{[]string{"restore", "--json", "a"}, 2, `--json only applies`},
		{[]string{"restore", "--dry-run"}, 2, `"restore" takes only the name`},
		{[]string{"bogus"}, 2, `unknown argument "bogus"`},
		{[]string{"status"}, 17, "required tools not on PATH: rsync ssh"},
	}
	for _, c := range cases {
		code, _, errOut := run(c.args...)
		if code != c.code || !bytes.Contains([]byte(errOut), []byte(c.err)) {
			t.Errorf("%v: got %d %q, want %d containing %q", c.args, code, errOut, c.code, c.err)
		}
	}
	if code, out, _ := run("--version"); code != 0 || out != "star-traders-sync "+Version+"\n" {
		t.Errorf("--version: %d %q", code, out)
	}
}
