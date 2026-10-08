package cli

import (
	"encoding/json"
	"fmt"
	"io"
	"strconv"
	"strings"
	"time"

	"github.com/moudlajs/star-traders-sync/internal/config"
	"github.com/moudlajs/star-traders-sync/internal/decide"
	"github.com/moudlajs/star-traders-sync/internal/exitcode"
	"github.com/moudlajs/star-traders-sync/internal/fail"
	"github.com/moudlajs/star-traders-sync/internal/hub"
	"github.com/moudlajs/star-traders-sync/internal/hubexec"
	"github.com/moudlajs/star-traders-sync/internal/lock"
	"github.com/moudlajs/star-traders-sync/internal/logx"
	"github.com/moudlajs/star-traders-sync/internal/manifest"
	"github.com/moudlajs/star-traders-sync/internal/platform"
	"github.com/moudlajs/star-traders-sync/internal/saves"
	"github.com/moudlajs/star-traders-sync/internal/state"
	"github.com/moudlajs/star-traders-sync/internal/tailscale"
)

type run struct {
	env     Env
	opt     Options
	cfg     *config.Config
	p       paths
	log     *logx.Logger
	out     io.Writer // say(): stdout, or stderr under --json
	json    io.Writer
	pid     int
	host    string
	local   string // LOCAL_SAVE_PATH, after a symlink is resolved
	hub     *hub.Hub
	lockLoc *lock.Local
	inPlay  bool // play's pull: LOCAL_ONLY is "nothing to fetch", not a refusal
	ex      *exiter
}

func (r *run) say(format string, a ...any) { fmt.Fprintf(r.out, format+"\n", a...) }

func hostnameShort() string { return platform.ShortHostname() }

func (r *run) prepare(now time.Time) *fail.Failure {
	l, f := lock.AcquireLocal(r.p.stateDir, r.opt.Command == "backup", r.pid, now, r.log)
	if f != nil {
		return f
	}
	r.lockLoc = l
	r.ex.add(l.Release)
	// Only after the local lock: before it, the sweep could delete a running sync's staging.
	if f := saves.RecoverOrphans(r.cfg.Get("LOCAL_SAVE_PATH"), r.opt.Command != "status", now, r.log); f != nil {
		return f
	}
	local, f := saves.CheckPath(r.cfg.Get("LOCAL_SAVE_PATH"), r.log, r.env.Stderr)
	if f != nil {
		return f
	}
	r.local = local

	bin, f := tailscale.Find(tailscale.AppPath(r.env.Getenv), r.env.LookPath, r.log)
	if f != nil {
		return f
	}
	ts := &tailscale.Client{Bin: bin, Log: r.log, Stderr: r.env.Stderr}
	st, _, f := ts.Status()
	if f != nil {
		return f
	}
	r.hub = &hub.Hub{Host: r.cfg.Get("HUB_HOST"), User: r.cfg.Get("HUB_USER"), Path: r.cfg.Get("HUB_PATH"),
		Exclude: r.cfg.Exclude(), Log: r.log, Stdout: r.out, Stderr: r.env.Stderr,
		SSHOpts:     hubexec.Options(r.cfg.Get("SSH_CONNECT_TIMEOUT"), r.cfg.Get("SSH_PORT"), r.cfg.Get("SSH_EXTRA_OPTS")),
		SSHOptsText: hubexec.OptionsText(r.cfg.Get("SSH_CONNECT_TIMEOUT"), r.cfg.Get("SSH_PORT"), r.cfg.Get("SSH_EXTRA_OPTS"))}
	if self, name := tailscale.HubIsSelf(st, r.hub.Host); self {
		r.hub.IsLocal, r.hub.EndpointKind, r.hub.Exec = true, "local", hubexec.Local{}
		r.log.Log("INFO", "hub", "this machine is the hub (%s) - using local paths, no ssh", name)
	} else {
		r.log.Log("DEBUG", "hub", "this machine is %s, hub is %s", name, r.hub.Host)
		if f := r.hub.Resolve(ts, r.cfg.Int("PREFER_MAGICDNS") == 1, r.opt.OfflineOK, hub.PingMagicDNS); f != nil {
			return f
		}
		r.hub.Exec = hubexec.SSH{Opts: r.hub.SSHOpts, Target: r.hub.Target()}
		if r.hub.EndpointKind != "offline" {
			if f := r.hub.CheckReachable(); f != nil {
				return f
			}
		}
	}
	if r.hub.EndpointKind == "offline" && r.opt.Command != "play" {
		return fail.New(exitcode.TSPeerOffline, "hub",
			"--offline-ok only applies to '%s play'; '%s' needs the hub, and %s is offline", prog, r.opt.Command, r.hub.Host)
	}
	if r.opt.DryRun {
		return nil // the caller prints the plan; nothing past this point runs
	}
	if r.hub.EndpointKind != "offline" {
		return r.hub.CheckPath(r.opt.Command == "push")
	}
	return nil
}

// sides reads both manifests, refusing (13) on anything unhashable (assert_manifest_hashable).
func (r *run) sides() (lm, hm manifest.Manifest, lfp, hfp string, f *fail.Failure) {
	lm, err := manifest.Build(r.local, r.cfg.Exclude())
	if err != nil {
		return lm, hm, "", "", fail.New(exitcode.LocalSaveBad, "manifest", "%v", err)
	}
	hm, err = r.hub.Manifest()
	if err != nil {
		return lm, hm, "", "", fail.New(exitcode.SSHFailed, "manifest", "reading the hub's files failed: %v", err)
	}
	for _, s := range []struct {
		m    manifest.Manifest
		side string
	}{{lm, "local"}, {hm, "hub"}} {
		if len(s.m.Unhashable) > 0 {
			r.log.Log("ERROR", "manifest", "unhashable file(s) on %s", s.side)
			lines := []string{fmt.Sprintf("error: some files on the %s side cannot be fingerprinted:", s.side)}
			for i, u := range s.m.Unhashable {
				if i == 5 {
					break
				}
				lines = append(lines, "  "+u)
			}
			lines = append(lines, "", "Without a fingerprint their contents cannot be compared, so sts",
				"cannot tell whether they changed. Rename or remove them.")
			return lm, hm, "", "", fail.Printed(exitcode.LocalSaveBad, "manifest", "", lines...)
		}
	}
	lfp, _ = lm.Fingerprint()
	hfp, _ = hm.Fingerprint()
	return lm, hm, lfp, hfp, nil
}

func campaignSaves(m manifest.Manifest) (n int, paths []string) {
	for _, l := range m.Lines {
		f := strings.Fields(l)
		if len(f) >= 3 && isGameSave(f[2]) {
			n++
			paths = append(paths, f[2])
		}
	}
	return n, paths
}

// isGameSave is grep 'game_[0-9]*\.db$': game_ then digits (or none) then .db.
func isGameSave(p string) bool {
	i := strings.LastIndex(p, "game_")
	if i < 0 || !strings.HasSuffix(p, ".db") {
		return false
	}
	mid := p[i+len("game_") : len(p)-len(".db")]
	return strings.Trim(mid, "0123456789") == ""
}

func humanTime(epoch int64) string {
	if epoch <= 0 {
		return "never"
	}
	return time.Unix(epoch, 0).Format("2006-01-02 15:04:05")
}

func (r *run) describeSide(label string, m manifest.Manifest, epoch int64) {
	n, paths := campaignSaves(m)
	r.say("  %s", label)
	r.say("    files:     %d (%d campaign saves)", m.Count(), n)
	r.say("    newest:    %s", humanTime(epoch))
	if len(paths) > 0 {
		r.say("    campaigns: %s ", strings.Join(paths, " "))
	}
}

func short(fp string, n int) string {
	if len(fp) > n {
		return fp[:n]
	}
	return fp
}

// status is cmd_status: read-only, both sides, no hub lock.
func (r *run) status() *fail.Failure {
	lm, hm, lfp, hfp, f := r.sides()
	if f != nil {
		return f
	}
	lep, hep := hub.NewestLocal(r.local), r.hub.Newest()
	st := state.Read(r.p.stateFile, r.cfg.Get("HUB_HOST"), r.cfg.Get("HUB_PATH"))

	verdict := "differ"
	switch {
	case lfp == hfp:
		verdict = "in_sync"
	case hfp == "empty":
		verdict = "hub_empty"
	case lfp == "empty":
		verdict = "local_empty"
	case lep > hep:
		verdict = "local_newer"
	case hep > lep:
		verdict = "hub_newer"
	}
	decision := decide.Effective(decide.Side{FP: lfp, Count: lm.Count()}, decide.Side{FP: hfp, Count: hm.Count()}, st)
	lockinfo := r.hub.LockInfo()
	gp := pgrep(r.cfg.Get("GAME_PROCESS_NAME"))

	if r.opt.JSON {
		r.statusJSON(lm, hm, lfp, hfp, lep, hep, st, verdict, lockinfo, gp, decision)
		r.log.Log("INFO", "status", "json local=%s hub=%s", short(lfp, 12), short(hfp, 12))
		return nil
	}
	isHub := ""
	if r.hub.IsLocal {
		isHub = " (IS the hub)"
	}
	via := r.hub.EndpointKind
	if r.hub.Endpoint != "" {
		via += " (" + r.hub.Endpoint + ")"
	}
	r.say("%s status", prog)
	r.say("")
	r.say("  this machine : %s%s", r.host, isHub)
	r.say("  tailscale    : Running, hub via %s", via)
	r.say("")
	r.describeSide("LOCAL  "+r.local, lm, lep)
	r.say("    fingerprint: %s", short(lfp, 16))
	r.say("")
	r.describeSide("HUB    "+r.cfg.Get("HUB_HOST")+":"+r.cfg.Get("HUB_PATH"), hm, hep)
	r.say("    fingerprint: %s", short(hfp, 16))
	r.say("")
	switch verdict {
	case "in_sync":
		r.say("  verdict      : in sync")
	case "hub_empty":
		r.say("  verdict      : the hub is EMPTY - seed it with 'sts push --force=local'")
	case "local_empty":
		r.say("  verdict      : this machine is EMPTY - 'sts pull' would first-seed it")
	case "local_newer":
		r.say("  verdict      : LOCAL is newer by %ds", lep-hep)
	case "hub_newer":
		r.say("  verdict      : HUB is newer by %ds", hep-lep)
	default:
		r.say("  verdict      : differ, but timestamps are equal - trust the fingerprints")
	}
	next := map[decide.Decision]string{
		decide.InSync:           "nothing to do",
		decide.HubOnly:          "pull copies the hub's changes here",
		decide.FirstSeed:        "pull first-seeds this machine from the hub",
		decide.LocalOnly:        "push sends this machine's changes; pull would refuse",
		decide.HubEmpty:         "seed the hub with 'sts push --force=local'",
		decide.BothChanged:      "CONFLICT - both changed, choose with --force",
		decide.FirstRunConflict: "CONFLICT - first run with saves on both sides, choose with --force",
		decide.LocalEmptied:     "this machine's saves are gone - restore them with 'sts pull --force=hub'",
	}[decision]
	if next == "" {
		next = "refused both ways, and --force does not override it - see 'diverged sync state' in docs/troubleshooting.md"
	}
	r.say("  next sync    : %s", next)
	if st.FirstRun {
		r.say("  last sync    : never recorded on this machine (first run)")
	} else {
		at, _ := strconv.ParseInt(st.Epoch, 10, 64)
		r.say("  last sync    : %s at %s", st.Direction, humanTime(at))
	}
	if lockinfo != "" {
		r.say("  hub lock     : HELD by %s", lockinfo)
	} else {
		r.say("  hub lock     : free")
	}
	if gp != "" {
		r.say("  game         : RUNNING (pid %s) - push and pull will refuse", gp)
	} else {
		r.say("  game         : not running")
	}
	r.log.Log("INFO", "status", "local=%s hub=%s", short(lfp, 12), short(hfp, 12))
	return nil
}

// pgrep is 'pgrep -x NAME | tr "\n" " "': each pid followed by a space.
func pgrep(name string) string {
	var s string
	for _, p := range platform.ProcessIDs(name) {
		s += p + " "
	}
	return s
}

type jsonSide struct {
	Path          string `json:"path"`
	Files         int    `json:"files"`
	CampaignSaves int    `json:"campaign_saves"`
	Newest        int64  `json:"newest"`
	Fingerprint   string `json:"fingerprint"`
}

type jsonLast struct {
	Direction string `json:"direction"`
	At        int64  `json:"at"`
}

type jsonStatus struct {
	Version string `json:"version"`
	Machine string `json:"machine"`
	IsHub   bool   `json:"is_hub"`
	Hub     struct {
		Host         string `json:"host"`
		Path         string `json:"path"`
		EndpointKind string `json:"endpoint_kind"`
	} `json:"hub"`
	Sides struct {
		Local jsonSide `json:"local"`
		Hub   jsonSide `json:"hub"`
	} `json:"sides"`
	Verdict     string    `json:"verdict"`
	Decision    string    `json:"decision"`
	LastSync    *jsonLast `json:"last_sync"`
	HubLock     *string   `json:"hub_lock"`
	GameRunning bool      `json:"game_running"`
}

// statusJSON writes status_json's object in its key order and indent=2 shape; the app parses it.
func (r *run) statusJSON(lm, hm manifest.Manifest, lfp, hfp string, lep, hep int64, st decide.State,
	verdict, lockinfo, gp string, decision decide.Decision) {
	var j jsonStatus
	j.Version, j.Machine, j.IsHub = Version, r.host, r.hub.IsLocal
	j.Hub.Host, j.Hub.Path, j.Hub.EndpointKind = r.cfg.Get("HUB_HOST"), r.cfg.Get("HUB_PATH"), r.hub.EndpointKind
	ln, _ := campaignSaves(lm)
	hn, _ := campaignSaves(hm)
	// check_local_save_path resolved a symlink, so the script reports the resolved path.
	j.Sides.Local = jsonSide{r.local, lm.Count(), ln, lep, lfp}
	j.Sides.Hub = jsonSide{r.cfg.Get("HUB_PATH"), hm.Count(), hn, hep, hfp}
	j.Verdict, j.Decision = verdict, string(decision)
	if !st.FirstRun {
		at, _ := strconv.ParseInt(st.Epoch, 10, 64)
		j.LastSync = &jsonLast{st.Direction, at}
	}
	if l := strings.TrimSpace(lockinfo); l != "" {
		j.HubLock = &l
	}
	j.GameRunning = strings.TrimSpace(gp) != ""
	enc := json.NewEncoder(r.json)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	_ = enc.Encode(j)
}
