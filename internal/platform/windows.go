//go:build windows

package platform

import "os"

func LockFile(*os.File) error      { return ErrUnsupported }
func UnlockFile(*os.File)          {}
func PidAlive(int) bool            { return false }
func PidSignalable(int) bool       { return false }
func Device(string) (uint64, bool) { return 0, false }
func CanRead(p string) bool        { _, err := os.Stat(p); return err == nil }
func CanWrite(string) bool         { return false }
func CanExec(string) bool          { return false }

var ExitSignals = map[os.Signal]int{os.Interrupt: 130}

const Shell = "bash"
