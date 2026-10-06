// Package transfer moves saves between this machine and the hub with every
// guarantee the script has (#22): the target is snapshotted first, with
// the snapshot's file count asserted; rsync runs into a staging directory
// on the receiving side; machine-local SYNC_EXCLUDE files are carried
// across; and only then are the two directories swapped, by two renames
// that no signal can come between.
package transfer

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/moudlajs/star-traders-sync/internal/exitcode"
	"github.com/moudlajs/star-traders-sync/internal/fail"
	"github.com/moudlajs/star-traders-sync/internal/hub"
	"github.com/moudlajs/star-traders-sync/internal/logx"
	"github.com/moudlajs/star-traders-sync/internal/manifest"
)

// Guard is the process's swap state, shared with its signal handler: while
// a swap is in flight the staged copy may be the only complete copy of the
// saves, so an interrupt waits for the swap instead of tearing through it.
type Guard struct {
	mu      sync.Mutex
	inSwap  bool
	closed  bool   // an interrupt is exiting: no swap may start any more
	pending func() // an interrupt that arrived mid-swap, run once it ends
	cleanup []string
}

// ErrClosed: an interrupt is already taking the process down, so the swap
// was not started (its staging may already be gone).
var ErrClosed = errors.New("interrupted before the swap")

// Swapping runs fn as the swap: an interrupt meanwhile is held until it
// returns. InSwap reports whether one is in flight (the remote swap, which
// an interrupt can still cut, by killing ssh).
func (g *Guard) Swapping(fn func() error) error {
	g.mu.Lock()
	if g.closed {
		g.mu.Unlock()
		return ErrClosed
	}
	g.inSwap = true
	g.mu.Unlock()
	err := fn()
	g.mu.Lock()
	g.inSwap = false
	p := g.pending
	g.pending = nil
	g.mu.Unlock()
	if p != nil {
		p()
	}
	return err
}

// Interrupt runs onExit now, or after the swap in flight.
func (g *Guard) Interrupt(onExit func()) {
	g.mu.Lock()
	if g.inSwap {
		g.pending = onExit
		g.mu.Unlock()
		return
	}
	// From here no swap starts: onExit removes the staging a swap would
	// move into place.
	g.closed = true
	g.mu.Unlock()
	onExit()
}

// Later registers a path that is removed on exit (the script's
// cleanup_later): staging directories, temp files.
func (g *Guard) Later(p string) {
	g.mu.Lock()
	g.cleanup = append(g.cleanup, p)
	g.mu.Unlock()
}

// Cleanup removes them - except while a swap is in flight, when nothing
// staged may go.
func (g *Guard) Cleanup() {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.inSwap {
		return
	}
	for _, p := range g.cleanup {
		_ = os.RemoveAll(p)
	}
	g.cleanup = nil
}

// T is one transfer's context.
type T struct {
	Hub      *hub.Hub
	Exclude  []string
	Keep     int // SNAPSHOT_KEEP
	Pid      int
	Now      func() time.Time
	Log      *logx.Logger
	Out      io.Writer // say()
	Stderr   io.Writer
	Guard    *Guard
	HubHost  string
	LocalDir string // LOCAL_SAVE_PATH, resolved
}

func (t *T) say(format string, a ...any) { fmt.Fprintf(t.Out, format+"\n", a...) }

func iso(t time.Time) string { return t.UTC().Format("2006-01-02T15:04:05Z") }

// ---------------------------------------------------------------------------
// Snapshots

// countFiles is find DIR -type f, the snapshot directory left out, as the
// script counts a snapshot's source.
func countFiles(dir string, skipTop string) int {
	n := 0
	_ = filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.IsDir() && skipTop != "" && p == filepath.Join(dir, skipTop) {
			return fs.SkipDir
		}
		if d.Type().IsRegular() {
			n++
		}
		return nil
	})
	return n
}

// copyTree is cpio -pdm: regular files with their mode and mtime, the
// directories they need; skipTop (the snapshot directory) left out.
func copyTree(src, dst, skipTop string) error {
	return filepath.WalkDir(src, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil // find's 2>/dev/null; the file count catches what is missed
		}
		rel, _ := filepath.Rel(src, p)
		if d.IsDir() {
			if skipTop != "" && rel == skipTop {
				return fs.SkipDir
			}
			return nil
		}
		if !d.Type().IsRegular() {
			return nil
		}
		return copyFile(p, filepath.Join(dst, rel))
	})
}

func copyFile(src, dst string) error {
	info, err := os.Stat(src)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, info.Mode().Perm())
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	if err := out.Close(); err != nil {
		return err
	}
	_ = os.Chmod(dst, info.Mode().Perm())
	return os.Chtimes(dst, info.ModTime(), info.ModTime())
}

// SnapshotLocal is snapshot_local: copy dir beside itself into
// star-traders-sync-snapshots/<UTC time>, built as .partial-<name> and
// renamed only once its file count matches the source - a snapshot that
// silently copied nothing is what --delete used to be gated on. prune
// false keeps every snapshot (restore must never prune the one it reads).
func (t *T) SnapshotLocal(dir string, prune bool) (string, *fail.Failure) {
	root := filepath.Join(filepath.Dir(dir), manifest.SnapDirName)
	if err := os.MkdirAll(root, 0o755); err != nil {
		return "", fail.New(exitcode.Snapshot, "snapshot", "could not create snapshot root %s", root)
	}
	if real, err := filepath.EvalSymlinks(root); err == nil {
		root = real
	} else {
		return "", fail.New(exitcode.Snapshot, "snapshot", "could not resolve the snapshot root %s: %v", root, err)
	}
	stamp := iso(t.Now())
	name := stamp
	for suffix := 2; ; suffix++ {
		if _, err := os.Lstat(filepath.Join(root, name)); os.IsNotExist(err) &&
			os.Mkdir(filepath.Join(root, ".partial-"+name), 0o755) == nil {
			break
		}
		if suffix > 50 {
			return "", fail.New(exitcode.Snapshot, "snapshot", "could not create a unique snapshot directory under %s", root)
		}
		name = fmt.Sprintf("%s-%d", stamp, suffix)
	}
	partial := filepath.Join(root, ".partial-"+name)
	srcN := countFiles(dir, manifest.SnapDirName)
	if err := copyTree(dir, partial, manifest.SnapDirName); err != nil {
		t.Log.Log("WARN", "snapshot", "copy failed for %s: %v", dir, err)
	}
	dstN := countFiles(partial, "")
	if dstN < srcN {
		return "", fail.New(exitcode.Snapshot, "snapshot",
			"snapshot of %s is INCOMPLETE - %d files in the source, only %d copied to %s. Refusing to overwrite anything. Check permissions on %s.", dir, srcN, dstN, partial, dir)
	}
	snap := filepath.Join(root, name)
	if _, err := os.Lstat(snap); err == nil || os.Rename(partial, snap) != nil {
		return "", fail.New(exitcode.Snapshot, "snapshot",
			"could not finish the snapshot %s as %s. Refusing to overwrite anything.", partial, snap)
	}
	if prune {
		t.pruneLocal(root, dir)
	}
	t.Log.Log("INFO", "snapshot", "local snapshot %s (%d files)", snap, dstN)
	return snap, nil
}

// pruneLocal keeps the newest SNAPSHOT_KEEP - and none are pruned while
// the live directory is empty: then they may be the only copy left.
func (t *T) pruneLocal(root, live string) {
	if t.Keep <= 0 {
		return
	}
	if entries, err := os.ReadDir(live); err == nil {
		files := 0
		for _, e := range entries {
			if e.Type().IsRegular() {
				files++
			}
		}
		if files == 0 {
			t.Log.Log("WARN", "snapshot", "live directory %s is empty - NOT pruning snapshots, they may be the only copy", live)
			return
		}
	}
	names := listed(root)
	if len(names) <= t.Keep {
		return
	}
	for _, old := range names[:len(names)-t.Keep] {
		_ = os.RemoveAll(filepath.Join(root, old))
		t.Log.Log("INFO", "snapshot", "pruned old snapshot %s", old)
	}
}

// listed is ls -1 | sort: the names, dot names (partial snapshots) left out.
func listed(dir string) []string {
	entries, _ := os.ReadDir(dir)
	var names []string
	for _, e := range entries {
		if !strings.HasPrefix(e.Name(), ".") {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)
	return names
}

// SnapshotHub is snapshot_hub, by the script's own snippet on the hub.
func (t *T) SnapshotHub() (string, *fail.Failure) {
	stamp := iso(t.Now())
	root := filepath.Dir(t.Hub.Path) + "/" + manifest.SnapDirName
	guess := root + "/" + stamp
	out, _ := t.Hub.Exec.Run(snapshotHubScript, t.Hub.Path, root, guess, stamp, strconv.Itoa(t.Keep),
		manifest.SnapDirName, manifest.LockDirName)
	switch {
	case strings.Contains(out, "STS_SNAP_OK"):
		t.Log.Log("INFO", "snapshot", "hub snapshot ok on %s: %s", t.HubHost, strings.ReplaceAll(out, "\n", " "))
		snap := guess
		for _, l := range strings.Split(out, "\n") {
			if f := strings.SplitN(l, " ", 3); len(f) == 3 && f[0] == "STS_SNAP_OK" {
				snap = f[2]
			}
		}
		return snap, nil
	case strings.Contains(out, "STS_SNAP_SHORT"):
		return "", fail.New(exitcode.Snapshot, "snapshot",
			"hub snapshot is INCOMPLETE (%s) - refusing to overwrite the hub. Check permissions under %s on %s.", strings.TrimRight(out, "\n"), t.Hub.Path, t.HubHost)
	}
	return "", fail.New(exitcode.Snapshot, "snapshot",
		"could not snapshot the hub directory on %s into %s: %s", t.HubHost, guess, strings.TrimRight(out, "\n"))
}

// ---------------------------------------------------------------------------
// rsync

// Excludes is rsync_excludes: snapshot and lock dirs, then SYNC_EXCLUDE.
func (t *T) Excludes() []string {
	e := []string{"--exclude=" + manifest.SnapDirName + "/", "--exclude=" + manifest.LockDirName + "/"}
	for _, n := range t.Exclude {
		e = append(e, "--exclude="+n)
	}
	return e
}

// Rsync is run_rsync: its own exit code and stderr on a failure, a full
// disk told apart (34) from anything else (33). The target is untouched
// either way - the transfer ran into a staging directory.
func (t *T) Rsync(step string, args ...string) *fail.Failure {
	t.Log.Log("INFO", step, "rsync %s", strings.Join(args, " "))
	var o, e bytes.Buffer
	c := exec.Command("rsync", args...)
	c.Stdout, c.Stderr = &o, &e
	err := c.Run()
	out, errOut := strings.TrimRight(o.String(), "\n"), strings.TrimRight(e.String(), "\n")
	if out != "" {
		t.Log.Log("DEBUG", step, "rsync stdout: %s", strings.ReplaceAll(out, "\n", "|"))
	}
	if errOut != "" {
		t.Log.Log("DEBUG", step, "rsync stderr: %s", strings.ReplaceAll(errOut, "\n", "|"))
	}
	if err == nil {
		return nil
	}
	rc := 1
	if ee, ok := err.(*exec.ExitError); ok {
		rc = ee.ExitCode()
	}
	both := errOut + out
	if strings.Contains(both, "No space left on device") || strings.Contains(both, "write error") || strings.Contains(both, "disk full") {
		t.Log.Log("ERROR", step, "disk full (rsync rc=%d): %s", rc, errOut)
		hubLine := "  hub:   df -h " + t.Hub.Path
		if t.Hub.Endpoint != "" {
			hubLine = "  hub:   ssh " + strings.Join(t.Hub.SSHOpts, " ") + " " + t.Hub.Target() + " df -h " + t.Hub.Path
		}
		return fail.Printed(exitcode.DiskFull, step, "",
			"error: out of disk space during transfer.",
			fmt.Sprintf("rsync exit code %d, stderr:", rc), errOut,
			"Check free space on both sides:",
			"  local: df -h "+t.LocalDir, hubLine)
	}
	t.Log.Log("ERROR", step, "rsync failed rc=%d: %s", rc, errOut)
	return fail.Printed(exitcode.Rsync, step, "",
		fmt.Sprintf("error: rsync failed with its own exit code %d.", rc),
		"rsync stderr:", errOut,
		"The target was not modified - the transfer ran into a temp directory.")
}

// ---------------------------------------------------------------------------
// Machine-local files and the swap

// globNames is the script's unquoted "$live"/$name: bash glob semantics, so
// a leading dot is only matched by a pattern that starts with one.
func globNames(dir, pattern string) []string {
	matches, _ := filepath.Glob(filepath.Join(dir, pattern))
	var out []string
	for _, m := range matches {
		if strings.HasPrefix(filepath.Base(m), ".") && !strings.HasPrefix(pattern, ".") {
			continue
		}
		out = append(out, m)
	}
	return out
}

// PreserveExcluded carries SYNC_EXCLUDE entries from live into staged, so
// the swap does not delete them; one that cannot be carried refuses (63).
func (t *T) PreserveExcluded(live, staged string) *fail.Failure {
	if st, err := os.Stat(live); err != nil || !st.IsDir() {
		return nil
	}
	count := 0
	for _, name := range t.Exclude {
		for _, f := range globNames(live, name) {
			if _, err := os.Lstat(filepath.Join(staged, filepath.Base(f))); err == nil {
				continue
			}
			if err := copyAll(f, filepath.Join(staged, filepath.Base(f))); err != nil {
				t.Log.Log("ERROR", "preserve", "could not carry excluded path %s into %s", f, staged)
				return fail.New(exitcode.Snapshot, "preserve",
					"failed to preserve the excluded path %s - refusing to swap, because the swap would delete it", f)
			}
			count++
		}
	}
	if count > 0 {
		t.Log.Log("INFO", "preserve", "carried %d excluded file(s) across the swap into %s", count, staged)
	}
	return nil
}

// copyAll is cp -Rp: a file, or a directory and everything in it.
func copyAll(src, dst string) error {
	st, err := os.Stat(src)
	if err != nil {
		return err
	}
	if !st.IsDir() {
		return copyFile(src, dst)
	}
	return filepath.WalkDir(src, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(src, p)
		target := filepath.Join(dst, rel)
		if d.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		if d.Type().IsRegular() {
			return copyFile(p, target)
		}
		return nil
	})
}

// PreserveExcludedHub is preserve_excluded_hub: the same carry on the hub,
// which reports the first path it could not carry (#128).
func (t *T) PreserveExcludedHub(staged string) *fail.Failure {
	if len(t.Exclude) == 0 {
		return nil
	}
	out, err := t.Hub.Exec.Run(carryHubScript, append([]string{t.Hub.Path, staged}, t.Exclude...)...)
	if strings.Contains(out, "STS_CARRY_OK") {
		return nil
	}
	if strings.Contains(out, "STS_CARRY_FAIL") {
		f := ""
		for _, l := range strings.Split(out, "\n") {
			if strings.HasPrefix(l, "STS_CARRY_FAIL ") {
				f = strings.TrimPrefix(l, "STS_CARRY_FAIL ")
			}
		}
		t.Log.Log("ERROR", "preserve", "could not carry excluded path %s/%s into %s on the hub", t.Hub.Path, f, staged)
		return fail.New(exitcode.Snapshot, "preserve",
			"failed to preserve the excluded path %s/%s on the hub - refusing to swap, because the swap would delete it", t.Hub.Path, f)
	}
	if err == nil {
		return nil // no hub directory yet, nothing to carry
	}
	t.Log.Log("ERROR", "preserve", "excluded-file carry on the hub failed: %s", out)
	return fail.New(exitcode.Snapshot, "preserve",
		"could not check the hub's excluded files before the swap - refusing to swap, because it could delete them (%s)", strings.TrimRight(out, "\n"))
}

// SwapIntoPlace is swap_into_place: target aside, staged in, old removed.
// A failed second rename puts the original back. No signal can come
// between the two renames (see Guard).
func (t *T) SwapIntoPlace(tmp, target string) *fail.Failure {
	old := fmt.Sprintf("%s.sts-old-%d", target, t.Pid)
	_ = os.RemoveAll(old)
	var f *fail.Failure
	err := t.Guard.Swapping(func() error {
		if rename(target, old) != nil {
			f = fail.New(exitcode.Rsync, "swap", "could not move %s aside - nothing was changed", target)
			return nil
		}
		if rename(tmp, target) != nil {
			if rename(old, target) != nil {
				// Say where the saves really are: telling the user they were
				// restored would be the opposite of the truth.
				f = fail.New(exitcode.Rsync, "swap",
					"could not move the staged copy into place, nor put the original back - your saves are intact at %s. Move them back by hand: mv %s %s", old, old, target)
			} else {
				f = fail.New(exitcode.Rsync, "swap", "could not move the staged copy into place - the original was restored")
			}
		}
		return nil
	})
	if errors.Is(err, ErrClosed) {
		return fail.New(exitcode.Rsync, "swap", "interrupted before the swap - nothing was changed")
	}
	if f != nil {
		return f
	}
	_ = os.RemoveAll(old)
	t.Log.Log("DEBUG", "swap", "%s -> %s", tmp, target)
	return nil
}

// rename is os.Rename, a seam for the tests of the swap's failure paths.
var rename = os.Rename

// ---------------------------------------------------------------------------
// The two directions

// PullHubToLocal: the hub becomes this machine's saves.
func (t *T) PullHubToLocal(target string) *fail.Failure {
	tmp := fmt.Sprintf("%s/.sts-incoming-%d", filepath.Dir(target), t.Pid)
	t.Guard.Later(tmp)
	_ = os.RemoveAll(tmp)
	if err := os.MkdirAll(tmp, 0o755); err != nil {
		return fail.New(exitcode.LocalSaveBad, "pull", "could not create the staging directory %s", tmp)
	}
	// The snapshot is what makes --delete safe. No snapshot, no --delete.
	snap, f := t.SnapshotLocal(target, true)
	if f != nil {
		return f
	}
	t.say("snapshot: %s", snap)
	args := append([]string{"-a", "-c", "--delete"}, t.Excludes()...)
	args = append(args, "--link-dest="+target)
	if t.Hub.IsLocal {
		args = append(args, t.Hub.Path+"/", tmp+"/")
	} else {
		args = append(args, "-e", "ssh "+strings.Join(t.Hub.SSHOpts, " "), t.Hub.Target()+":"+t.Hub.Path+"/", tmp+"/")
	}
	if f := t.Rsync("pull", args...); f != nil {
		return f
	}
	if f := t.PreserveExcluded(target, tmp); f != nil {
		return f
	}
	if f := t.SwapIntoPlace(tmp, target); f != nil {
		return f
	}
	t.Log.Log("INFO", "pull", "hub -> local complete")
	return nil
}

// PushLocalToHub: this machine's saves become the hub.
func (t *T) PushLocalToHub(src string) *fail.Failure {
	tmp := fmt.Sprintf("%s/.sts-incoming-%d", filepath.Dir(t.Hub.Path), t.Pid)
	// Sweep staging directories left by interrupted pushes: safe under the
	// hub lock, nothing else is mid-transfer.
	_, _ = t.Hub.Exec.Run(sweepHubScript, filepath.Dir(t.Hub.Path))
	if _, err := t.Hub.Exec.Run(stageHubScript, tmp); err != nil {
		return fail.New(exitcode.HubPerms, "push", "could not create the staging directory %s on %s", tmp, t.HubHost)
	}
	snap, f := t.SnapshotHub()
	if f != nil {
		return f
	}
	t.say("snapshot: %s (on %s)", snap, t.HubHost)
	args := append([]string{"-a", "-c", "--delete"}, t.Excludes()...)
	args = append(args, "--link-dest="+t.Hub.Path)
	if t.Hub.IsLocal {
		if f := t.Rsync("push", append(args, src+"/", tmp+"/")...); f != nil {
			return f
		}
		if f := t.PreserveExcluded(t.Hub.Path, tmp); f != nil {
			return f
		}
		if f := t.SwapIntoPlace(tmp, t.Hub.Path); f != nil {
			return f
		}
	} else {
		args = append(args, "-e", "ssh "+strings.Join(t.Hub.SSHOpts, " "), src+"/", t.Hub.Target()+":"+tmp+"/")
		if f := t.Rsync("push", args...); f != nil {
			return f
		}
		if f := t.PreserveExcludedHub(tmp); f != nil {
			return f
		}
		var swapErr error
		if errors.Is(t.Guard.Swapping(func() error {
			_, swapErr = t.Hub.Exec.Run(swapHubScript, t.Hub.Path, tmp, strconv.Itoa(t.Pid))
			return nil
		}), ErrClosed) {
			return fail.New(exitcode.Rsync, "swap", "interrupted before the swap - nothing was changed")
		}
		if swapErr != nil {
			return fail.New(exitcode.HubPerms, "push",
				"transfer succeeded but moving it into place on %s failed - the previous hub content was restored, or is at %s.sts-old-%d", t.HubHost, t.Hub.Path, t.Pid)
		}
	}
	t.Log.Log("INFO", "push", "local -> hub complete")
	return nil
}

// MkdirHub is push's "mkdir -p HUB_PATH", for a first seed.
func (t *T) MkdirHub() { _, _ = t.Hub.Exec.Run(mkdirHubScript, t.Hub.Path) }
