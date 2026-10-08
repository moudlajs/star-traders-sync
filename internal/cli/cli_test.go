package cli

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
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

func runMain(args ...string) (int, string, string) {
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
		code, _, errOut := runMain(c.args...)
		if code != c.code || !bytes.Contains([]byte(errOut), []byte(c.err)) {
			t.Errorf("%v: got %d %q, want %d containing %q", c.args, code, errOut, c.code, c.err)
		}
	}
	if code, out, _ := runMain("--version"); code != 0 || out != "star-traders-sync "+Version+"\n" {
		t.Errorf("--version: %d %q", code, out)
	}
}

// A refused status still releases the local lock it took in prepare.
func TestARefusedRunLeavesNoLocalLock(t *testing.T) {
	home := t.TempDir()
	cfgDir := filepath.Join(home, ".config", "star-traders-sync")
	if err := os.MkdirAll(cfgDir, 0o755); err != nil {
		t.Fatal(err)
	}
	cfg := "HUB_HOST=h\nHUB_USER=u\nHUB_PATH=" + home + "/hub\nLOCAL_SAVE_PATH=" + home + "/missing\n" +
		"STEAM_APPID=1\nGAME_PROCESS_NAME=g\nBACKUP_VOLUME=/V\nBACKUP_DEST=/V/b\n"
	if err := os.WriteFile(filepath.Join(cfgDir, "config"), []byte(cfg), 0o644); err != nil {
		t.Fatal(err)
	}
	var out, errb bytes.Buffer
	env := Env{Stdout: &out, Stderr: &errb,
		Getenv:   func(k string) string { return map[string]string{"HOME": home}[k] },
		Geteuid:  func() int { return 501 },
		LookPath: func(string) (string, error) { return "/usr/bin/true", nil }}
	if code := Main([]string{"status"}, env); code != 13 {
		t.Fatalf("exit %d, want 13 (no save folder): %s", code, errb.String())
	}
	state := filepath.Join(home, ".local", "state", "star-traders-sync")
	for _, f := range []string{"local.lock", "local.lock.d"} {
		if _, err := os.Stat(filepath.Join(state, f)); err == nil {
			t.Errorf("%s left behind", f)
		}
	}
}
