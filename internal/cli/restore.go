package cli

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/moudlajs/star-traders-sync/internal/exitcode"
	"github.com/moudlajs/star-traders-sync/internal/fail"
	"github.com/moudlajs/star-traders-sync/internal/lock"
	"github.com/moudlajs/star-traders-sync/internal/manifest"
	"github.com/moudlajs/star-traders-sync/internal/saves"
	"github.com/moudlajs/star-traders-sync/internal/transfer"
)

// prepareLocal is main() for the commands that only touch this machine
// (restore): the local lock, orphan recovery and the save folder - no
// tailnet, no hub.
func (r *run) prepareLocal(now time.Time) *fail.Failure {
	l, f := lock.AcquireLocal(r.p.stateDir, false, r.pid, now, r.log)
	if f != nil {
		return f
	}
	r.lockLoc = l
	r.ex.add(l.Release)
	if f := saves.RecoverOrphans(r.cfg.Get("LOCAL_SAVE_PATH"), true, now, r.log); f != nil {
		return f
	}
	local, f := saves.CheckPath(r.cfg.Get("LOCAL_SAVE_PATH"), r.log, r.env.Stderr)
	if f != nil {
		return f
	}
	r.local = local
	return nil
}

func (r *run) snapRoot() string {
	return filepath.Join(filepath.Dir(r.local), manifest.SnapDirName)
}

type safetyCopy struct {
	name         string
	files, saves int
	newest       int64
}

// candidates is restore_candidates: every listed snapshot (dot names - a
// partial one - left out), newest first.
func (r *run) candidates() []safetyCopy {
	entries, _ := os.ReadDir(r.snapRoot())
	var names []string
	for _, e := range entries {
		if !strings.HasPrefix(e.Name(), ".") && e.IsDir() {
			names = append(names, e.Name())
		}
	}
	sort.Sort(sort.Reverse(sort.StringSlice(names)))
	var out []safetyCopy
	for _, n := range names {
		c := safetyCopy{name: n}
		_ = filepath.WalkDir(filepath.Join(r.snapRoot(), n), func(p string, d fs.DirEntry, err error) error {
			if err != nil || !d.Type().IsRegular() {
				return nil
			}
			c.files++
			if isGameSave(p) {
				c.saves++
			}
			if info, err := d.Info(); err == nil && info.ModTime().Unix() > c.newest {
				c.newest = info.ModTime().Unix()
			}
			return nil
		})
		out = append(out, c)
	}
	return out
}

// restoreList is cmd_restore_list, the JSON in json.dumps' own spacing.
func (r *run) restoreList() {
	cs := r.candidates()
	if r.opt.JSON {
		var items []string
		for _, c := range cs {
			items = append(items, fmt.Sprintf(`{"name": %s, "files": %d, "campaign_saves": %d, "newest": %d}`,
				strconv.Quote(c.name), c.files, c.saves, c.newest))
		}
		fmt.Fprintf(r.json, "{\"snapshots\": [%s]}\n", strings.Join(items, ", "))
		return
	}
	if len(cs) == 0 {
		r.say("no safety copies of this machine's saves yet, under %s", r.snapRoot())
		return
	}
	r.say("safety copies of this machine's saves, newest first:")
	for _, c := range cs {
		r.say("  %s   %d files, %d campaign saves, newest %s", c.name, c.files, c.saves, humanTime(c.newest))
	}
	r.say("")
	r.say("restore one with: %s restore NAME", prog)
}

// restore is cmd_restore: put one of this machine's safety copies back,
// through the same staging and swap as a pull. What is here now is
// snapshotted first - without pruning, so the copy restored from survives -
// and the live machine-local files are carried across, not the copy's.
func (r *run) restore() *fail.Failure {
	if r.opt.RestoreFrom == "" {
		r.restoreList()
		return nil
	}
	name, root := r.opt.RestoreFrom, r.snapRoot()
	if strings.Contains(name, "/") || strings.HasPrefix(name, ".") {
		return fail.New(exitcode.NoSnapshot, "restore", "'%s' is not the name of a safety copy. List them with: %s restore", name, prog)
	}
	snap := filepath.Join(root, name)
	if st, err := os.Stat(snap); err != nil || !st.IsDir() {
		return fail.New(exitcode.NoSnapshot, "restore", "there is no safety copy named %s in %s. List them with: %s restore", name, root, prog)
	}
	n := 0
	_ = filepath.WalkDir(snap, func(p string, d fs.DirEntry, err error) error {
		if err == nil && d.Type().IsRegular() {
			n++
		}
		return nil
	})
	if n == 0 {
		return fail.New(exitcode.NoSnapshot, "restore", "the safety copy %s is empty - there is nothing in it to restore", name)
	}
	s := &syncer{run: r}
	if f := s.checkGameNotRunning(); f != nil {
		return f
	}
	g := &transfer.Guard{}
	r.ex.setGuard(g)
	r.ex.add(g.Cleanup)
	t := &transfer.T{Exclude: r.cfg.Exclude(), Keep: r.cfg.Int("SNAPSHOT_KEEP"), Pid: r.pid, Now: time.Now,
		Log: r.log, Out: r.out, Stderr: r.env.Stderr, Guard: g, LocalDir: r.local}

	tmp := fmt.Sprintf("%s/.sts-incoming-%d", filepath.Dir(r.local), r.pid)
	g.Later(tmp)
	_ = os.RemoveAll(tmp)
	if err := os.MkdirAll(tmp, 0o755); err != nil {
		return fail.New(exitcode.Snapshot, "restore", "could not copy the safety copy %s - nothing was changed", name)
	}
	if err := transfer.CopyTree(snap, tmp); err != nil {
		r.log.Log("WARN", "restore", "copying %s: %v", snap, err)
	}
	if got := transfer.CountFiles(tmp); got < n {
		return fail.New(exitcode.Snapshot, "restore",
			"copying the safety copy %s was INCOMPLETE - %d files in it, only %d copied. Nothing was changed.", name, n, got)
	}

	aside := ""
	if transfer.CountFiles(r.local) > 0 {
		a, f := t.SnapshotLocal(r.local, false)
		if f != nil {
			return f
		}
		aside = a
	}
	// The copy's machine-local files are older than the live ones: drop
	// them where this machine still has its own, so those are carried.
	for _, pat := range r.cfg.Exclude() {
		for _, live := range transfer.GlobNames(r.local, pat) {
			_ = os.RemoveAll(filepath.Join(tmp, filepath.Base(live)))
		}
	}
	if f := t.PreserveExcluded(r.local, tmp); f != nil {
		return f
	}
	if f := t.SwapIntoPlace(tmp, r.local); f != nil {
		return f
	}
	keptAs := "nothing, it was empty"
	if aside != "" {
		keptAs = aside
	}
	r.log.Log("INFO", "restore", "restored %s (%d files) into %s; previous saves kept as %s", name, n, r.local, keptAs)
	r.say("restored the safety copy %s (%d files)", name, n)
	if aside != "" {
		r.say("the saves that were here are kept as the safety copy %s,", filepath.Base(aside))
		r.say("so this can be undone with: %s restore %s", prog, filepath.Base(aside))
	}
	r.say("run '%s status' to see what the next sync will do with them.", prog)
	return nil
}
