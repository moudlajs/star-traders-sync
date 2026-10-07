//go:build darwin

package platform

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

// Supported: this build runs here.
const Supported = true

// ShortHostname is "hostname -s".
func ShortHostname() string {
	out, err := exec.Command("hostname", "-s").Output()
	if err != nil {
		h, _ := os.Hostname()
		h, _, _ = strings.Cut(h, ".")
		return h
	}
	return strings.TrimSpace(string(out))
}

// LocalHostName is the Bonjour name (scutil --get LocalHostName), the other
// name a hub host may go by.
func LocalHostName() string {
	out, _ := exec.Command("scutil", "--get", "LocalHostName").Output()
	return strings.TrimSpace(string(out))
}

// ProcessIDs is "pgrep -x NAME": the pids of processes with exactly that
// name, in pgrep's order.
func ProcessIDs(name string) []string {
	out, _ := exec.Command("pgrep", "-x", name).Output()
	return strings.Fields(string(out))
}

// ProcessHint is the command a person runs to look for the game.
func ProcessHint(name string) string { return "pgrep -x " + name }

// LaunchGame asks Steam to start the game.
func LaunchGame(appID string) error { return exec.Command("open", "steam://rungameid/"+appID).Run() }

// LaunchHint is the command that launches the game by hand.
func LaunchHint(appID string) string { return "open steam://rungameid/" + appID }

// CrashReport is a crash report for the game written at or after since.
func CrashReport(home, name string, since int64) string {
	matches, _ := filepath.Glob(filepath.Join(home, "Library/Logs/DiagnosticReports", name) + "*")
	for _, m := range matches {
		if st, err := os.Stat(m); err == nil && st.Mode().IsRegular() && st.ModTime().Unix() >= since {
			return m
		}
	}
	return ""
}

// LogDir is where the log file lives.
func LogDir(home, prog string) string { return filepath.Join(home, "Library/Logs", prog) }

// TailscaleAppPath is the App Store build's CLI, preferred over PATH.
const TailscaleAppPath = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"

// PingArgs is one ping with a two-second wait: does the name resolve and
// answer.
func PingArgs(host string) []string { return []string{"-c1", "-t2", host} }

// SteamLibraries are where a Steam app manifest may be.
func SteamLibraries(home string) []string {
	vols, _ := filepath.Glob("/Volumes/*/SteamLibrary")
	return append([]string{home + "/Library/Application Support/Steam"}, vols...)
}

// FullCopyVolume: the volume's filesystem has no hard links, so every
// backup is a full copy (exFAT, FAT).
func FullCopyVolume(vol string) bool {
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
		return true
	}
	return false
}

var lastExit = regexp.MustCompile(`last exit code = [0-9]+`)

// BackupJob is the launchd job that runs the nightly backup.
func BackupJob(label string) Scheduler {
	job := fmt.Sprintf("gui/%d/%s", os.Getuid(), label)
	s := Scheduler{
		RunNowCmd:  "launchctl kickstart -k " + job,
		ErrLog:     "~/Library/Logs/star-traders-sync/backup.launchd.err",
		InstallCmd: "./launchd/install-backup-job.sh",
		Exit70Hint: "exit 70 usually means the disk was unplugged, or macOS denied access to it",
	}
	printed, err := exec.Command("launchctl", "print", job).Output()
	if err != nil {
		return s
	}
	s.Installed = true
	for _, m := range lastExit.FindAllString(string(printed), -1) {
		s.LastExits = append(s.LastExits, m[strings.LastIndex(m, " ")+1:])
	}
	return s
}

// Doctor's advice, in this OS's terms.
var (
	// ToolsHint follows "not on PATH: ...".
	ToolsHint = []string{"these ship with macOS; python3 needs the Xcode command line tools:", "    xcode-select --install"}
	// FindSavesHint helps find the game's save directory.
	FindSavesHint = "    ls -la ~/Library | grep -i star"
	// PlaceholderPrefixes are path defaults that config.example and
	// install.sh ship, so a config still holding one was never edited.
	PlaceholderPrefixes = []string{"/Volumes/Backup"}
)
