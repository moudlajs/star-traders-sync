// Package platform is everything that differs by OS; nothing outside it names a macOS command or path.
// The hub-side snippets still assume a macOS hub (stat -f, shasum): another OS needs its own hubexec.Exec.
package platform

import (
	"errors"
	"runtime"
)

// ErrUnsupported is what an operation answers on an OS without an implementation yet.
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
