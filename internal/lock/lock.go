// Package lock is the hub lock (one machine writes the hub) and the local lock (one run per machine), #23.
// The hub side runs the script's own snippets, so the Go build and the script respect each other's locks.
package lock

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/moudlajs/star-traders-sync/internal/exitcode"
	"github.com/moudlajs/star-traders-sync/internal/fail"
	"github.com/moudlajs/star-traders-sync/internal/hubexec"
	"github.com/moudlajs/star-traders-sync/internal/logx"
	"github.com/moudlajs/star-traders-sync/internal/platform"
)

// DirName is the hub lock's name, beside HUB_PATH and never inside it: a swap replaces the whole directory.
const DirName = ".sts-lock"

// Hub is one run's hub lock.
type Hub struct {
	Exec     hubexec.Exec
	HubPath  string
	HubHost  string
	HubUser  string
	TTL      int
	HostName string
	StableID string
	Pid      int
	Nonce    string // per acquisition; release and clear check it
	Now      func() time.Time
	Log      *logx.Logger
	Stderr   io.Writer

	held  bool
	dir   string
	tries int
	// mu: Release may come from the signal handler mid-Acquire; it waits, then releases what Acquire took.
	mu sync.Mutex
}

// Path is the lock directory beside HUB_PATH, computed as dirname(1) does: filepath.Dir("/a/hub/") is "/a/hub".
func (h *Hub) Path() string {
	p := strings.TrimRight(h.HubPath, "/")
	if p == "" {
		p = "/"
	}
	return strings.TrimSuffix(filepath.Dir(p), "/") + "/" + DirName
}

// Held reports whether this run holds it.
func (h *Hub) Held() bool { return h.held }

func (h *Hub) warn(format string, a ...any) {
	fmt.Fprintf(h.Stderr, "warning: "+format+"\n", a...)
}

// Acquire takes the lock or refuses (50 or 51), clearing only this machine's own stale lock past the TTL.
func (h *Hub) Acquire() *fail.Failure {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.acquire()
}

func (h *Hub) acquire() *fail.Failure {
	if h.held {
		return nil
	}
	if h.Nonce == "" {
		// An empty nonce would match every owner record shorter than five lines: someone else's.
		return fail.New(exitcode.LockCreate, "lock", "internal error: no lock nonce")
	}
	lock := h.Path()
	out, err := h.Exec.Run(acquireScript, lock, h.HostName, strconv.Itoa(h.Pid),
		h.Now().UTC().Format("2006-01-02T15:04:05Z"), h.Nonce, h.StableID)
	if err != nil {
		return fail.New(exitcode.LockCreate, "lock",
			"could not create the hub lock at %s - is the hub directory writable? (%s)", lock, strings.TrimRight(out, "\n"))
	}
	switch {
	case strings.Contains(out, "STS_LOCK_ACQUIRED"):
		h.held, h.dir, h.tries = true, lock, 0
		h.Log.Log("DEBUG", "lock", "hub lock acquired at %s", lock)
		return nil
	case strings.Contains(out, "STS_LOCK_NOCREATE"):
		return fail.New(exitcode.LockCreate, "lock",
			"could not create the hub lock at %s - %s is not writable by %s on %s", lock, filepath.Dir(h.HubPath), h.HubUser, h.HubHost)
	}

	// Backstop: clearing then retrying must terminate whatever the far side reports.
	h.tries++
	if h.tries > 2 {
		return fail.New(exitcode.LockCreate, "lock",
			"gave up acquiring the hub lock at %s after %d attempts - clear it by hand on %s", lock, h.tries, h.HubHost)
	}
	now, f := h.hubClock()
	if f != nil {
		return f
	}
	lines := strings.Split(out, "\n")
	field := func(i int) string {
		if i-1 < len(lines) {
			return lines[i-1]
		}
		return ""
	}

	if strings.Contains(out, "STS_NO_OWNER") {
		mtime, err := strconv.ParseInt(field(3), 10, 64)
		// Unreadable means unknown, and unknown is never old enough to clear.
		if err != nil || mtime <= 0 || !digits(field(3)) {
			mtime = now
		}
		age := max(now-mtime, 0)
		if age >= int64(h.TTL) {
			h.Log.Log("WARN", "lock", "CLEARING ownerless hub lock at %s, age %ds", lock, age)
			h.warn("clearing an ownerless hub lock (a run died while taking it), %ds old", age)
			if f := h.clearStale(lock, "-", "ownerless"); f != nil {
				return f
			}
			return h.acquire()
		}
		h.Log.Log("ERROR", "lock", "ownerless hub lock at %s, age %ds < TTL", lock, age)
		return fail.Printed(exitcode.LockRemote, "lock", "",
			"error: the hub lock exists but has no owner record.",
			fmt.Sprintf("A run died while taking it, %d seconds ago.", age),
			fmt.Sprintf("It clears automatically once older than LOCK_TTL_SECONDS (%d),", h.TTL),
			fmt.Sprintf("or remove it on %s by hand:  rm -rf %s", h.HubHost, lock))
	}

	ownerHost, ownerPid, ownerISO := field(3), field(4), field(5)
	ownerNonce, ownerID := field(7), field(8)
	var ownerEpoch int64
	if digits(field(6)) {
		ownerEpoch, _ = strconv.ParseInt(field(6), 10, 64)
	}
	age := max(now-ownerEpoch, 0)

	// Prefer the stable id; fall back to the hostname for a lock written before it existed.
	ours := ownerHost == h.HostName
	if ownerID != "" {
		ours = ownerID == h.StableID
	}

	// A lock from another machine is never cleared automatically, at any age.
	if !ours {
		h.Log.Log("ERROR", "lock", "hub lock held by %s since %s (%ds)", ownerHost, ownerISO, age)
		return fail.Printed(exitcode.LockRemote, "lock", "",
			"error: the hub is locked by another machine.",
			fmt.Sprintf("  holder: %s (pid %s)", ownerHost, ownerPid),
			fmt.Sprintf("  since:  %s (%d seconds ago)", ownerISO, age),
			"Wait for it to finish. If that machine crashed, clear it there,",
			fmt.Sprintf("or remove %s on the hub by hand.", lock))
	}

	// Our own lock from a crashed earlier run: clear only past the TTL, loudly.
	if age >= int64(h.TTL) {
		// Without a nonce it cannot be told from a fresh lock mid-write, so it is never cleared (#151).
		if ownerNonce == "" {
			h.Log.Log("ERROR", "lock", "stale hub lock at %s has no nonce; not clearing it automatically", lock)
			return fail.New(exitcode.LockRemote, "lock",
				"the hub lock from %s is stale but its owner record is incomplete, so it is not cleared automatically. Make sure no sts is running on either Mac, then on %s: rm -rf %s", ownerISO, h.HubHost, lock)
		}
		h.Log.Log("WARN", "lock", "CLEARING our own stale hub lock from %s, age %ds >= TTL %ds (pid %s)", ownerISO, age, h.TTL, ownerPid)
		h.warn("clearing a stale hub lock left by this machine on %s (%ds old, pid %s)", ownerISO, age, ownerPid)
		if f := h.clearStale(lock, ownerNonce, "stale"); f != nil {
			return f
		}
		return h.acquire()
	}

	h.Log.Log("ERROR", "lock", "hub lock held by this host since %s (%ds < TTL)", ownerISO, age)
	return fail.Printed(exitcode.LockRemote, "lock", "",
		"error: the hub is locked by this machine from an earlier run.",
		fmt.Sprintf("  pid %s, since %s (%d seconds ago)", ownerPid, ownerISO, age),
		fmt.Sprintf("It will be cleared automatically once it is older than LOCK_TTL_SECONDS (%d).", h.TTL),
		fmt.Sprintf("Or remove it on %s by hand:  rm -rf %s", h.HubHost, lock))
}

// clearStale is clear_stale_hub_lock: one clearer at a time, re-judging the lock under a mutex (#132).
func (h *Hub) clearStale(lock, want, what string) *fail.Failure {
	out, err := h.Exec.Run(clearScript, lock, want, strconv.Itoa(h.TTL))
	if err != nil {
		return fail.New(exitcode.LockCreate, "lock", "failed to clear the %s hub lock at %s (%s)", what, lock, strings.TrimRight(out, "\n"))
	}
	switch {
	case strings.Contains(out, "STS_CLEAR_OK"):
		h.Log.Log("WARN", "lock", "cleared the %s hub lock at %s", what, lock)
	case strings.Contains(out, "STS_CLEAR_GONE"):
		h.Log.Log("INFO", "lock", "the %s hub lock at %s was already cleared by another run", what, lock)
	case strings.Contains(out, "STS_CLEAR_CHANGED"):
		h.Log.Log("WARN", "lock", "the hub lock at %s changed hands before it could be cleared; left alone", lock)
	case strings.Contains(out, "STS_CLEAR_BUSY"):
		h.Log.Log("ERROR", "lock", "another run is clearing the hub lock at %s", lock)
		return fail.New(exitcode.LockRemote, "lock",
			"another run is clearing the %s hub lock at this moment. Nothing was synced. Run again", what)
	case strings.Contains(out, "STS_CLEAR_DEAD"):
		h.Log.Log("ERROR", "lock", "a run died while clearing the hub lock at %s: %s.clearing is left", lock, lock)
		return fail.New(exitcode.LockRemote, "lock",
			"a run died while clearing the %s hub lock, and left %s.clearing behind. Nothing was synced. Make sure no sts is running on either Mac, then on %s: rmdir %s.clearing", what, lock, h.HubHost, lock)
	default:
		return fail.New(exitcode.LockCreate, "lock", "unexpected answer while clearing the hub lock at %s: %s", lock, strings.TrimRight(out, "\n"))
	}
	return nil
}

// Release removes the lock only if the nonce is still ours; a failure is logged, never fatal.
func (h *Hub) Release() {
	h.mu.Lock()
	defer h.mu.Unlock()
	if !h.held || h.Nonce == "" {
		return
	}
	h.held = false
	if _, err := h.Exec.Run(releaseScript, h.dir, h.Nonce); err != nil {
		h.Log.Log("WARN", "lock", "could not release the hub lock at %s - clear it by hand; until then it blocks the other Mac, and this one, for LOCK_TTL_SECONDS", h.dir)
	}
	h.Log.Log("DEBUG", "lock", "hub lock released")
}

// hubClock is hub_clock_epoch: lock ages are judged on the hub's own clock.
func (h *Hub) hubClock() (int64, *fail.Failure) {
	out, err := h.Exec.Run("date -u +%s")
	n, perr := strconv.ParseInt(strings.TrimSpace(out), 10, 64)
	if err != nil || perr != nil {
		return 0, fail.New(exitcode.LockCreate, "lock", "could not read the hub's clock (%s)", strings.TrimSpace(out))
	}
	return n, nil
}

func digits(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

// StableID is a persistent machine id (hostname -s changes with DHCP on macOS), created atomically by hard link.
func StableID(stateDir, hostName string, pid int, now time.Time) string {
	f := filepath.Join(stateDir, "host-id")
	if id := firstLine(f); id != "" {
		return id
	}
	_ = os.MkdirAll(stateDir, 0o755)
	id := newUUID()
	if id == "" {
		id = fmt.Sprintf("%s-%d-%d", hostName, pid, now.Unix())
	}
	if tmp, err := os.CreateTemp(stateDir, "host-id.*"); err == nil {
		_, werr := tmp.WriteString(id + "\n")
		tmp.Close()
		if werr == nil && os.Link(tmp.Name(), f) == nil {
			os.Remove(tmp.Name())
			return id
		}
		os.Remove(tmp.Name())
	}
	if id := firstLine(f); id != "" {
		return id
	}
	return hostName
}

func firstLine(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	line, _, _ := strings.Cut(string(b), "\n")
	return line
}

func newUUID() string {
	f, err := os.Open("/dev/urandom")
	if err != nil {
		return ""
	}
	defer f.Close()
	b := make([]byte, 16)
	if _, err := io.ReadFull(f, b); err != nil {
		return ""
	}
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return strings.ToUpper(fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16]))
}

// Local is this machine's lock: a kernel flock among Go runs, plus the script's lock dir and pid file.
type Local struct {
	dir, file string
	pid       int
	flock     *os.File
}

// youngLock: a pidless script lock this new is likely mid-mkdir; clearing it would let two runs in.
const youngLock = 10 * time.Second

// AcquireLocal takes backup.lock for backup, so a nightly backup is not cancelled, local.lock otherwise.
func AcquireLocal(stateDir string, backup bool, pid int, now time.Time, log *logx.Logger) (*Local, *fail.Failure) {
	name := "local.lock"
	if backup {
		name = "backup.lock"
	}
	l := &Local{dir: filepath.Join(stateDir, name+".d"), file: filepath.Join(stateDir, name), pid: pid}
	_ = os.MkdirAll(stateDir, 0o755)

	fl, err := os.OpenFile(filepath.Join(stateDir, name+".flock"), os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return nil, fail.New(exitcode.LockLocal, "lock", "could not open the local lock in %s: %v", stateDir, err)
	}
	if err := platform.LockFile(fl); err != nil {
		fl.Close()
		holder := strings.TrimSpace(firstLine(l.file))
		if !digits(holder) {
			holder = "unknown"
		}
		return nil, fail.New(exitcode.LockLocal, "lock",
			"another star-traders-sync is already running on this machine (pid %s) - wait for it to finish", holder)
	}
	l.flock = fl

	if os.Mkdir(l.dir, 0o755) != nil {
		holder := strings.TrimSpace(firstLine(l.file))
		if !digits(holder) {
			holder = ""
		}
		if holder != "" && alive(holder) {
			l.unflock()
			return nil, fail.New(exitcode.LockLocal, "lock",
				"another star-traders-sync is already running on this machine (pid %s) - wait for it to finish", holder)
		}
		if st, err := os.Stat(l.dir); err == nil && now.Sub(st.ModTime()) < youngLock {
			l.unflock()
			return nil, fail.New(exitcode.LockLocal, "lock",
				"another star-traders-sync is starting on this machine - wait for it to finish")
		}
		shown := holder
		if shown == "" {
			shown = "unknown"
		}
		log.Log("WARN", "lock", "clearing stale local lock (pid %s is gone)", shown)
		_ = os.RemoveAll(l.dir)
		if os.Mkdir(l.dir, 0o755) != nil {
			l.unflock()
			return nil, fail.New(exitcode.LockLocal, "lock",
				"could not take the local lock at %s - remove it by hand if no star-traders-sync is running", l.dir)
		}
	}
	// A lock with no recorded holder would read as stale to the next run.
	if err := os.WriteFile(l.file, []byte(strconv.Itoa(pid)+"\n"), 0o644); err != nil {
		_ = os.Remove(l.dir)
		l.unflock()
		return nil, fail.New(exitcode.LockLocal, "lock", "could not record this run in %s: %v", l.file, err)
	}
	log.Log("DEBUG", "lock", "local lock held, pid %d", pid)
	return l, nil
}

// HoldLocal takes the run flock without waiting, so doctor can clear a stale local lock with no run slipping in.
func HoldLocal(stateDir string, create bool) (release func(), busy bool, err error) {
	flag := os.O_RDWR
	if create {
		flag |= os.O_CREATE
	}
	fl, err := os.OpenFile(filepath.Join(stateDir, "local.lock.flock"), flag, 0o644)
	if err != nil {
		if create {
			return func() {}, false, err
		}
		return func() {}, false, nil
	}
	if platform.LockFile(fl) != nil {
		fl.Close()
		return func() {}, true, nil
	}
	return func() { platform.UnlockFile(fl); fl.Close() }, false, nil
}

func (l *Local) unflock() {
	if l.flock != nil {
		platform.UnlockFile(l.flock)
		l.flock.Close()
		l.flock = nil
	}
}

// Release removes the script-visible lock only if it still names this run, then drops the flock.
func (l *Local) Release() {
	if l == nil {
		return
	}
	if strings.TrimSpace(firstLine(l.file)) == strconv.Itoa(l.pid) {
		_ = os.Remove(l.file)
		_ = os.RemoveAll(l.dir)
	}
	l.unflock()
}

func alive(pid string) bool {
	n, err := strconv.Atoi(pid)
	return err == nil && platform.PidAlive(n)
}
