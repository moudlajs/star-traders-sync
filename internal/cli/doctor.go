package cli

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/moudlajs/star-traders-sync/internal/config"
	"github.com/moudlajs/star-traders-sync/internal/fail"
	"github.com/moudlajs/star-traders-sync/internal/hub"
	"github.com/moudlajs/star-traders-sync/internal/hubexec"
	"github.com/moudlajs/star-traders-sync/internal/lock"
	"github.com/moudlajs/star-traders-sync/internal/logx"
	"github.com/moudlajs/star-traders-sync/internal/tailscale"
)

// Hub-side snippets doctor sends, verbatim from the script (pinned by
// TestDoctorSnippetsMatchTheScript).
const (
	doctorProbeScript = "\n        d=\"$1\"\n        [ -e \"$d\" ] || { echo NOENT; exit 0; }\n        [ -d \"$d\" ] || { echo NOTDIR; exit 0; }\n        [ -w \"$d\" ] || { echo NOWRITE; exit 0; }\n        echo OK\n    "
	doctorBusyScript  = `[ -d "$1" ]`
	doctorMkdirScript = `mkdir -p "$1"`
)

// doctor is cmd_doctor: every check, none of them aborting, one report. It
// prints what the script prints, line for line: the app reads this text
// (DoctorReport.swift), and tests/parity.sh diffs the two.
//
// Read-only unless --fix, and --fix only does what is safe, reversible and
// idempotent. It never accepts a host key, changes system settings, or
// grants permissions.
type doctor struct {
	env Env
	out io.Writer
	fix bool
	p   paths
	log *logx.Logger
	cfg *config.Config

	nFail, nWarn, nFixed, nSkip, nFixable int

	tsBin                  string
	tsOK, isHub            bool
	hubDNS, hubIP          string
	endpoint, endpointKind string
}

func (d *doctor) line(format string, a ...any) { fmt.Fprintf(d.out, format+"\n", a...) }
func (d *doctor) section(s string)             { d.line("\n  %s", s) }
func (d *doctor) ok(format string, a ...any)   { d.line("    ok    "+format, a...) }
func (d *doctor) note(format string, a ...any) {
	d.line("    note  "+format, a...)
}
func (d *doctor) warn(format string, a ...any) { d.nWarn++; d.line("    warn  "+format, a...) }
func (d *doctor) fail(format string, a ...any) { d.nFail++; d.line("    FAIL  "+format, a...) }
func (d *doctor) fixed(format string, a ...any) {
	d.nFixed++
	d.line("    fixed "+format, a...)
}
func (d *doctor) skip(what string) { d.nSkip++; d.line("    --    skipped, needs: %s", what) }

// do is the indented remediation under a finding.
func (d *doctor) do(format string, a ...any) { d.line("          "+format, a...) }

// try is doc_try: run a repair only under --fix, and otherwise say what
// --fix would do, so a dry doctor still teaches.
func (d *doctor) try(what string, repair func() bool) bool {
	if d.fix {
		if repair() {
			d.fixed("%s", what)
			return true
		}
		d.fail("could not %s", what)
		return false
	}
	d.nFixable++
	d.do("sts doctor --fix   will: %s", what)
	return false
}

func whoami() string {
	if u, err := user.Current(); err == nil {
		return u.Username
	}
	return "this user"
}

// The script's test(1) checks, which use access(2) rather than mode bits.
func canRead(p string) bool { return syscall.Access(p, 4) == nil }
func canExec(p string) bool { return syscall.Access(p, 1) == nil }
func isDir(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.IsDir()
}
func isFile(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.Mode().IsRegular()
}
func exists(p string) bool { _, err := os.Stat(p); return err == nil }

// runOK runs a command for its exit status only.
func runOK(name string, args ...string) bool { return exec.Command(name, args...).Run() == nil }

// fileMentions is grep -qF.
func fileMentions(path, s string) bool {
	b, err := os.ReadFile(path)
	return err == nil && strings.Contains(string(b), s)
}

// countFiles is "find DIR/ -maxdepth 1 -type f | grep -c .": regular files
// directly inside, a symlinked directory followed.
func countFiles(dir string) int {
	ents, err := os.ReadDir(dir)
	if err != nil {
		return 0
	}
	n := 0
	for _, e := range ents {
		if e.Type().IsRegular() {
			n++
		}
	}
	return n
}

// runDoctor is main()'s doctor branch: it runs before every other check,
// because the things those checks abort on are what it exists to report.
func runDoctor(env Env, o Options, p paths, log *logx.Logger) int {
	d := &doctor{env: env, out: env.Stdout, fix: o.Fix, p: p, log: log}
	d.line("%s %s - checking this machine", prog, Version)
	if d.fix {
		d.line("(--fix: safe repairs will be applied)")
	}

	d.environment()
	if d.config() {
		d.stateDirs()
		d.saveDir()
		if d.tailscale() {
			d.ssh()
			d.hubOnly()
		} else {
			d.section("ssh to the hub")
			d.skip("a working tailscale")
		}
	} else {
		d.section("everything else")
		d.skip("a valid config")
		d.line("    --    nothing else can be checked until the config is right")
	}

	d.line("")
	if d.nFail == 0 && d.nWarn == 0 {
		d.line("  Everything checks out. Try:  sts status")
	} else {
		s := fmt.Sprintf("  %d problem(s), %d warning(s)", d.nFail, d.nWarn)
		if d.nFixed > 0 {
			s += fmt.Sprintf(", %d fixed", d.nFixed)
		}
		if d.nSkip > 0 {
			s += fmt.Sprintf(", %d check(s) skipped", d.nSkip)
		}
		d.line("%s", s)
		if !d.fix && d.nFixable > 0 {
			d.line("  %d of these can be repaired automatically:  sts doctor --fix", d.nFixable)
		} else if !d.fix && d.nFail > 0 {
			d.line("  None of these can be repaired automatically; follow the steps above.")
		}
		d.line(`  Nothing above was changed except where it says "fixed".`)
	}
	d.line("")

	d.log.Log("INFO", "doctor", "fail=%d warn=%d fixed=%d skipped=%d", d.nFail, d.nWarn, d.nFixed, d.nSkip)
	if d.nFail == 0 {
		return 0
	}
	return 1
}

func (d *doctor) environment() {
	d.section("environment")

	if d.env.Geteuid() == 0 {
		d.fail("running as root")
		d.do("run as your normal user; root would leave files you cannot rewrite")
	} else {
		d.ok("running as %s, not root", whoami())
	}

	// The hub side runs the script's snippets under bash, here too when
	// this machine is the hub.
	out, err := exec.Command("/bin/bash", "-c",
		`printf '%s %s %s' "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}" "$BASH_VERSION"`).Output()
	f := strings.Fields(string(out))
	if err != nil || len(f) != 3 {
		d.fail("/bin/bash is missing or would not run")
	} else if maj, _ := strconv.Atoi(f[0]); maj < 3 || maj == 3 && atoi(f[1]) < 2 {
		d.fail("bash %s is too old, 3.2 required", f[2])
	} else {
		d.ok("bash %s.%s", f[0], f[1])
	}

	var missing string
	for _, t := range []string{"rsync", "ssh", "python3", "shasum", "cpio"} {
		if _, err := d.env.LookPath(t); err != nil {
			missing += " " + t
		}
	}
	if missing != "" {
		d.fail("not on PATH:%s", missing)
		d.do("these ship with macOS; python3 needs the Xcode command line tools:")
		d.do("    xcode-select --install")
	} else {
		d.ok("rsync, ssh, python3, shasum, cpio")
		v, _ := exec.Command("rsync", "--version").CombinedOutput()
		if first, _, _ := strings.Cut(string(v), "\n"); strings.Contains(first, "openrsync") {
			d.note("rsync is openrsync (macOS built-in)")
		}
	}

	home := d.env.Getenv("HOME")
	zshrc := home + "/.zshrc"
	if strings.Contains(":"+d.env.Getenv("PATH")+":", ":"+home+"/bin:") {
		d.ok("~/bin is on PATH")
	} else if isFile(zshrc) && fileMentions(zshrc, "HOME/bin") {
		// Configured, but this shell started before it: telling them to
		// add the line again would be wrong.
		d.warn("~/bin is in ~/.zshrc but not in this shell's PATH")
		d.do("this shell started before the line was added. Open a new one, or:")
		d.do("    exec zsh")
	} else {
		d.warn("~/bin is not on PATH, so 'sts' will not resolve")
		if d.fix {
			d.fixPath(zshrc)
		} else {
			d.nFixable++
			d.do("sts doctor --fix   will append to ~/.zshrc (with a backup):")
			d.do(`    export PATH="$HOME/bin:$PATH"`)
		}
	}

	link := home + "/bin/sts"
	if st, err := os.Lstat(link); err == nil && st.Mode()&os.ModeSymlink != 0 {
		tgt, _ := os.Readlink(link)
		if canExec(tgt) {
			d.ok("sts -> %s", tgt)
		} else {
			d.fail("~/bin/sts points at %s, which is missing or not executable", tgt)
			d.do("re-run ./install.sh from the repository")
		}
	} else if exists(link) {
		d.warn("~/bin/sts exists but is not a symlink; install.sh will not touch it")
	} else {
		d.warn("sts is not installed in ~/bin")
		d.do("run ./install.sh from the repository")
	}
}

func atoi(s string) int { n, _ := strconv.Atoi(s); return n }

// fixPath appends one line to ~/.zshrc, keeping a backup and showing it:
// reversible and idempotent, so --fix may do it.
func (d *doctor) fixPath(rc string) {
	if isFile(rc) && fileMentions(rc, "HOME/bin") {
		d.note("~/.zshrc already mentions ~/bin; not adding it twice")
		d.do(`open a new shell, or: export PATH="$HOME/bin:$PATH"`)
		return
	}
	if isFile(rc) {
		b, err := os.ReadFile(rc)
		if err == nil {
			err = os.WriteFile(rc+".sts-backup", b, 0o644)
		}
		if err != nil {
			d.fail("could not back up %s, so it was not changed", rc)
			return
		}
	}
	fh, err := os.OpenFile(rc, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err == nil {
		_, err = io.WriteString(fh, "\n# star-traders-sync: sts and star-traders-sync live in ~/bin\nexport PATH=\"$HOME/bin:$PATH\"\n")
		if cerr := fh.Close(); err == nil {
			err = cerr
		}
	}
	if err != nil {
		d.fail("could not write %s", rc)
		return
	}
	d.fixed("appended to ~/.zshrc (backup at ~/.zshrc.sts-backup)")
	d.do("open a new shell, or: exec zsh")
}

// refusalLines is a refusal as die prints it, less its "exit code" line
// and "error: " prefixes: what doctor shows under the finding.
func refusalLines(f *fail.Failure) []string {
	lines := f.Lines
	if lines == nil {
		lines = []string{"error: " + f.Msg}
	}
	var out []string
	for _, l := range lines {
		if l = strings.TrimPrefix(l, "error: "); l != "" && !strings.HasPrefix(l, "exit code") {
			out = append(out, l)
		}
	}
	return out
}

// config is doc_config. It asks the real parser and validator rather than
// mirroring their rules, so doctor cannot pass a config push would refuse.
func (d *doctor) config() bool {
	d.section("config")
	file := d.p.configFile
	if !exists(file) {
		d.fail("no config at %s", file)
		d.do("run ./install.sh from the repository, which writes a starting one")
		return false
	}
	if !canRead(file) {
		d.fail("%s is not readable by %s", file, whoami())
		return false
	}
	d.ok("%s", file)

	cfg, f := config.Load(file, d.env.Getenv("HOME"))
	if f != nil {
		d.log.Log("ERROR", f.Step, "exit=%d %s", f.Code, f.Msg)
		d.fail("config cannot be parsed")
		for _, l := range refusalLines(f) {
			d.do("%s", l)
		}
		d.do("the file is parsed, not sourced - no shell syntax, see config.example")
		return false
	}
	d.cfg = cfg
	d.log.Level = cfg.Get("LOG_LEVEL")
	d.log.Log("DEBUG", "config", "loaded %s", file)

	// Placeholders are the single most common half-finished install.
	var placeholders string
	for _, k := range []string{"HUB_HOST", "HUB_USER", "HUB_PATH", "BACKUP_VOLUME", "BACKUP_DEST"} {
		if isPlaceholder(cfg.Get(k)) {
			placeholders += " " + k
		}
	}
	if placeholders != "" {
		d.fail("still set to the example placeholders:%s", placeholders)
		d.do("edit %s", file)
		d.do("HUB_HOST is the tailscale node name of the machine hosting the hub")
		d.do("  see: tailscale status")
		d.do("HUB_USER is your account name ON THAT machine")
		return false
	}

	var missing string
	for _, k := range []string{"HUB_HOST", "HUB_USER", "HUB_PATH", "LOCAL_SAVE_PATH", "STEAM_APPID",
		"GAME_PROCESS_NAME", "BACKUP_VOLUME", "BACKUP_DEST"} {
		if cfg.Get(k) == "" {
			missing += " " + k
		}
	}
	if missing != "" {
		d.fail("required keys missing or empty:%s", missing)
		d.do("edit %s", file)
		return false
	}
	d.ok("all required keys set")

	if f := cfg.Validate(); f != nil {
		d.log.Log("ERROR", f.Step, "exit=%d %s", f.Code, f.Msg)
		d.fail("config is not valid")
		for _, l := range refusalLines(f) {
			d.do("%s", l)
		}
		return false
	}
	d.ok("config passes every validation rule")
	return true
}

// isPlaceholder: still what config.example or install.sh ships.
func isPlaceholder(v string) bool {
	for _, p := range []string{"my-mac-mini", "my-macbook", "youruser", "YourDisk", "tailnet-name"} {
		if strings.Contains(v, p) {
			return true
		}
	}
	return strings.HasPrefix(v, "/Volumes/Backup")
}

func (d *doctor) stateDirs() {
	d.section("state and logs")
	for _, dir := range []string{filepath.Dir(d.p.configFile), d.p.stateDir, filepath.Dir(d.p.logFile)} {
		switch {
		case isDir(dir) && writable(dir):
			d.ok("%s", dir)
		case exists(dir):
			d.fail("%s exists but is not a writable directory", dir)
		default:
			if !d.try("create "+dir, func() bool { return os.MkdirAll(dir, 0o755) == nil }) {
				d.warn("%s does not exist yet", dir)
			}
		}
	}

	// A leaked local lock wedges every later run, and is safe to clear
	// once its owner is gone.
	lockDir := filepath.Join(d.p.stateDir, "local.lock.d")
	pidFile := filepath.Join(d.p.stateDir, "local.lock")
	if !isDir(lockDir) {
		d.ok("no stale local lock")
		return
	}
	// Judged and cleared under the flock a Go run holds, so no run can take
	// the lock between the checks below and the removal.
	release, busy := lock.HoldLocal(d.p.stateDir, d.fix)
	defer release()
	b, _ := os.ReadFile(pidFile)
	holder := strings.TrimRight(string(b), "\n")
	if holder == "" || !onlyDigits(holder) {
		holder = ""
	}
	if pid, _ := strconv.Atoi(holder); holder != "" && (busy || syscall.Kill(pid, 0) == nil) {
		d.note("another sts is running right now (pid %s)", holder)
		return
	}
	if busy {
		d.note("another sts is starting right now")
		return
	}
	// A run between its mkdir and its pid write: the pid file is empty or
	// still names the run before. Never cleared, as lock.AcquireLocal
	// refuses it too (#151).
	if st, err := os.Stat(lockDir); err == nil && time.Since(st.ModTime()) < 10*time.Second {
		d.note("another sts is starting right now")
		return
	}
	owner := holder
	if owner == "" {
		owner = "unknown"
	}
	d.warn("a stale local lock is present (owner %s is gone)", owner)
	d.try("clear the stale local lock", func() bool {
		return os.RemoveAll(lockDir) == nil && os.RemoveAll(pidFile) == nil
	})
}

func onlyDigits(s string) bool {
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

func (d *doctor) saveDir() {
	d.section("game")
	p := d.cfg.Get("LOCAL_SAVE_PATH")
	if !exists(p) {
		d.fail("save directory does not exist: %s", p)
		d.do("launch the game once so it creates it, then re-run")
		d.do("if the path is wrong, find the real one:")
		d.do("    ls -la ~/Library | grep -i star")
		return
	}
	if !isDir(p) {
		d.fail("%s is not a directory", p)
		return
	}
	if n := countFiles(p); n == 0 {
		d.warn("save directory is empty: %s", p)
		d.do("launch the game once, or check the path is right")
	} else {
		d.ok("save directory, %d files", n)
	}

	// The appid is checkable without launching anything.
	appid := d.cfg.Get("STEAM_APPID")
	libs := []string{d.env.Getenv("HOME") + "/Library/Application Support/Steam"}
	vols, _ := filepath.Glob("/Volumes/*/SteamLibrary")
	found := false
	for _, lib := range append(libs, vols...) {
		if isFile(lib + "/steamapps/appmanifest_" + appid + ".acf") {
			found = true
			break
		}
	}
	if found {
		d.ok("Steam appid %s is installed", appid)
	} else {
		d.warn("no Steam manifest found for appid %s", appid)
		d.do("sts play needs it; pull and push do not")
		d.do("check with: open steam://rungameid/%s", appid)
	}
}

// hubExec runs a snippet where the hub lives.
func (d *doctor) hubExec() hubexec.Exec {
	if d.isHub {
		return hubexec.Local{}
	}
	return hubexec.SSH{Opts: d.sshOpts(), Target: d.target()}
}

func (d *doctor) sshOpts() []string {
	return hubexec.Options(d.cfg.Get("SSH_CONNECT_TIMEOUT"), d.cfg.Get("SSH_PORT"), d.cfg.Get("SSH_EXTRA_OPTS"))
}

func (d *doctor) target() string { return d.cfg.Get("HUB_USER") + "@" + d.endpoint }

func (d *doctor) reproCmd() string {
	return "ssh " + hubexec.OptionsText(d.cfg.Get("SSH_CONNECT_TIMEOUT"), d.cfg.Get("SSH_PORT"),
		d.cfg.Get("SSH_EXTRA_OPTS")) + " " + d.target()
}

// hubBusy is hub_is_busy: is a sync in progress on the hub? doctor takes no
// locks, so --fix must not create HUB_PATH while a swap has it renamed
// aside: the swap's "mv staged hub" would then move INTO the new empty
// directory, exit 0, and the pre-swap copy would be deleted.
func (d *doctor) hubBusy() bool {
	l := (&lock.Hub{HubPath: d.cfg.Get("HUB_PATH")}).Path()
	if d.isHub {
		return isDir(l)
	}
	_, err := d.hubExec().Run(doctorBusyScript, l)
	return err == nil
}

// tsJSON is the slice of tailscale status --json doctor reads, decoded the
// way the script's python does.
type tsJSON struct {
	BackendState string
	Self         *struct{ HostName, DNSName string }
}

func (d *doctor) tailscale() bool {
	d.section("tailscale")

	app := tailscale.AppPath(d.env.Getenv)
	if canExec(app) {
		d.tsBin = app
		d.ok("found the App Store app")
	} else if p, err := d.env.LookPath("tailscale"); err == nil {
		d.tsBin = p
		d.ok("found %s", p)
	} else {
		d.fail("tailscale is not installed")
		d.do("install the Tailscale app from the App Store, or: brew install tailscale")
		return false
	}

	// stdout only: a warning on stderr must not be read as the JSON.
	raw, err := exec.Command(d.tsBin, "status", "--json").Output()
	if err != nil {
		d.fail("tailscaled is not running")
		d.do("start the Tailscale app, or: sudo tailscaled install-system-daemon")
		return false
	}
	var j tsJSON
	if json.Unmarshal(raw, &j) != nil || j.BackendState == "" {
		d.fail("could not read tailscale status - the output was not valid JSON")
		d.do("check it by hand: %s status --json | head -3", d.tsBin)
		return false
	}
	if j.BackendState != "Running" {
		d.fail("tailscale is %s, not Running", j.BackendState)
		d.do("log in:  %s up", d.tsBin)
		d.do("this is interactive and opens a browser, so doctor will not do it for you")
		return false
	}
	if j.Self == nil || j.Self.HostName == "" {
		d.fail("tailscale is running but did not report this machine's name")
		return false
	}
	d.ok("running, this machine is '%s'", j.Self.HostName)

	// The same comparison every other command uses, so doctor cannot reach
	// a different verdict than push and pull do.
	st := &tailscale.Status{}
	_ = json.Unmarshal(raw, st)
	if self, _ := tailscale.HubIsSelf(st, d.cfg.Get("HUB_HOST")); self {
		d.isHub = true
		d.ok("this machine IS the hub, so no ssh is involved")
		d.tsOK = true
		return true
	}

	host := d.cfg.Get("HUB_HOST")
	peer, found := tailscale.FindPeer(st, host)
	if !found {
		d.fail("hub '%s' is not in this tailnet at all", host)
		d.do("check HUB_HOST against the node names in:")
		d.do("    %s status", d.tsBin)
		d.do("both machines must be on the SAME tailnet; Apple IDs are irrelevant")
		return false
	}
	d.hubDNS, d.hubIP = peer.DNS, peer.IP
	if !peer.Online {
		d.fail("hub '%s' is in the tailnet but offline", host)
		d.do("wake it, or check Tailscale is running there")
		return false
	}
	d.ok("hub '%s' is online at %s", host, d.hubIP)

	if d.hubDNS != "" && hub.PingMagicDNS(d.hubDNS) {
		d.endpoint, d.endpointKind = d.hubDNS, "magicdns"
		d.ok("MagicDNS resolves: %s", d.hubDNS)
	} else {
		d.endpoint, d.endpointKind = d.hubIP, "tailnet-ip"
		d.note("MagicDNS does not resolve here, using the tailnet IP %s", d.hubIP)
		d.note("normal when tailscaled came from Homebrew; not a problem")
	}

	if runOK(d.tsBin, "ping", "--c", "2", "--timeout", "5s", d.hubIP) {
		d.ok("tailscale ping reaches the hub")
	} else {
		d.fail("hub says online but tailscale ping fails")
		d.do("    %s ping %s", d.tsBin, d.hubIP)
		return false
	}
	d.tsOK = true
	return true
}

func (d *doctor) ssh() {
	d.section("ssh to the hub")
	if d.isHub {
		d.ok("not needed, this machine is the hub")
		return
	}
	if !d.tsOK {
		d.skip("a reachable hub")
		return
	}

	key := d.env.Getenv("HOME") + "/.ssh/id_ed25519"
	if isFile(key) {
		d.ok("ssh key %s", key)
	} else {
		d.warn("no ssh key at %s", key)
		comment := "sts@" + hostnameShort()
		if !d.try("generate an ssh key", func() bool {
			return runOK("ssh-keygen", "-t", "ed25519", "-N", "", "-C", comment, "-f", key)
		}) {
			d.do(`or by hand: ssh-keygen -t ed25519 -C "%s"`, comment)
			return
		}
	}

	// Never accepted automatically - but if the same machine is already
	// trusted under its other address, the comparison is done for them.
	if runOK("ssh-keygen", "-F", d.endpoint) {
		d.ok("host key for %s is trusted", d.endpoint)
	} else {
		d.fail("host key for %s is not trusted yet", d.endpoint)
		h := &hub.Hub{Host: d.cfg.Get("HUB_HOST"), DNS: d.hubDNS, IP: d.hubIP, Log: d.log}
		for _, l := range h.HostKeyHelp(d.endpoint) {
			d.line("          %s", l)
		}
		d.skip("a trusted host key")
		return
	}

	raw, err := exec.Command("ssh", append(d.sshOpts(), d.target(), "echo STS_OK")...).CombinedOutput()
	out := strings.TrimRight(string(raw), "\n")
	if err == nil && out == "STS_OK" {
		d.ok("key auth works: %s", d.target())
	} else {
		d.fail("cannot ssh to the hub without a password")
		switch {
		case strings.Contains(out, "Permission denied"):
			d.do("your key is not on the hub yet. Run, and enter the HUB's password:")
			d.do("    ssh-copy-id -i %s/.ssh/id_ed25519.pub %s", d.env.Getenv("HOME"), d.target())
			d.do("doctor will not do this: it needs a password it must not handle")
		case strings.Contains(out, "Connection refused"):
			d.do("Remote Login is off on the hub. On the hub:")
			d.do("    System Settings > General > Sharing > Remote Login")
			d.do("then check your user is allowed:")
			d.do("    dseditgroup -o checkmember -m %s com.apple.access_ssh", d.cfg.Get("HUB_USER"))
		default:
			first, _, _ := strings.Cut(out, "\n")
			d.do("ssh said: %s", first)
			d.do("reproduce it by hand: %s", d.reproCmd())
		}
		d.skip("working ssh")
		return
	}

	// A connection that drops between the auth probe and this one must not
	// end the report: that is exactly when doctor gets run.
	hubPath := d.cfg.Get("HUB_PATH")
	probe, err := d.hubExec().Run(doctorProbeScript, hubPath)
	if err != nil {
		first, _, _ := strings.Cut(strings.TrimRight(probe, "\n"), "\n")
		d.fail("lost the connection while probing the hub directory")
		d.do("%s", first)
		d.do("re-run when the hub is reachable: %s", d.reproCmd())
		return
	}
	host := d.cfg.Get("HUB_HOST")
	switch {
	case strings.Contains(probe, "OK"):
		d.ok("hub directory %s is writable", hubPath)
	case strings.Contains(probe, "NOENT"):
		d.warn("hub directory does not exist yet: %s", hubPath)
		if d.hubBusy() {
			d.do("a sync is running on the hub right now - not creating it")
			d.do("re-run once that finishes")
		} else if !d.try("create "+hubPath+" on "+host, func() bool {
			_, err := d.hubExec().Run(doctorMkdirScript, hubPath)
			return err == nil
		}) {
			d.do("or seed it: sts push --force=local")
		}
	case strings.Contains(probe, "NOTDIR"):
		d.fail("%s exists on the hub but is not a directory", hubPath)
	case strings.Contains(probe, "NOWRITE"):
		d.fail("%s cannot write %s on the hub", d.cfg.Get("HUB_USER"), hubPath)
	default:
		d.fail("could not probe the hub directory: %s", strings.TrimRight(probe, "\n"))
	}
}

var lastExit = regexp.MustCompile(`last exit code = [0-9]+`)

func (d *doctor) hubOnly() {
	if !d.isHub {
		return
	}
	d.section("hub duties (this machine)")

	hubPath := d.cfg.Get("HUB_PATH")
	switch {
	case isDir(hubPath):
		d.ok("hub directory, %d files", countFiles(hubPath))
	case d.hubBusy():
		d.warn("hub directory does not exist yet: %s", hubPath)
		d.do("a sync is running right now, which moves it aside briefly")
		d.do("not creating it - that would turn the in-flight swap into a nested move")
		d.do("re-run once the sync finishes")
	default:
		d.warn("hub directory does not exist yet: %s", hubPath)
		if !d.try("create "+hubPath, func() bool { return os.MkdirAll(hubPath, 0o755) == nil }) {
			d.do("or seed it from the machine holding the saves: sts push --force=local")
		}
	}

	vol := d.cfg.Get("BACKUP_VOLUME")
	if volumeMounted(vol) {
		d.ok("backup volume %s is mounted and writable", vol)
		info, _ := exec.Command("diskutil", "info", vol).Output()
		var fs []string
		for _, l := range strings.Split(string(info), "\n") {
			if strings.Contains(l, "File System Personality") {
				if f := strings.Fields(l); len(f) > 0 {
					fs = append(fs, f[len(f)-1])
				}
			}
		}
		switch strings.Join(fs, "\n") {
		case "ExFAT", "MS-DOS", "FAT32":
			d.note("the backup volume has no hard links, so each backup is a full copy")
		}
	} else {
		d.warn("backup volume %s is not mounted", vol)
		d.do("plug the disk in; sts backup refuses rather than writing to the internal disk")
	}

	const label = "com.github.moudlajs.star-traders-sync.backup"
	job := fmt.Sprintf("gui/%d/%s", os.Getuid(), label)
	printed, err := exec.Command("launchctl", "print", job).Output()
	if err != nil {
		d.warn("the daily backup job is not installed")
		d.do("./launchd/install-backup-job.sh")
		return
	}
	var codes []string
	for _, m := range lastExit.FindAllString(string(printed), -1) {
		codes = append(codes, m[strings.LastIndex(m, " ")+1:])
	}
	switch ec := strings.Join(codes, "\n"); ec {
	case "":
		d.ok("daily backup job is loaded, has not run yet")
		d.do("run it now to be sure it works: launchctl kickstart -k %s", job)
	case "0":
		d.ok("daily backup job is loaded, last run exited 0")
	default:
		d.warn("daily backup job is loaded, last run exited %s", ec)
		d.do("see ~/Library/Logs/star-traders-sync/backup.launchd.err")
		if ec == "70" {
			d.do("exit 70 usually means the disk was unplugged, or macOS denied access to it")
		}
	}
}
