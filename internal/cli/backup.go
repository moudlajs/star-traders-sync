package cli

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/moudlajs/star-traders-sync/internal/exitcode"
	"github.com/moudlajs/star-traders-sync/internal/fail"
	"github.com/moudlajs/star-traders-sync/internal/hub"
	"github.com/moudlajs/star-traders-sync/internal/hubexec"
	"github.com/moudlajs/star-traders-sync/internal/lock"
	"github.com/moudlajs/star-traders-sync/internal/platform"
	"github.com/moudlajs/star-traders-sync/internal/transfer"
)

func (r *run) isHubByHostname() bool {
	want := strings.ToLower(r.cfg.Get("HUB_HOST"))
	if want == strings.ToLower(r.host) {
		return true
	}
	return want == strings.ToLower(platform.LocalHostName())
}

func device(p string) (uint64, bool) { return platform.Device(p) }

func writable(p string) bool { return platform.CanWrite(p) }

// volumeMounted is backup_volume_mounted: a mount point (not on its parent's device) and writable.
func volumeMounted(vol string) bool {
	if st, err := os.Stat(vol); err != nil || !st.IsDir() {
		return false
	}
	dv, ok1 := device(vol)
	dp, ok2 := device(filepath.Dir(vol))
	return ok1 && ok2 && dv != dp && writable(vol)
}

// waitForBackupVolume is wait_for_backup_volume, before the hub lock so the other Mac is not locked out (#169).
func (r *run) waitForBackupVolume() {
	vol := r.cfg.Get("BACKUP_VOLUME")
	if wait := r.cfg.Int("BACKUP_MOUNT_WAIT"); wait > 0 && !volumeMounted(vol) {
		r.say("waiting up to %ds for %s to mount...", wait, vol)
		r.log.Log("INFO", "backup", "waiting up to %ds for %s", wait, vol)
		for waited := 0; waited < wait; {
			time.Sleep(5 * time.Second)
			waited += 5
			if volumeMounted(vol) {
				r.log.Log("INFO", "backup", "%s appeared after %ds", vol, waited)
				break
			}
		}
	}
}

// checkBackupVolume is check_backup_volume, rechecked under the hub lock.
func (r *run) checkBackupVolume() *fail.Failure {
	vol := r.cfg.Get("BACKUP_VOLUME")
	if st, err := os.Stat(vol); err != nil || !st.IsDir() {
		return fail.New(exitcode.BackupNotMounted, "backup", "backup volume %s is not present at all - is the disk plugged in?", vol)
	}
	dv, ok1 := device(vol)
	dp, ok2 := device(filepath.Dir(vol))
	if !ok1 || !ok2 || dv == dp {
		return fail.New(exitcode.BackupNotMounted, "backup",
			"%s exists but is NOT a mount point - it is a plain directory on the internal disk (device %d, same as %s). Refusing to write backups there. Mount the disk and re-run.", vol, dv, filepath.Dir(vol))
	}
	if !writable(vol) {
		return fail.New(exitcode.BackupNotMounted, "backup", "%s is mounted but not writable - is it mounted read-only?", vol)
	}
	r.log.Log("DEBUG", "backup", "volume %s mounted, device %d", vol, dv)
	return nil
}

// completeBackups is list_complete_backups: only marked ones, oldest first, are --link-dest bases or retained.
func completeBackups(dest string) []string {
	entries, _ := os.ReadDir(dest)
	var out []string
	for _, e := range entries {
		n := e.Name()
		if len(n) < 11 || !strings.HasPrefix(n, "20") || n[4] != '-' || n[7] != '-' || n[10] != 'T' ||
			strings.Trim(n[2:4]+n[5:7]+n[8:10], "0123456789") != "" {
			continue
		}
		if st, err := os.Stat(filepath.Join(dest, n, ".sts-complete")); err == nil && st.Mode().IsRegular() {
			out = append(out, n)
		}
	}
	sort.Strings(out)
	return out
}

// backup is cmd_backup; a torn backup never joins the rotation.
func (r *run) backup(now time.Time) *fail.Failure {
	if !r.isHubByHostname() {
		return fail.New(exitcode.BackupNotHub, "backup",
			"'%s backup' only runs on the hub host (%s). This machine is %s.", prog, r.cfg.Get("HUB_HOST"), r.host)
	}
	r.log.Log("INFO", "backup", "hub identity confirmed by hostname: %s", r.host)

	r.hub = &hub.Hub{Host: r.cfg.Get("HUB_HOST"), User: r.cfg.Get("HUB_USER"), Path: r.cfg.Get("HUB_PATH"),
		IsLocal: true, EndpointKind: "local", Exec: hubexec.Local{}, Log: r.log, Stdout: r.out, Stderr: r.env.Stderr}
	s := r.newSyncer(now)
	r.waitForBackupVolume()
	if f := s.hubLock.Acquire(); f != nil {
		return f
	}
	if f := r.checkBackupVolume(); f != nil {
		return f
	}
	hubPath := r.cfg.Get("HUB_PATH")
	if st, err := os.Stat(hubPath); err != nil || !st.IsDir() {
		return fail.New(exitcode.HubPathMissing, "backup", "hub path %s does not exist on this machine", hubPath)
	}
	srcN := 0
	_ = filepath.WalkDir(hubPath, func(p string, d fs.DirEntry, err error) error {
		if err == nil && d.Type().IsRegular() && d.Name() != lock.DirName {
			srcN++
		}
		return nil
	})
	// Never back up an empty hub: nightly, it would age every real backup out.
	if srcN == 0 {
		return fail.New(exitcode.HubEmpty, "backup",
			"the hub at %s has 0 files - refusing to back up an empty hub over the existing rotation. Investigate the hub before running this again.", hubPath)
	}
	dest := r.cfg.Get("BACKUP_DEST")
	if r.opt.DryRun {
		r.say("dry run - would back up %s (%d files) into %s", hubPath, srcN, dest)
		out, _ := exec.Command("rsync", "-a", "-c", "-n", "-i", hubPath+"/", dest+"/pending/").CombinedOutput()
		for _, l := range strings.Split(strings.TrimRight(string(out), "\n"), "\n") {
			if l != "" {
				r.say("  %s", l)
			}
		}
		s.hubLock.Release()
		return nil
	}
	if err := os.MkdirAll(dest, 0o755); err != nil {
		return fail.New(exitcode.BackupNotMounted, "backup", "could not create %s", dest)
	}
	completed := completeBackups(dest)
	prev := ""
	if len(completed) > 0 {
		prev = completed[len(completed)-1]
	}
	// exFAT and friends have no hard links: then every backup is a full copy.
	canLink := false
	a, b := filepath.Join(dest, ".sts-linktest"), filepath.Join(dest, ".sts-linktest-2")
	_ = os.Remove(a)
	_ = os.Remove(b)
	if os.WriteFile(a, nil, 0o644) == nil && os.Link(a, b) == nil {
		canLink = true
	}
	_ = os.Remove(a)
	_ = os.Remove(b)
	if !canLink {
		r.log.Log("INFO", "backup", "%s does not support hard links (exFAT or similar) - each backup is a full copy", dest)
	}

	stamp := now.UTC().Format("2006-01-02T15:04:05Z")
	target := filepath.Join(dest, stamp)
	for suffix := 2; ; suffix++ {
		err := os.Mkdir(target, 0o755)
		if err == nil {
			break
		}
		if !errors.Is(err, fs.ErrExist) {
			r.log.Log("ERROR", "backup", "mkdir %s failed: %v", target, err)
			return fail.Printed(exitcode.BackupNotMounted, "backup", "",
				"error: could not create the backup directory.",
				fmt.Sprintf("  mkdir: %s: %s", target, strings.TrimPrefix(err.Error(), "mkdir "+target+": ")),
				"", "The volume is mounted and writable, so this is usually macOS",
				"privacy protection: a launchd job needs explicit permission to",
				"write to a removable volume, and is denied silently without a",
				"prompt. Grant it in System Settings > Privacy & Security >",
				"Full Disk Access, for /bin/bash.")
		}
		if suffix > 50 {
			return fail.New(exitcode.BackupNotMounted, "backup",
				"could not create a unique backup directory under %s after 50 attempts", dest)
		}
		target = fmt.Sprintf("%s/%s-%d", dest, stamp, suffix)
	}

	// Until marked complete, a failure or interrupt removes it, so a torn backup never looks good.
	var pendMu sync.Mutex
	pending := target
	dropPending := func() {
		pendMu.Lock()
		defer pendMu.Unlock()
		if pending != "" {
			r.log.Log("WARN", "backup", "removing incomplete backup %s", pending)
			_ = os.RemoveAll(pending)
			pending = ""
		}
	}
	r.ex.add(dropPending)
	defer dropPending()
	r.say("backing up %s (%d files) -> %s", hubPath, srcN, target)
	t := &transfer.T{Hub: r.hub, Log: r.log, Out: r.out, Stderr: r.env.Stderr, LocalDir: hubPath}
	var f *fail.Failure
	if prev != "" && canLink {
		// -c: else a same-size save rewritten in the same second is hard-linked from the old copy (#158).
		f = t.Rsync("backup", "-a", "-c", "--link-dest="+filepath.Join(dest, prev), hubPath+"/", target+"/")
		if f == nil {
			r.log.Log("INFO", "backup", "hardlinked unchanged files against %s", prev)
		}
	} else {
		f = t.Rsync("backup", "-a", hubPath+"/", target+"/")
	}
	if f != nil {
		return f
	}
	dstN := transfer.CountFiles(target)
	if dstN < srcN {
		_ = os.RemoveAll(target)
		return fail.New(exitcode.Rsync, "backup",
			"backup is INCOMPLETE - %d files in the hub, only %d copied. The partial copy was removed so it cannot be mistaken for a good backup.", srcN, dstN)
	}
	// Unmarked, it would never rotate out; still pending, the deferred cleanup removes it.
	if err := os.WriteFile(filepath.Join(target, ".sts-complete"), []byte(time.Now().UTC().Format("2006-01-02T15:04:05Z")+"\n"), 0o644); err != nil {
		return fail.New(exitcode.Rsync, "backup",
			"could not mark the backup in %s complete, so it was removed - the backup volume may be full or read-only", target)
	}
	pendMu.Lock()
	pending = ""
	pendMu.Unlock()

	if keep := r.cfg.Int("BACKUP_KEEP"); keep > 0 {
		if done := completeBackups(dest); len(done) > keep {
			for _, old := range done[:len(done)-keep] {
				_ = os.RemoveAll(filepath.Join(dest, old))
				r.log.Log("INFO", "backup", "pruned old backup %s", old)
			}
		}
	}
	s.hubLock.Release()
	r.say("backup complete: %s (%d files)", target, dstN)
	r.log.Log("INFO", "backup", "complete %s (%d files)", target, dstN)
	return nil
}
