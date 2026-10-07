//go:build unix

package platform

import (
	"os"
	"syscall"
)

// LockFile takes an exclusive lock on f without waiting.
func LockFile(f *os.File) error { return syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB) }

// UnlockFile drops it.
func UnlockFile(f *os.File) { _ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN) }

// PidAlive: the process exists, even if owned by another user (kill -0
// failing with EPERM).
func PidAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	err := syscall.Kill(pid, 0)
	return err == nil || err == syscall.EPERM
}

// PidSignalable is the shell's "kill -0 PID" succeeding: the process
// exists and this user may signal it.
func PidSignalable(pid int) bool { return syscall.Kill(pid, 0) == nil }

// Device is the filesystem device a path lives on.
func Device(p string) (uint64, bool) {
	var st syscall.Stat_t
	if syscall.Stat(p, &st) != nil {
		return 0, false
	}
	return uint64(st.Dev), true
}

// test(1)'s -r, -w and -x: access(2), not the mode bits.
func CanRead(p string) bool  { return syscall.Access(p, 4) == nil }
func CanWrite(p string) bool { return syscall.Access(p, 2) == nil }
func CanExec(p string) bool  { return syscall.Access(p, 1) == nil }

// ExitSignals are the signals a run handles, with the exit code each
// gives (128 + the signal number, as the script's traps exit).
var ExitSignals = map[os.Signal]int{syscall.SIGINT: 130, syscall.SIGTERM: 143, syscall.SIGHUP: 129, syscall.SIGPIPE: 141}

// Shell runs the hub-side snippets when this machine is the hub.
const Shell = "/bin/bash"
