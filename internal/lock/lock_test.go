package lock

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/moudlajs/star-traders-sync/internal/exitcode"
	"github.com/moudlajs/star-traders-sync/internal/fail"
	"github.com/moudlajs/star-traders-sync/internal/hubexec"
	"github.com/moudlajs/star-traders-sync/internal/logx"
)

func TestSnippetsMatchTheScript(t *testing.T) {
	src, err := os.ReadFile("../../bin/star-traders-sync")
	if err != nil {
		t.Fatal(err)
	}
	for fn, snip := range map[string]string{
		"acquire_hub_lock": acquireScript, "clear_stale_hub_lock": clearScript, "release_hub_lock": releaseScript,
	} {
		body := regexp.MustCompile(`(?ms)^` + fn + `\(\) \{\n.*?^\}\n`).Find(src)
		if body == nil || !bytes.Contains(body, []byte("'"+snip+"    '")) {
			t.Errorf("%s's hub-side snippet differs from snippets.go: regenerate it", fn)
		}
	}
}

type fixture struct {
	t      *testing.T
	root   string
	stderr bytes.Buffer
	n      int
}

func newFixture(t *testing.T) *fixture {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "hub"), 0o755); err != nil {
		t.Fatal(err)
	}
	return &fixture{t: t, root: root}
}

// hub is one run on one machine (id); every call is a fresh run.
func (f *fixture) hub(id string) *Hub {
	f.n++
	return &Hub{Exec: hubexec.Local{}, HubPath: filepath.Join(f.root, "hub"), HubHost: "hubhost", HubUser: "me",
		TTL: 60, HostName: "mac", StableID: id, Pid: 1000 + f.n, Nonce: fmt.Sprintf("mac-%d-run%d", 1000+f.n, f.n),
		Now: time.Now, Log: &logx.Logger{File: filepath.Join(f.root, "log"), Level: "DEBUG"}, Stderr: &f.stderr}
}

func (f *fixture) lock() string { return filepath.Join(f.root, DirName) }

// writeOwner leaves a lock as a run would have: host, pid, iso, epoch,
// nonce, stable id.
func (f *fixture) writeOwner(lines ...string) {
	f.t.Helper()
	if err := os.MkdirAll(f.lock(), 0o755); err != nil {
		f.t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(f.lock(), "owner"), []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		f.t.Fatal(err)
	}
}

func old(f *fixture, p string) {
	f.t.Helper()
	ago := time.Now().Add(-2 * time.Hour)
	if err := os.Chtimes(p, ago, ago); err != nil {
		f.t.Fatal(err)
	}
}

func wantRefusal(t *testing.T, got *fail.Failure, code exitcode.Code, text string) {
	t.Helper()
	if got == nil {
		t.Fatalf("acquired; want a %d refusal", code)
	}
	all := got.Msg + strings.Join(got.Lines, "\n")
	if got.Code != code || !strings.Contains(all, text) {
		t.Fatalf("got %d %q, want %d containing %q", got.Code, all, code, text)
	}
}

func exists(p string) bool { _, err := os.Stat(p); return err == nil }

func TestAcquireAndRelease(t *testing.T) {
	f := newFixture(t)
	h := f.hub("A")
	if r := h.Acquire(); r != nil {
		t.Fatal(r)
	}
	if !exists(filepath.Join(f.lock(), "owner")) || h.Path() != f.lock() {
		t.Fatal("the lock and its owner record sit beside the hub")
	}
	if r := h.Acquire(); r != nil {
		t.Fatal("acquiring again while held is a no-op")
	}
	h.Release()
	if exists(f.lock()) {
		t.Fatal("released")
	}
}

func TestAnotherMachinesLockIsNeverCleared(t *testing.T) {
	f := newFixture(t)
	a := f.hub("A")
	if r := a.Acquire(); r != nil {
		t.Fatal(r)
	}
	wantRefusal(t, f.hub("B").Acquire(), exitcode.LockRemote, "locked by another machine")
	// ... not even an ancient one with the same hostname.
	a.Release()
	f.writeOwner("mac", "1", "2020-01-01T00:00:00Z", "1577836800", "n", "someone-else")
	wantRefusal(t, f.hub("A").Acquire(), exitcode.LockRemote, "locked by another machine")
	if !exists(f.lock()) {
		t.Fatal("cleared another machine's lock")
	}
}

func TestOwnLock(t *testing.T) {
	f := newFixture(t)
	now := fmt.Sprint(time.Now().Unix())
	f.writeOwner("mac", "1", "2026-01-01T00:00:00Z", now, "earlier-run", "A")
	wantRefusal(t, f.hub("A").Acquire(), exitcode.LockRemote, "locked by this machine from an earlier run")

	// Past the TTL: cleared and taken, even under a new hostname.
	f.writeOwner("old-hostname", "1", "2020-01-01T00:00:00Z", "1577836800", "earlier-run", "A")
	h := f.hub("A")
	if r := h.Acquire(); r != nil {
		t.Fatal(r)
	}
	if !strings.Contains(f.stderr.String(), "clearing a stale hub lock left by this machine") {
		t.Fatalf("clearing is loud: %q", f.stderr.String())
	}
	h.Release()

	// An owner record from before the stable id (5 lines): ours by hostname.
	f.writeOwner("mac", "1", "2020-01-01T00:00:00Z", "1577836800", "earlier-run")
	h = f.hub("A")
	if r := h.Acquire(); r != nil {
		t.Fatal(r)
	}
	h.Release()

	// Stale but with no nonce: never cleared automatically.
	f.writeOwner("mac", "1", "2020-01-01T00:00:00Z", "1577836800")
	wantRefusal(t, f.hub("A").Acquire(), exitcode.LockRemote, "rm -rf")
	if !exists(f.lock()) {
		t.Fatal("a nonce-less lock was cleared")
	}
}

func TestOwnerlessLock(t *testing.T) {
	f := newFixture(t)
	if err := os.Mkdir(f.lock(), 0o755); err != nil {
		t.Fatal(err)
	}
	wantRefusal(t, f.hub("A").Acquire(), exitcode.LockRemote, "has no owner record")
	old(f, f.lock())
	h := f.hub("A")
	if r := h.Acquire(); r != nil {
		t.Fatal(r)
	}
	h.Release()
}

func TestTheClearingMutex(t *testing.T) {
	f := newFixture(t)
	f.writeOwner("mac", "1", "2020-01-01T00:00:00Z", "1577836800", "earlier-run", "A")
	if err := os.Mkdir(f.lock()+".clearing", 0o755); err != nil {
		t.Fatal(err)
	}
	wantRefusal(t, f.hub("A").Acquire(), exitcode.LockRemote, "another run is clearing")
	old(f, f.lock()+".clearing")
	wantRefusal(t, f.hub("A").Acquire(), exitcode.LockRemote, "rmdir "+f.lock()+".clearing")
	if !exists(f.lock()) || !exists(f.lock()+".clearing") {
		t.Fatal("nothing is removed while the mutex is held or dead")
	}
}

func TestReleaseOnlyRemovesOurOwnLock(t *testing.T) {
	f := newFixture(t)
	h := f.hub("A")
	if r := h.Acquire(); r != nil {
		t.Fatal(r)
	}
	// Someone cleared it as stale and took a fresh one meanwhile.
	f.writeOwner("mac", "1", "2026-01-01T00:00:00Z", fmt.Sprint(time.Now().Unix()), "another-run", "A")
	h.Release()
	if !exists(f.lock()) {
		t.Fatal("released a lock with another run's nonce")
	}
}

func TestUnwritableHubParent(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root writes everywhere")
	}
	f := newFixture(t)
	if err := os.Chmod(f.root, 0o555); err != nil {
		t.Fatal(err)
	}
	defer os.Chmod(f.root, 0o755)
	r := f.hub("A").Acquire()
	if r == nil || r.Code != exitcode.LockCreate {
		t.Fatalf("got %v, want 51", r)
	}
}

func TestStableIDIsWrittenOnceEvenUnderARace(t *testing.T) {
	dir := t.TempDir()
	var wg sync.WaitGroup
	ids := make([]string, 16)
	for i := range ids {
		wg.Add(1)
		go func(i int) { defer wg.Done(); ids[i] = StableID(dir, "mac", i, time.Now()) }(i)
	}
	wg.Wait()
	disk := firstLine(filepath.Join(dir, "host-id"))
	for i, id := range ids {
		if id != disk || id == "" {
			t.Fatalf("run %d got %q, the file says %q", i, id, disk)
		}
	}
	if again := StableID(dir, "renamed-mac", 99, time.Now()); again != disk {
		t.Fatal("a renamed machine keeps its id")
	}
}

func TestLocalLock(t *testing.T) {
	dir := t.TempDir()
	log := &logx.Logger{File: filepath.Join(dir, "log"), Level: "DEBUG"}
	a, r := AcquireLocal(dir, false, os.Getpid(), time.Now(), log)
	if r != nil {
		t.Fatal(r)
	}
	_, r = AcquireLocal(dir, false, os.Getpid()+1, time.Now(), log)
	wantRefusal(t, r, exitcode.LockLocal, "already running")
	b, r := AcquireLocal(dir, true, os.Getpid(), time.Now(), log)
	if r != nil {
		t.Fatal("backup has its own lock")
	}
	b.Release()
	a.Release()

	// A leftover lock whose pid is gone: cleared - once it is not brand new.
	if err := os.Mkdir(filepath.Join(dir, "local.lock.d"), 0o755); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(dir, "local.lock"), []byte("999999\n"), 0o644)
	_, r = AcquireLocal(dir, false, os.Getpid(), time.Now(), log)
	wantRefusal(t, r, exitcode.LockLocal, "is starting")
	ago := time.Now().Add(-time.Minute)
	os.Chtimes(filepath.Join(dir, "local.lock.d"), ago, ago)
	c, r := AcquireLocal(dir, false, os.Getpid(), time.Now(), log)
	if r != nil {
		t.Fatal(r)
	}
	c.Release()
	if exists(filepath.Join(dir, "local.lock.d")) || exists(filepath.Join(dir, "local.lock")) {
		t.Fatal("released")
	}
}
