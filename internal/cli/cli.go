// Package cli is the command line: arguments, the startup checks and the
// dispatch, in the bash script's order and with its messages, so that the
// two can be run side by side and diffed (tests/parity.sh) until the Go
// build replaces the script (#26).
package cli

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/moudlajs/star-traders-sync/internal/config"
	"github.com/moudlajs/star-traders-sync/internal/exitcode"
	"github.com/moudlajs/star-traders-sync/internal/fail"
	"github.com/moudlajs/star-traders-sync/internal/lock"
	"github.com/moudlajs/star-traders-sync/internal/logx"
)

// Version must equal STS_VERSION in bin/star-traders-sync while both
// exist; a test enforces it, so a release bump that misses one fails CI.
const Version = "1.6.1"

const prog = "star-traders-sync"

// Env is everything Main reads from the outside world, so tests can run
// it in a sandbox.
type Env struct {
	Stdout, Stderr io.Writer
	Getenv         func(string) string
	Geteuid        func() int
	LookPath       func(string) (string, error)
}

// System is the real process environment.
func System() Env {
	return Env{Stdout: os.Stdout, Stderr: os.Stderr, Getenv: os.Getenv,
		Geteuid: os.Geteuid, LookPath: exec.LookPath}
}

// Options are the parsed arguments.
type Options struct {
	Command     string
	DryRun      bool
	Verbose     bool
	OfflineOK   bool
	Fix         bool
	JSON        bool
	Expect      string
	Force       string
	RestoreFrom string
}

type paths struct{ configFile, stateDir, stateFile, logFile string }

func pathsFrom(env Env) paths {
	home := env.Getenv("HOME")
	cfg := env.Getenv("XDG_CONFIG_HOME")
	if cfg == "" {
		cfg = home + "/.config"
	}
	state := env.Getenv("XDG_STATE_HOME")
	if state == "" {
		state = home + "/.local/state"
	}
	return paths{
		configFile: filepath.Join(cfg, prog, "config"),
		stateDir:   filepath.Join(state, prog),
		stateFile:  filepath.Join(state, prog, "last-sync.json"),
		logFile:    filepath.Join(home, "Library/Logs", prog, prog+".log"),
	}
}

func usage(p paths) string {
	return strings.NewReplacer(
		"${CONFIG_FILE}", p.configFile, "${STATE_FILE}", p.stateFile, "${LOG_FILE}", p.logFile,
		"$STS_VERSION", Version, "$PROG", prog,
	).Replace(usageTemplate)
}

// exit is how parseArgs stops: a code and what to print first.
type exit struct {
	code   exitcode.Code
	stdout string
	stderr string
}

func usageErr(lines ...string) *exit {
	return &exit{code: exitcode.Usage, stderr: strings.Join(lines, "\n") + "\n"}
}

func parseArgs(args []string, p paths) (Options, *exit) {
	var o Options
	for _, a := range args {
		switch {
		case a == "status" || a == "pull" || a == "push" || a == "play" || a == "backup" || a == "doctor" || a == "restore":
			if o.Command != "" {
				return o, usageErr(fmt.Sprintf("error: more than one command given: %s and %s", o.Command, a))
			}
			o.Command = a
		case a == "--dry-run":
			o.DryRun = true
		case a == "--verbose" || a == "-v":
			o.Verbose = true
		case a == "--offline-ok":
			o.OfflineOK = true
		case a == "--fix":
			o.Fix = true
		case a == "--json":
			o.JSON = true
		case strings.HasPrefix(a, "--expect-decision="):
			o.Expect = strings.TrimPrefix(a, "--expect-decision=")
			if o.Expect == "" || strings.Trim(o.Expect, "ABCDEFGHIJKLMNOPQRSTUVWXYZ_") != "" {
				return o, usageErr(fmt.Sprintf(`error: --expect-decision takes a decision name such as HUB_ONLY, got "%s"`, o.Expect))
			}
		case a == "--force=local":
			o.Force = "local"
		case a == "--force=hub":
			o.Force = "hub"
		case strings.HasPrefix(a, "--force="):
			return o, usageErr(fmt.Sprintf(`error: --force takes exactly "local" or "hub", got "%s"`, strings.TrimPrefix(a, "--force=")))
		case a == "--force":
			return o, usageErr("error: --force needs a value: --force=local or --force=hub")
		case a == "-h" || a == "--help":
			return o, &exit{code: exitcode.OK, stdout: usage(p)}
		case a == "--version":
			return o, &exit{code: exitcode.OK, stdout: fmt.Sprintf("%s %s\n", prog, Version)}
		case a != "" && !strings.HasPrefix(a, "-") && o.Command == "restore" && o.RestoreFrom == "":
			// The one positional argument: the safety copy to restore.
			o.RestoreFrom = a
		default:
			return o, usageErr(fmt.Sprintf(`error: unknown argument "%s"`, a), fmt.Sprintf("run '%s --help'", prog))
		}
	}
	if o.Command == "" {
		return o, &exit{code: exitcode.Usage, stderr: usage(p)}
	}
	switch o.Command + ":" + o.Force {
	case "pull:local":
		return o, usageErr(`error: --force=local makes no sense for "pull" - it would discard the hub.`,
			fmt.Sprintf("Use:  %s push --force=local", prog))
	case "push:hub":
		return o, usageErr(`error: --force=hub makes no sense for "push" - it would discard this machine.`,
			fmt.Sprintf("Use:  %s pull --force=hub", prog))
	}
	if o.Fix && o.Command != "doctor" {
		return o, usageErr(`error: --fix only applies to "doctor".`, fmt.Sprintf("Use:  %s doctor --fix", prog))
	}
	if o.Expect != "" && o.Command != "pull" && o.Command != "push" {
		return o, usageErr(`error: --expect-decision only applies to "pull" and "push".`)
	}
	if o.JSON && o.Command != "status" && !(o.Command == "restore" && o.RestoreFrom == "") {
		return o, usageErr(`error: --json only applies to "status" and to listing with "restore".`,
			fmt.Sprintf("Use:  %s status --json", prog))
	}
	if o.Command == "restore" && (o.DryRun || o.Force != "" || o.OfflineOK) {
		return o, usageErr(`error: "restore" takes only the name of a safety copy, and --json to list them.`)
	}
	if o.Command == "play" && o.Force != "" {
		return o, usageErr(`error: --force cannot be used with "play", which pulls before and pushes after.`,
			"Resolve the conflict explicitly first, then play:",
			fmt.Sprintf("  %s pull --force=hub     keep the hub's saves", prog),
			fmt.Sprintf("  %s push --force=local   keep this machine's saves", prog))
	}
	return o, nil
}

// Main runs the tool and returns its exit code.
func Main(args []string, env Env) int {
	p := pathsFrom(env)
	o, stop := parseArgs(args, p)
	if stop != nil {
		fmt.Fprint(env.Stdout, stop.stdout)
		fmt.Fprint(env.Stderr, stop.stderr)
		return int(stop.code)
	}

	log := &logx.Logger{File: p.logFile, Level: "INFO", MaxBytes: 5242880, Keep: 3}
	if o.Verbose {
		log.Verbose = env.Stderr
	}
	die := func(code exitcode.Code, step, msg string) int {
		log.Log("ERROR", step, "exit=%d %s", code, msg)
		fmt.Fprintf(env.Stderr, "error: %s\n", msg)
		fmt.Fprintf(env.Stderr, "exit code %d - see %s\n", code, p.logFile)
		return int(code)
	}

	// doctor runs before every other check, because the things those
	// checks abort on are exactly what it exists to report.
	if o.Command == "doctor" {
		return runDoctor(env, o, p, log)
	}

	// Cheapest, most fundamental refusals first - these need no config.
	if env.Geteuid() == 0 {
		return die(exitcode.Root, "preflight",
			"refusing to run as root - saves belong to your user and root would leave files your user cannot rewrite")
	}
	var missing string
	for _, tool := range []string{"rsync", "ssh"} {
		if _, err := env.LookPath(tool); err != nil {
			missing += " " + tool
		}
	}
	if missing != "" {
		return die(exitcode.ToolMissing, "preflight", "required tools not on PATH:"+missing)
	}

	cfg, f := config.Load(p.configFile, env.Getenv("HOME"))
	if f == nil {
		f = cfg.Validate()
	}
	if f != nil {
		if f.Lines != nil {
			for _, l := range f.Lines {
				fmt.Fprintln(env.Stderr, l)
			}
			log.Log("ERROR", f.Step, "%s", f.Msg)
			return int(f.Code)
		}
		return die(f.Code, f.Step, f.Msg)
	}
	log.Level = cfg.Get("LOG_LEVEL")
	log.MaxBytes = int64(cfg.Int("LOG_MAX_BYTES"))
	log.Keep = cfg.Int("LOG_KEEP")
	log.Log("DEBUG", "config", "loaded %s", p.configFile)
	log.Log("DEBUG", "config", "validated")
	log.Log("INFO", "start", "command=%s dry_run=%d force='%s' offline_ok=%d version=%s",
		o.Command, b2i(o.DryRun), o.Force, b2i(o.OfflineOK), Version)

	r := &run{env: env, opt: o, cfg: cfg, p: p, log: log, out: env.Stdout, json: io.Discard,
		pid: os.Getpid(), host: hostnameShort(), ex: &exiter{}}
	stopSignals := r.ex.watch()
	defer stopSignals()
	defer r.ex.finish() // runs first: an interrupt mid-release finishes before Main returns
	if o.JSON {
		// stdout carries the JSON (status's object, restore's list) and
		// nothing else; every other
		// message goes to stderr, so a caller can parse stdout on exit 0.
		r.out, r.json = env.Stderr, env.Stdout
	}
	// A closure: r.lockLoc is set later, in prepare, and a plain
	// "defer r.lockLoc.Release()" would bind the nil it holds now.
	defer func() { r.lockLoc.Release() }() // status takes no hub lock
	now := time.Now()
	if o.Command == "backup" {
		// backup is local to the hub and does not need the tailnet; its own
		// lock, so a nightly run is not cancelled by an interactive one.
		l, lf := lock.AcquireLocal(p.stateDir, true, r.pid, now, log)
		if f = lf; f == nil {
			r.lockLoc = l
			r.ex.add(l.Release)
			f = r.backup(now)
		}
		if f != nil {
			return report(env, log, p, f)
		}
		return 0
	}
	if o.Command == "restore" {
		// restore touches only this machine's saves: no tailnet, no hub.
		if f = r.prepareLocal(now); f == nil {
			f = r.restore()
		}
		if f != nil {
			return report(env, log, p, f)
		}
		return 0
	}
	f = r.prepare(now)
	switch {
	case f != nil:
	case o.DryRun:
		r.dryRun()
	case o.Command == "status":
		f = r.status()
	default:
		s := r.newSyncer(now)
		switch o.Command {
		case "pull":
			f = s.pull()
		case "push":
			f = s.push()
		case "play":
			f = s.play()
		}
		if f != nil {
			code := report(env, log, p, f)
			s.release()
			return code
		}
		s.release()
		return 0
	}
	if f != nil {
		return report(env, log, p, f)
	}
	return 0
}

// report prints a refusal the way the script does: die's two lines, or the
// refusal's own lines verbatim.
func report(env Env, log *logx.Logger, p paths, f *fail.Failure) int {
	if f.Lines != nil {
		for _, l := range f.Lines {
			fmt.Fprintln(env.Stderr, l)
		}
		if f.Msg != "" {
			log.Log("ERROR", f.Step, "%s", f.Msg)
		}
		return int(f.Code)
	}
	log.Log("ERROR", f.Step, "exit=%d %s", f.Code, f.Msg)
	fmt.Fprintf(env.Stderr, "error: %s\n", f.Msg)
	fmt.Fprintf(env.Stderr, "exit code %d - see %s\n", f.Code, p.logFile)
	return int(f.Code)
}

func b2i(b bool) int {
	if b {
		return 1
	}
	return 0
}
