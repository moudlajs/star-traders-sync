package hub

import (
	"bytes"
	"os"
	"regexp"
	"testing"
)

func TestSnippetsMatchTheScript(t *testing.T) {
	src, err := os.ReadFile("../../bin/star-traders-sync")
	if err != nil {
		t.Fatal(err)
	}
	if m := regexp.MustCompile(`(?s)readonly MANIFEST_SCRIPT='\n(.*?)\n'\n`).FindSubmatch(src); m == nil || string(m[1]) != manifestScript {
		t.Error("MANIFEST_SCRIPT differs from snippets.go: regenerate it")
	}
	for fn, snip := range map[string]string{"newest_mtime_hub": newestScript, "check_hub_path": checkPathScript} {
		body := regexp.MustCompile(`(?ms)^` + fn + `\(\) \{\n.*?^\}\n`).Find(src)
		if body == nil || !bytes.Contains(body, []byte("'"+snip+"    '")) {
			t.Errorf("%s's hub-side snippet differs from snippets.go: regenerate it", fn)
		}
	}
	if !bytes.Contains(src, []byte("hub_exec_args '"+lockInfoScript+"'")) {
		t.Error("status's lock probe differs from snippets.go: regenerate it")
	}
}
