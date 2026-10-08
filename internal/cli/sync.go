package cli

import (
	"fmt"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/moudlajs/star-traders-sync/internal/decide"
	"github.com/moudlajs/star-traders-sync/internal/exitcode"
	"github.com/moudlajs/star-traders-sync/internal/fail"
	"github.com/moudlajs/star-traders-sync/internal/hub"
	"github.com/moudlajs/star-traders-sync/internal/lock"
	"github.com/moudlajs/star-traders-sync/internal/manifest"
	"github.com/moudlajs/star-traders-sync/internal/state"
	"github.com/moudlajs/star-traders-sync/internal/transfer"
)

type syncer struct {
	*run
	hubLock *lock.Hub
	t       *transfer.T
	guard   *transfer.Guard
}

func (r *run) newSyncer(now time.Time) *syncer {
	g := &transfer.Guard{}
	s := &syncer{run: r, guard: g}
	s.hubLock = &lock.Hub{Exec: r.hub.Exec, HubPath: r.cfg.Get("HUB_PATH"), HubHost: r.cfg.Get("HUB_HOST"),
		HubUser: r.cfg.Get("HUB_USER"), TTL: r.cfg.Int("LOCK_TTL_SECONDS"), HostName: r.host,
		StableID: lock.StableID(r.p.stateDir, r.host, r.pid, now), Pid: r.pid,
		Nonce: fmt.Sprintf("%s-%d-%d", r.host, r.pid, now.Unix()), Now: time.Now, Log: r.log, Stderr: r.env.Stderr}
	r.ex.setGuard(g)
	r.ex.add(func() { s.hubLock.Release(); g.Cleanup() })
	s.t = &transfer.T{Hub: r.hub, Exclude: r.cfg.Exclude(), Keep: r.cfg.Int("SNAPSHOT_KEEP"), Pid: r.pid,
		Now: time.Now, Log: r.log, Out: r.out, Stderr: r.env.Stderr, Guard: g, HubHost: r.cfg.Get("HUB_HOST"), LocalDir: r.local}
	return s
}

// release is on_exit's part; staging is kept while a swap is in flight, as it may hold the only complete copy.
func (s *syncer) release() {
	s.hubLock.Release()
	s.guard.Cleanup()
	s.lockLoc.Release()
}

func (s *syncer) checkGameNotRunning() *fail.Failure {
	name := s.cfg.Get("GAME_PROCESS_NAME")
	if pids := pgrep(name); strings.TrimSpace(pids) != "" {
		return fail.New(exitcode.GameRunning, "game",
			"%s is running (pid %s) - it holds core.db open read-write, so any copy taken now would be torn. Quit the game first.", name, pids)
	}
	return nil
}

// checkClockSkew warns, never refuses: fingerprints do not care about clocks.
func (s *syncer) checkClockSkew() {
	if s.hub.IsLocal {
		return
	}
	out, err := s.hub.Exec.Run("date -u +%s")
	hubEpoch, perr := strconv.ParseInt(strings.TrimSpace(out), 10, 64)
	if err != nil || perr != nil {
		return
	}
	diff := hubEpoch - time.Now().Unix()
	if diff < 0 {
		diff = -diff
	}
	tol := int64(s.cfg.Int("CLOCK_SKEW_TOLERANCE"))
	if diff > tol {
		s.log.Log("WARN", "clock", "hub clock differs by %ds (tolerance %ds)", diff, tol)
		fmt.Fprintf(s.env.Stderr, "warning: the hub's clock is %ds away from this machine's - timestamps below are unreliable, the decision is based on content fingerprints\n", diff)
	} else {
		s.log.Log("DEBUG", "clock", "hub clock skew %ds, within tolerance", diff)
	}
}

// sideLines is describe_side, as lines.
func sideLines(label string, m manifest.Manifest, epoch int64) []string {
	n, paths := campaignSaves(m)
	l := []string{"  " + label, fmt.Sprintf("    files:     %d (%d campaign saves)", m.Count(), n), "    newest:    " + humanTime(epoch)}
	if len(paths) > 0 {
		l = append(l, "    campaigns: "+strings.Join(paths, " ")+" ")
	}
	return l
}

func (s *syncer) conflictReport(code exitcode.Code, step, logMsg, reason string, pre []string, lm, hm manifest.Manifest, lep, hep int64) *fail.Failure {
	lines := append([]string{}, pre...)
	lines = append(lines, "error: "+reason, "")
	lines = append(lines, sideLines(fmt.Sprintf("LOCAL  (%s): %s", s.host, s.local), lm, lep)...)
	lines = append(lines, "")
	lines = append(lines, sideLines(fmt.Sprintf("HUB    (%s): %s", s.cfg.Get("HUB_HOST"), s.cfg.Get("HUB_PATH")), hm, hep)...)
	lines = append(lines, "",
		"These are not merged and not auto-picked. Decide, then run:",
		fmt.Sprintf("  %s push --force=local   keep this machine's saves, overwrite the hub", prog),
		fmt.Sprintf("  %s pull --force=hub     keep the hub's saves, overwrite this machine", prog),
		"", fmt.Sprintf("Both sides are snapshotted before any overwrite, under %s/", manifest.SnapDirName))
	s.log.Log("ERROR", step, "%s", logMsg)
	return fail.Printed(code, step, "", lines...)
}

var divergedPre = []string{
	"error: the recorded sync state is inconsistent with what is on disk.",
	"Neither side changed since the last recorded sync, yet they differ.",
	"That usually means a sync was recorded against a hub another machine",
	"changed at the same moment, or SYNC_EXCLUDE differs between machines.", "",
}

type reading struct {
	lm, hm             manifest.Manifest
	lfp, hfp           string
	lep, hep           int64
	st                 decide.State
	verdict, effective decide.Decision
}

func (s *syncer) read(step string) (*reading, *fail.Failure) {
	if f := s.checkGameNotRunning(); f != nil {
		return nil, f
	}
	if f := s.hubLock.Acquire(); f != nil {
		return nil, f
	}
	s.checkClockSkew()
	lm, hm, lfp, hfp, f := s.sides()
	if f != nil {
		return nil, f
	}
	rd := &reading{lm: lm, hm: hm, lfp: lfp, hfp: hfp, lep: lepOf(s.local), hep: s.hub.Newest(),
		st: state.Read(s.p.stateFile, s.cfg.Get("HUB_HOST"), s.cfg.Get("HUB_PATH"))}
	l, h := decide.Side{FP: lfp, Count: lm.Count()}, decide.Side{FP: hfp, Count: hm.Count()}
	rd.verdict, rd.effective = decide.Decide(l, h, rd.st), decide.Effective(l, h, rd.st)
	s.log.Log("INFO", step, "verdict=%s effective=%s local=%d files hub=%d files force='%s'",
		rd.verdict, rd.effective, lm.Count(), hm.Count(), s.opt.Force)
	// --expect-decision is checked under the hub lock, so nothing can change before the transfer.
	if s.opt.Expect != "" {
		if string(rd.effective) != s.opt.Expect {
			return nil, fail.New(exitcode.StateChanged, step,
				"the saves changed since this was chosen: it was %s, it is now %s. Nothing was done - check again and choose.", s.opt.Expect, rd.effective)
		}
		s.log.Log("INFO", step, "expected decision %s still holds", s.opt.Expect)
	}
	return rd, nil
}

func lepOf(dir string) int64 { return hub.NewestLocal(dir) }

func (s *syncer) record(direction, lfp, hfp string) {
	if err := state.Write(s.p.stateFile, direction, lfp, hfp, s.cfg.Get("HUB_HOST"), s.cfg.Get("HUB_PATH"), time.Now()); err == nil {
		s.log.Log("INFO", "state", "recorded %s local=%s hub=%s", direction, short(lfp, 12), short(hfp, 12))
	}
}

// afterTransferUnread records nothing, so the next run decides from what is really there.
func (s *syncer) afterTransferUnread(direction string, err error) *fail.Failure {
	s.log.Log("ERROR", direction, "could not read the hub back after the transfer: %v", err)
	return fail.New(exitcode.SSHFailed, direction,
		"the %s finished, but the hub could not be read back afterwards (%v), so it was not recorded. Run '%s status' once the hub is reachable.", direction, err, prog)
}

// verify is verify_transfer: a mismatch leaves DIVERGED_STATE, which every path refuses (#158).
func (s *syncer) verify(direction, lfp, hfp string) *fail.Failure {
	if lfp == hfp {
		return nil
	}
	s.log.Log("ERROR", direction, "after the transfer the two sides differ: local=%s hub=%s", lfp, hfp)
	return fail.New(exitcode.Rsync, direction,
		"the transfer finished but this machine and the hub still hold different saves, so the %s did not really happen. The side being overwritten was snapshotted first. Nothing will sync on its own until this is resolved - see 'transfer finished but ... different saves' in docs/troubleshooting.md.", direction)
}

func (s *syncer) warn(format string, a ...any) {
	fmt.Fprintf(s.env.Stderr, "warning: "+format+"\n", a...)
}

// pull is cmd_pull.
func (s *syncer) pull() *fail.Failure {
	rd, f := s.read("pull")
	if f != nil {
		return f
	}
	lc, hc := rd.lm.Count(), rd.hm.Count()
	if rd.effective == decide.HubEmpty {
		return fail.New(exitcode.HubEmpty, "pull",
			"the hub has 0 files and this machine has %d - refusing to empty this machine. If the hub really should be the source of truth, seed it first with '%s push --force=local' from the machine that has the saves.", lc, prog)
	}
	if s.opt.Force != "hub" && rd.effective == decide.LocalEmptied {
		return fail.New(exitcode.ConflictFirstRun, "pull",
			"this machine's saves are gone (0 files) while the hub has %d - not playing or syncing on nothing. Restore them from the hub with: %s pull --force=hub", hc, prog)
	}
	switch rd.verdict {
	case decide.InSync:
		s.say("already in sync - nothing to pull")
		s.record("pull", rd.lfp, rd.hfp)
		s.hubLock.Release()
		return nil
	case decide.HubEmpty:
		return fail.New(exitcode.HubEmpty, "pull",
			"the hub is empty and this machine has %d files - there is nothing to pull. If these saves should become the source of truth, run: %s push", lc, prog)
	case decide.FirstSeed:
		s.say("first seed: this machine has no saves, the hub has %d files", hc)
		s.log.Log("WARN", "pull", "FIRST SEED - local was empty, seeding from hub (not an ordinary pull)")
	case decide.FirstRunConflict:
		if s.opt.Force != "hub" {
			return s.conflictReport(exitcode.ConflictFirstRun, "pull", "first-run conflict",
				"first run on this machine, and BOTH sides already have saves. This is a conflict, not a fresh start.", nil, rd.lm, rd.hm, rd.lep, rd.hep)
		}
		s.warn("--force=hub: overwriting this machine's %d files with the hub's %d", lc, hc)
	case decide.DivergedState:
		return s.conflictReport(exitcode.Conflict, "pull", "diverged state", "not deciding this for you.", divergedPre, rd.lm, rd.hm, rd.lep, rd.hep)
	case decide.BothChanged:
		if s.opt.Force != "hub" {
			return s.conflictReport(exitcode.Conflict, "pull", "both sides changed",
				"both sides changed since the last sync on this machine.", nil, rd.lm, rd.hm, rd.lep, rd.hep)
		}
		s.warn("--force=hub: discarding local changes")
	case decide.LocalOnly:
		if s.inPlay && s.opt.Force != "hub" {
			s.say("this machine is ahead of the hub - nothing to fetch, its saves are sent after you play")
			s.log.Log("INFO", "pull", "local-only changes before play: not pulling, play continues")
			s.hubLock.Release()
			return nil
		}
		if s.opt.Force != "hub" {
			return s.conflictReport(exitcode.Conflict, "pull", "local-only changes, refusing to pull",
				"only THIS machine changed since the last sync - pulling would discard those changes.", nil, rd.lm, rd.hm, rd.lep, rd.hep)
		}
		s.warn("--force=hub: discarding local changes")
	}
	s.say("pulling %s:%s -> %s", s.cfg.Get("HUB_HOST"), s.cfg.Get("HUB_PATH"), s.local)
	if f := s.t.PullHubToLocal(s.local); f != nil {
		return f
	}
	lm, err := manifest.Build(s.local, s.cfg.Exclude())
	if err != nil {
		return fail.New(exitcode.LocalSaveBad, "pull", "%v", err)
	}
	hm, err := s.hub.Manifest()
	if err != nil {
		return s.afterTransferUnread("pull", err)
	}
	lfp, _ := lm.Fingerprint()
	hfp, _ := hm.Fingerprint()
	s.record("pull", lfp, hfp)
	s.hubLock.Release()
	if f := s.verify("pull", lfp, hfp); f != nil {
		return f
	}
	s.say("pull complete - %d files", lm.Count())
	return nil
}

// push is cmd_push.
func (s *syncer) push() *fail.Failure {
	rd, f := s.read("push")
	if f != nil {
		return f
	}
	lc, hc := rd.lm.Count(), rd.hm.Count()
	hubEmpty := func(lines ...string) *fail.Failure {
		s.log.Log("ERROR", "push", "hub empty, refusing to seed without --force=local")
		return fail.Printed(exitcode.HubEmpty, "push", "", lines...)
	}
	if rd.effective == decide.HubEmpty && s.opt.Force != "local" {
		return hubEmpty(
			fmt.Sprintf("The hub at %s:%s is empty.", s.cfg.Get("HUB_HOST"), s.cfg.Get("HUB_PATH")),
			fmt.Sprintf("This machine has %d files, newest %s.", lc, humanTime(rd.lep)), "",
			"If the hub should have saves, something went wrong there - check it",
			"before overwriting. If this machine is the source of truth, run:",
			fmt.Sprintf("  %s push --force=local", prog))
	}
	// Never let an empty local directory wipe the hub. Not overridable.
	if rd.effective == decide.LocalEmptied || rd.effective == decide.FirstSeed {
		return fail.New(exitcode.ConflictFirstRun, "push",
			"this machine has 0 files and the hub has %d - refusing to empty the hub. If this machine's empty state is correct, delete the hub contents by hand on %s.", hc, s.cfg.Get("HUB_HOST"))
	}
	switch rd.verdict {
	case decide.InSync:
		s.say("already in sync - nothing to push")
		s.record("push", rd.lfp, rd.hfp)
		s.hubLock.Release()
		return nil
	case decide.HubEmpty:
		if s.opt.Force != "local" {
			return hubEmpty(
				fmt.Sprintf("The hub at %s:%s is empty.", s.cfg.Get("HUB_HOST"), s.cfg.Get("HUB_PATH")),
				fmt.Sprintf("This machine has %d files, newest %s.", lc, humanTime(rd.lep)), "",
				"Seeding the hub is a one-way decision, so it is not done silently.",
				"If these saves are the source of truth, run:",
				fmt.Sprintf("  %s push --force=local", prog))
		}
		s.say("seeding the empty hub with %d files from this machine", lc)
	case decide.FirstSeed:
		return fail.New(exitcode.ConflictFirstRun, "push",
			"this machine has no saves but the hub has %d files - pushing would wipe the hub. Run '%s pull' instead.", hc, prog)
	case decide.FirstRunConflict:
		if s.opt.Force != "local" {
			return s.conflictReport(exitcode.ConflictFirstRun, "push", "first-run conflict",
				"first run on this machine, and BOTH sides already have saves. This is a conflict, not a fresh start.", nil, rd.lm, rd.hm, rd.lep, rd.hep)
		}
		s.warn("--force=local: overwriting the hub's %d files with this machine's %d", hc, lc)
	case decide.DivergedState:
		return s.conflictReport(exitcode.Conflict, "push", "diverged state", "not deciding this for you.", divergedPre, rd.lm, rd.hm, rd.lep, rd.hep)
	case decide.BothChanged:
		if s.opt.Force != "local" {
			return s.conflictReport(exitcode.Conflict, "push", "both sides changed",
				"both sides changed since the last sync on this machine.", nil, rd.lm, rd.hm, rd.lep, rd.hep)
		}
		s.warn("--force=local: discarding hub changes")
	case decide.HubOnly:
		if s.opt.Force != "local" {
			return s.conflictReport(exitcode.Conflict, "push", "hub-only changes, refusing to push",
				"only the HUB changed since the last sync - pushing would discard those changes.", nil, rd.lm, rd.hm, rd.lep, rd.hep)
		}
		s.warn("--force=local: discarding hub changes")
	}
	s.t.MkdirHub()
	s.say("pushing %s -> %s:%s", s.local, s.cfg.Get("HUB_HOST"), s.cfg.Get("HUB_PATH"))
	if f := s.t.PushLocalToHub(s.local); f != nil {
		return f
	}
	hm, err := s.hub.Manifest()
	if err != nil {
		return s.afterTransferUnread("push", err)
	}
	hfp, _ := hm.Fingerprint()
	s.record("push", rd.lfp, hfp)
	s.hubLock.Release()
	if f := s.verify("push", rd.lfp, hfp); f != nil {
		return f
	}
	s.say("push complete - %d files on the hub", hm.Count())
	return nil
}

// dryRun is cmd_dry_run_plan: rsync -n -i for both directions, nothing written.
func (r *run) dryRun() {
	t := &transfer.T{Exclude: r.cfg.Exclude()}
	e := strings.Join(t.Excludes(), " ")
	sshE := "ssh " + r.hub.SSHOptsText
	plan := func(title, src, dst string) {
		r.say("  %s", title)
		args := []string{"-a", "-c", "-n", "-i", "--delete"}
		args = append(args, t.Excludes()...)
		if r.hub.IsLocal {
			r.say("    rsync -a -c --delete %s %s %s", e, src, dst)
		} else {
			r.say("    rsync -a -c --delete %s -e '%s' %s %s", e, sshE, src, dst)
			args = append(args, "-e", sshE)
		}
		out, _ := exec.Command("rsync", append(args, src, dst)...).CombinedOutput()
		for _, l := range strings.Split(strings.TrimRight(string(out), "\n"), "\n") {
			if l != "" {
				r.say("      %s", l)
			}
		}
		r.say("")
	}
	hubSide := r.cfg.Get("HUB_PATH") + "/"
	if !r.hub.IsLocal {
		hubSide = r.hub.Target() + ":" + hubSide
	}
	r.say("dry run - nothing will be written. Real rsync plans, both directions:")
	r.say("")
	plan("HUB -> LOCAL  (what 'sts pull' would do)", hubSide, r.local+"/")
	plan("LOCAL -> HUB  (what 'sts push' would do)", r.local+"/", hubSide)
	r.say("  In a real run each of these goes into a temp directory on the")
	r.say("  receiving side first, and the target is snapshotted before the swap.")
	r.log.Log("INFO", "dry-run", "printed both plans")
}
