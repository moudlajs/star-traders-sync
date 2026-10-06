package state

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/moudlajs/star-traders-sync/internal/decide"
)

func scriptFunc(t *testing.T, name string) string {
	t.Helper()
	src, err := os.ReadFile("../../bin/star-traders-sync")
	if err != nil {
		t.Fatal(err)
	}
	m := regexp.MustCompile(`(?ms)^` + name + `\(\) \{\n.*?^\}\n`).Find(src)
	if m == nil {
		t.Fatalf("%s() not found in the script", name)
	}
	return string(m)
}

// The script's state_read on the same file, as the tuple decide() takes.
func bashRead(t *testing.T, path, host, hubPath string) string {
	t.Helper()
	sh := scriptFunc(t, "state_read") + `
STATE_FILE="$1"; CFG_HUB_HOST="$2"; CFG_HUB_PATH="$3"; state_read`
	out, err := exec.Command("/bin/bash", "-c", sh, "x", path, host, hubPath).Output()
	if err != nil {
		t.Fatalf("bash state_read: %v", err)
	}
	// The script captures it with $(...), which drops print's newline.
	return strings.TrimRight(string(out), "\n")
}

func line(st decide.State) string {
	if st.FirstRun {
		return "FIRSTRUN"
	}
	return strings.Join([]string{st.Direction, st.Epoch, st.LocalFP, st.HubFP}, "\t")
}

func TestReadAgreesWithTheScript(t *testing.T) {
	dir := t.TempDir()
	good := `{"version": 2, "direction": "push", "timestamp": "2026-10-06T12:00:00Z", "epoch": 1790000000,
 "local_fingerprint": "aaa", "hub_fingerprint": "bbb", "hub_host": "hub", "hub_path": "/h"}`
	for name, body := range map[string]string{
		"good":              good,
		"another hub host":  strings.Replace(good, `"hub_host": "hub"`, `"hub_host": "other"`, 1),
		"another hub path":  strings.Replace(good, `"/h"`, `"/elsewhere"`, 1),
		"version 1":         strings.Replace(good, `"version": 2`, `"version": 1`, 1),
		"version as string": strings.Replace(good, `"version": 2`, `"version": "2"`, 1),
		"no direction":      strings.Replace(good, `"direction": "push", `, ``, 1),
		"not json":          "{nope",
		"empty":             "",
		"a list":            "[]",
	} {
		p := filepath.Join(dir, strings.ReplaceAll(name, " ", "-")+".json")
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		got := line(Read(p, "hub", "/h"))
		if want := bashRead(t, p, "hub", "/h"); got != want {
			t.Errorf("%s: go %q, script %q", name, got, want)
		}
	}
	if got := line(Read(filepath.Join(dir, "missing.json"), "hub", "/h")); got != "FIRSTRUN" {
		t.Errorf("no file: %q", got)
	}
}

// What Go writes, the script reads back; and it is the script's bytes.
func TestWriteIsTheScriptsFormat(t *testing.T) {
	dir := t.TempDir()
	at := time.Date(2026, 10, 6, 12, 0, 0, 0, time.UTC)
	p := filepath.Join(dir, "sub", "last-sync.json")
	if err := Write(p, "pull", "aaa", "bbb", "hub", "/h", at); err != nil {
		t.Fatal(err)
	}
	if got, want := bashRead(t, p, "hub", "/h"), "pull\t1791288000\taaa\tbbb"; got != want {
		t.Fatalf("the script reads %q, want %q", got, want)
	}
	if _, err := os.Stat(p + ".tmp"); err == nil {
		t.Fatal("temp file left behind")
	}

	// state_write's own output, with its clock pinned, for a byte compare.
	sh := scriptFunc(t, "state_write") + `
STATE_FILE="$1"; STATE_DIR="$(dirname "$1")"; CFG_HUB_HOST=hub; CFG_HUB_PATH=/h
iso_now() { printf '2026-10-06T12:00:00Z'; }
log() { :; }
state_write pull aaa bbb`
	ref := filepath.Join(dir, "ref", "last-sync.json")
	cmd := exec.Command("/bin/bash", "-c", sh, "x", ref)
	cmd.Env = append(os.Environ(), "PYTHONHASHSEED=0")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("bash state_write: %v %s", err, out)
	}
	refBytes, _ := os.ReadFile(ref)
	goBytes, _ := os.ReadFile(p)
	// The script stamps epoch from the real clock: compare all but that.
	epoch := regexp.MustCompile(`"epoch": [0-9]+`)
	if epoch.ReplaceAllString(string(refBytes), `"epoch": N`) != epoch.ReplaceAllString(string(goBytes), `"epoch": N`) {
		t.Fatalf("not the script's bytes\n--- script\n%s--- go\n%s", refBytes, goBytes)
	}
}
