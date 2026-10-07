//go:build !darwin

package platform

import (
	"os"
	"path/filepath"
	"strings"
)

// Supported: no implementation for this OS yet (Linux #1, Windows #3).
const Supported = false

func ShortHostname() string {
	h, _ := os.Hostname()
	h, _, _ = strings.Cut(h, ".")
	return h
}
func LocalHostName() string                    { return "" }
func ProcessIDs(string) []string               { return nil }
func ProcessHint(name string) string           { return "" }
func LaunchGame(string) error                  { return ErrUnsupported }
func LaunchHint(string) string                 { return "" }
func CrashReport(string, string, int64) string { return "" }
func LogDir(home, prog string) string          { return filepath.Join(home, ".local", "state", prog) }

const TailscaleAppPath = ""

func PingArgs(host string) []string  { return []string{host} }
func SteamLibraries(string) []string { return nil }
func FullCopyVolume(string) bool     { return false }
func BackupJob(string) Scheduler     { return Scheduler{} }

var (
	ToolsHint           []string
	FindSavesHint       string
	PlaceholderPrefixes []string
)
