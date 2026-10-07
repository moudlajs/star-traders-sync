// Package platform is everything that differs by operating system: how a
// process is found, how the game is launched, where logs and crash reports
// live, the file lock, the scheduler the nightly backup runs under, and
// the advice doctor gives. Nothing outside this package names a macOS
// command or path (TestNoPlatformCodeOutside), so the Linux (#1) and
// Windows (#3) ports add a file here rather than edit the rest.
//
// One limit, deliberately left for those ports: the hub-side snippets
// (internal/hub, lock, transfer) are the bash script's own text and assume
// a macOS hub (stat -f, shasum). A hub on another OS needs its own
// hubexec.Exec, not just a local platform file.
package platform

import (
	"errors"
	"runtime"
)

// ErrUnsupported is what an operation answers on an OS without an
// implementation yet.
var ErrUnsupported = errors.New(runtime.GOOS + " is not supported yet")

// Scheduler is the nightly backup job, as doctor reports it.
type Scheduler struct {
	Installed  bool
	LastExits  []string // each recorded last exit code; none if it has not run
	RunNowCmd  string   // how to run it now by hand
	ErrLog     string   // where its stderr goes
	InstallCmd string   // how to install it
	Exit70Hint string   // what a 70 (backup volume missing) usually means here
}
