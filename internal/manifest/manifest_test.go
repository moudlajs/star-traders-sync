package manifest

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// The script's own MANIFEST_SCRIPT, run by bash on the same tree, is the
// reference: the Go manifest must be byte-identical to it.
func bashManifest(t *testing.T, dir string, exclude []string) string {
	t.Helper()
	src, err := os.ReadFile("../../bin/star-traders-sync")
	if err != nil {
		t.Fatal(err)
	}
	m := regexp.MustCompile(`(?s)readonly MANIFEST_SCRIPT='\n(.*?)\n'\n`).FindSubmatch(src)
	if m == nil {
		t.Fatal("MANIFEST_SCRIPT not found in the script")
	}
	args := append([]string{"-c", string(m[1]), "sts", dir, SnapDirName, LockDirName}, exclude...)
	out, err := exec.Command("/bin/bash", args...).Output()
	if err != nil {
		t.Fatalf("bash manifest: %v", err)
	}
	// $(...) in the script drops trailing newlines; Text() does too.
	for len(out) > 0 && out[len(out)-1] == '\n' {
		out = out[:len(out)-1]
	}
	return string(out)
}

func write(t *testing.T, root, rel, body string) {
	t.Helper()
	p := filepath.Join(root, rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestByteIdenticalToTheScript(t *testing.T) {
	dir := t.TempDir()
	for rel, body := range map[string]string{
		"core.db": "core", "game_1.db": "g1", "map_1.db": "m1", "template_1.json": "{}",
		"empty.db": "", "a b.db": "space", "a/b.db": "slash sorts after space",
		".hidden": "dot", "sub/deep/x.db": "deep", "ünï.db": "utf-8",
		// excluded: data.db anywhere by name; *.bak by name and any
		// directory matching it, at any depth (find's -path with fnmatch).
		"data.db": "static", "sub/data.db": "static too",
		"old.bak": "b", "keep/x.bak/inner.db": "under a *.bak dir, deep",
		"x.bak/top.db":                  "under a top-level *.bak dir",
		SnapDirName + "/2026/game_1.db": "snapshot", LockDirName + "/owner": "lock",
		"nested/" + SnapDirName + "/kept.db": "only the top-level snapshot dir is pruned",
	} {
		write(t, dir, rel, body)
	}
	if err := os.Symlink("game_1.db", filepath.Join(dir, "link.db")); err != nil {
		t.Fatal(err)
	}
	exclude := []string{"data.db", "*.bak", "steam_autocloud.vdf"}

	got, err := Build(dir, exclude)
	if err != nil {
		t.Fatal(err)
	}
	want := bashManifest(t, dir, exclude)
	if got.Text() != want {
		t.Fatalf("manifest differs from the script's\n--- bash\n%s\n--- go\n%s", want, got.Text())
	}
	if got.Count() < 10 {
		t.Fatalf("suspiciously small manifest (%d): the fixture did not land", got.Count())
	}
}

func TestUnhashableFilesAreReportedInPlace(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads everything")
	}
	dir := t.TempDir()
	write(t, dir, "a.db", "a")
	write(t, dir, "b.db", "b")
	write(t, dir, "c.db", "c")
	if err := os.Chmod(filepath.Join(dir, "b.db"), 0); err != nil {
		t.Fatal(err)
	}
	defer os.Chmod(filepath.Join(dir, "b.db"), 0o644)

	got, _ := Build(dir, nil)
	if len(got.Unhashable) != 1 || got.Unhashable[0] != "./b.db" {
		t.Fatalf("unhashable = %v", got.Unhashable)
	}
	if want := bashManifest(t, dir, nil); got.Text() != want {
		t.Fatalf("differs from the script\n--- bash\n%s\n--- go\n%s", want, got.Text())
	}
}

// fnmatch's * matches a newline; without (?s) Go's . would not, and a file
// named "x\n.bak" would slip past an exclude of *.bak.
func TestAStarMatchesANewlineToo(t *testing.T) {
	dir := t.TempDir()
	write(t, dir, "x\n.bak", "excluded")
	write(t, dir, "keep.db", "kept")
	got, _ := Build(dir, []string{"*.bak"})
	if got.Count() != 1 || len(got.Lines) != 1 || !strings.HasSuffix(got.Lines[0], "./keep.db") {
		t.Fatalf("manifest = %q", got.Text())
	}
}

// Deliberately stricter than the script: nothing unreadable vanishes.
func TestNothingUnreadableIsSkippedSilently(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads everything")
	}
	dir := t.TempDir()
	write(t, dir, "game_1.db", "g")
	write(t, dir, "sub/keep.db", "under an unreadable dir")
	sub := filepath.Join(dir, "sub")
	if err := os.Chmod(sub, 0); err != nil {
		t.Fatal(err)
	}
	defer os.Chmod(sub, 0o755)
	got, err := Build(dir, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Unhashable) != 1 || got.Unhashable[0] != "./sub/" {
		t.Fatalf("an unreadable subdirectory must be unhashable, got %q", got.Text())
	}

	root := t.TempDir()
	write(t, root, "game_1.db", "g")
	if err := os.Chmod(root, 0); err != nil {
		t.Fatal(err)
	}
	defer os.Chmod(root, 0o755)
	if m, err := Build(root, nil); err == nil {
		t.Fatalf("an unreadable dir must be an error, not %q (%s)", m.Text(), m.Fingerprint())
	}
}

func TestFingerprint(t *testing.T) {
	empty := t.TempDir()
	m, _ := Build(empty, nil)
	if m.Fingerprint() != "empty" || m.Count() != 0 {
		t.Fatalf("an empty dir is %q/%d", m.Fingerprint(), m.Count())
	}
	missing, _ := Build(filepath.Join(empty, "nope"), nil)
	if missing.Fingerprint() != "empty" {
		t.Fatal("a missing dir is empty, as the script's cd || exit 0")
	}
	dir := t.TempDir()
	write(t, dir, "core.db", "12288 bytes either way")
	a, _ := Build(dir, nil)
	write(t, dir, "core.db", "12288 bytes either wax")
	b, _ := Build(dir, nil)
	if a.Fingerprint() == b.Fingerprint() {
		t.Fatal("same size, different contents: the fingerprints must differ")
	}
	// The script: printf '%s' "$m" | shasum -a 256.
	out, err := exec.Command("/bin/bash", "-c", `printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1`, "x", b.Text()).Output()
	if err != nil {
		t.Fatal(err)
	}
	if string(out[:64]) != b.Fingerprint() {
		t.Fatalf("fingerprint %s, the script's %s", b.Fingerprint(), out[:64])
	}
}
