// Package hub is where the hub lives and how it is read: which address it
// is reached at, whether ssh works non-interactively, whether HUB_PATH is
// usable, and the hub side's manifest, newest file and lock owner. The
// script's resolve_hub_endpoint, check_hub_reachable, check_hub_path,
// manifest_hub, newest_mtime_hub and status's lock probe.
package hub

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/moudlajs/star-traders-sync/internal/exitcode"
	"github.com/moudlajs/star-traders-sync/internal/fail"
	"github.com/moudlajs/star-traders-sync/internal/hubexec"
	"github.com/moudlajs/star-traders-sync/internal/lock"
	"github.com/moudlajs/star-traders-sync/internal/logx"
	"github.com/moudlajs/star-traders-sync/internal/manifest"
	"github.com/moudlajs/star-traders-sync/internal/platform"
	"github.com/moudlajs/star-traders-sync/internal/tailscale"
)

// Hub is one run's view of the hub.
type Hub struct {
	Host, User, Path string // HUB_HOST, HUB_USER, HUB_PATH
	Exclude          []string
	IsLocal          bool   // this machine is the hub host
	EndpointKind     string // local, magicdns, tailnet-ip or offline
	Endpoint         string // the address ssh uses; "" when local or offline
	DNS, IP          string // the peer's two addresses, for the host-key advice
	Exec             hubexec.Exec
	SSHOpts          []string
	SSHOptsText      string // hubexec.OptionsText, for printed commands
	Log              *logx.Logger
	Stdout, Stderr   io.Writer
}

// Target is ssh_target.
func (h *Hub) Target() string { return h.User + "@" + h.Endpoint }

// Resolve is resolve_hub_endpoint for a hub that is not this machine:
// the hub peer, whether it is online, MagicDNS if it resolves, else the
// tailnet IP, and a tailscale ping. offlineOK lets play run on the local
// save when the hub is offline.
func (h *Hub) Resolve(ts *tailscale.Client, preferMagicDNS, offlineOK bool, ping func(host string) bool) *fail.Failure {
	st, f := ts.EnsureUp()
	if f != nil {
		return f
	}
	peer, ok := tailscale.FindPeer(st, h.Host)
	if !ok {
		return fail.New(exitcode.TSNoPeer, "tailscale",
			"hub host '%s' is not in this tailnet at all - check HUB_HOST against '%s status', or the machine has never joined", h.Host, ts.Bin)
	}
	h.DNS, h.IP = peer.DNS, peer.IP
	if !peer.Online {
		if offlineOK {
			h.Log.Log("WARN", "tailscale", "hub %s is OFFLINE, continuing under --offline-ok", h.Host)
			h.Endpoint, h.EndpointKind = "", "offline"
			return nil
		}
		return fail.New(exitcode.TSPeerOffline, "tailscale",
			"hub host '%s' (%s) is offline - wake it, or re-run with --offline-ok to play on the local save without syncing", h.Host, peer.IP)
	}
	if preferMagicDNS && peer.DNS != "" && ping(peer.DNS) {
		h.Endpoint, h.EndpointKind = peer.DNS, "magicdns"
		h.Log.Log("INFO", "tailscale", "hub endpoint %s (MagicDNS)", peer.DNS)
	} else {
		h.Endpoint, h.EndpointKind = peer.IP, "tailnet-ip"
		if preferMagicDNS {
			h.Log.Log("INFO", "tailscale", "MagicDNS name '%s' did not resolve, falling back to tailnet IP %s", peer.DNS, peer.IP)
			fmt.Fprintf(h.Stdout, "note: MagicDNS did not resolve, using tailnet IP %s\n", peer.IP)
		} else {
			h.Log.Log("INFO", "tailscale", "hub endpoint %s (tailnet IP, MagicDNS disabled by config)", peer.IP)
		}
	}
	out, err := exec.Command(ts.Bin, "ping", "--c", "3", "--timeout", "5s", peer.IP).CombinedOutput()
	said := strings.TrimRight(string(out), "\n")
	if err != nil {
		h.Log.Log("ERROR", "tailscale", "tailscale ping %s failed: %s", peer.IP, said)
		return fail.New(exitcode.TSPing, "tailscale",
			"hub '%s' reports online but 'tailscale ping %s' failed - %s", h.Host, peer.IP, said)
	}
	first, _, _ := strings.Cut(said, "\n")
	h.Log.Log("DEBUG", "tailscale", "ping ok: %s", first)
	return nil
}

// PingMagicDNS is the script's "ping -c1 -t2": does the name resolve and
// answer.
func PingMagicDNS(host string) bool {
	return exec.Command("ping", platform.PingArgs(host)...).Run() == nil
}

// CheckReachable is check_hub_reachable: one ssh probe, its failure modes
// turned into distinct codes, a changed or unknown host key never accepted.
func (h *Hub) CheckReachable() *fail.Failure {
	if h.IsLocal {
		h.Log.Log("DEBUG", "ssh", "hub is local, skipping ssh probe")
		return nil
	}
	c := exec.Command("ssh", append(append([]string{}, h.SSHOpts...), h.Target(), "echo STS_SSH_OK")...)
	raw, err := c.CombinedOutput()
	out := strings.TrimRight(string(raw), "\n")
	if err == nil && out == "STS_SSH_OK" {
		h.Log.Log("DEBUG", "ssh", "ssh to %s ok", h.Target())
		return nil
	}
	rc := 1
	if ee, ok := err.(*exec.ExitError); ok {
		rc = ee.ExitCode()
	}
	if strings.Contains(out, "HOST IDENTIFICATION HAS CHANGED") || (strings.Contains(out, "host key for") && strings.Contains(out, "has changed")) {
		h.Log.Log("ERROR", "ssh", "host key CHANGED for %s: %s", h.Endpoint, out)
		return fail.Printed(exitcode.SSHHostkey, "ssh", "",
			fmt.Sprintf("error: the SSH host key for %s has CHANGED.", h.Endpoint),
			"This is either a reinstalled machine or something is wrong.",
			"Verify the new key ON THE HUB, then remove the stale entry:",
			"  ssh-keygen -R "+h.Endpoint,
			"Compare against, run on the hub:",
			"  ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub")
	}
	for _, s := range []string{"No ED25519 host key is known", "Host key verification failed", "No RSA host key is known"} {
		if strings.Contains(out, s) {
			h.Log.Log("ERROR", "ssh", "host key UNKNOWN for %s: %s", h.Endpoint, out)
			lines := []string{fmt.Sprintf("error: the SSH host key for %s is not trusted yet.", h.Endpoint), ""}
			return fail.Printed(exitcode.SSHHostkey, "ssh", "", append(lines, h.HostKeyHelp(h.Endpoint)...)...)
		}
	}
	h.Log.Log("ERROR", "ssh", "non-interactive ssh failed rc=%d: %s", rc, out)
	return fail.Printed(exitcode.SSHFailed, "ssh", "",
		fmt.Sprintf("error: could not ssh to the hub non-interactively (rc=%d).", rc),
		"ssh said:", out,
		"Reproduce it by hand with:", "  ssh "+h.SSHOptsText+" "+h.Target(),
		"If it asks for a password, key auth is not set up:",
		"  ssh-copy-id -i ~/.ssh/id_ed25519.pub "+h.Target())
}

// HostKeyHelp is hostkey_help: if the machine's other address is already
// trusted with the same key, adding this one is safe and the comparison is
// done for the user; otherwise they verify out of band. Never auto-accept.
// (All of it on stderr: the script's first line of the "safe" advice went
// to stdout, the rest to stderr.)
func (h *Hub) HostKeyHelp(want string) []string {
	alt := h.DNS
	if want == h.DNS {
		alt = h.IP
	}
	if alt != "" && exec.Command("ssh-keygen", "-F", alt).Run() == nil {
		altKey := keyField(exec.Command("ssh-keygen", "-F", alt), true)
		wantKey := keyField(exec.Command("ssh-keyscan", "-t", "ed25519", want), false)
		if altKey != "" && altKey == wantKey {
			h.Log.Log("INFO", "ssh", "advised adding %s, key matches already-trusted %s", want, alt)
			return []string{
				fmt.Sprintf("You already trust this machine as %s, and %s presents the", alt, want),
				"identical host key. Adding the name is safe. Run:", "",
				"    ssh-keyscan -t ed25519 " + want + " >> ~/.ssh/known_hosts", "",
				"Then re-run this command."}
		}
		if altKey != "" && wantKey != "" {
			h.Log.Log("ERROR", "ssh", "key mismatch between %s and %s", alt, want)
			return []string{
				fmt.Sprintf("WARNING: you trust %s, but %s presents a DIFFERENT key.", alt, want),
				"Do not add it. Investigate before going further."}
		}
	}
	return []string{
		"Not auto-accepting it. Verify out of band, then add it.", "",
		"Copy this whole block - it does the comparison for you:", "",
		fmt.Sprintf("    # 1. ON THE HUB (%s), print its real fingerprint:", h.Host),
		"    ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub", "",
		"    # 2. HERE, paste that SHA256:... value in and run it:",
		`    EXPECT="SHA256:PASTE_IT_HERE"`,
		`    GOT=$(ssh-keyscan -t ed25519 ` + want + ` 2>/dev/null | ssh-keygen -lf - | awk "{print \$2}")`,
		`    [ "$GOT" = "$EXPECT" ] \`,
		`      && ssh-keyscan -t ed25519 ` + want + ` >> ~/.ssh/known_hosts && echo "MATCH - added" \`,
		`      || echo "MISMATCH: $GOT - do not proceed"`}
}

// keyField is the script's "| awk '{print $3}' | head -1" over ssh-keygen
// -F or ssh-keyscan output (skipping ssh-keygen's # comment lines).
func keyField(c *exec.Cmd, skipComments bool) string {
	out, _ := c.Output()
	for _, line := range strings.Split(string(out), "\n") {
		if skipComments && strings.HasPrefix(line, "#") {
			continue
		}
		if f := strings.Fields(line); len(f) >= 3 {
			return f[2]
		}
	}
	return ""
}

// CheckPath is check_hub_path: HUB_PATH exists, is a directory, and the hub
// user can read and write it. A missing hub with a parked .sts-old copy
// beside it is an interrupted swap: the data is intact there, and an empty
// hub must never be created on top of it. allowMissing: a first push may
// create the hub.
func (h *Hub) CheckPath(allowMissing bool) *fail.Failure {
	out, err := h.Exec.Run(checkPathScript, h.Path)
	if err != nil {
		return fail.New(exitcode.SSHFailed, "hub", "probing hub path failed: %s", strings.TrimRight(out, "\n"))
	}
	switch {
	case strings.Contains(out, "STS_ORPHAN"):
		parked := ""
		for _, l := range strings.Split(out, "\n") {
			if l != "" && !strings.Contains(l, "STS_ORPHAN") {
				parked = l
				break
			}
		}
		h.Log.Log("ERROR", "hub", "interrupted hub swap: %s missing, data parked at %s", h.Path, parked)
		return fail.Printed(exitcode.HubPathMissing, "hub", "",
			"error: a previous run was interrupted while swapping the hub.", "",
			"The hub data is INTACT on "+h.Host+" at:", "  "+parked, "",
			"Restore it there with:", "  mv "+parked+" "+h.Path, "",
			"Do NOT create an empty hub - that would make the next push look",
			"like a legitimate first seed and orphan this data.")
	case strings.Contains(out, "STS_OK"):
		h.Log.Log("DEBUG", "hub", "hub path ok: %s", h.Path)
		return nil
	case strings.Contains(out, "STS_NOENT"):
		if allowMissing {
			h.Log.Log("INFO", "hub", "hub path does not exist yet - a first seed may create it")
			return nil
		}
		return fail.New(exitcode.HubPathMissing, "hub",
			"hub path does not exist on %s: %s - create it with 'mkdir -p %s' on the hub, or run 'sts push' which will offer to seed it", h.Host, h.Path, h.Path)
	case strings.Contains(out, "STS_NOTDIR"):
		return fail.New(exitcode.HubPathMissing, "hub", "hub path exists but is not a directory on %s: %s", h.Host, h.Path)
	case strings.Contains(out, "STS_NOREAD"):
		return fail.New(exitcode.HubPerms, "hub", "hub user '%s' cannot READ %s on %s", h.User, h.Path, h.Host)
	case strings.Contains(out, "STS_NOWRITE"):
		return fail.New(exitcode.HubPerms, "hub", "hub user '%s' cannot WRITE %s on %s - check ownership and mode", h.User, h.Path, h.Host)
	}
	return fail.New(exitcode.HubPerms, "hub", "unexpected hub path probe result: %s", out)
}

// Manifest is the hub side's manifest: built here when this machine is the
// hub (identical to the script's, see package manifest), else the script's
// own MANIFEST_SCRIPT run on the hub.
func (h *Hub) Manifest() (manifest.Manifest, error) {
	if h.IsLocal {
		return manifest.Build(h.Path, h.Exclude)
	}
	args := append([]string{h.Path, manifest.SnapDirName, manifest.LockDirName}, h.Exclude...)
	out, err := h.Exec.Output(h.Stderr, manifestScript, args...)
	if err != nil {
		return manifest.Manifest{}, err
	}
	return manifest.Parse(out), nil
}

// Newest is newest_mtime_hub: the newest file's mtime, snapshot and lock
// dirs left out, 0 for none.
func (h *Hub) Newest() int64 {
	if h.IsLocal {
		return NewestLocal(h.Path)
	}
	out, _ := h.Exec.Output(io.Discard, newestScript, h.Path, manifest.SnapDirName, manifest.LockDirName)
	n, _ := strconv.ParseInt(strings.TrimSpace(out), 10, 64)
	return n
}

// NewestLocal is newest_mtime_local.
func NewestLocal(dir string) int64 {
	var newest int64
	root, err := filepath.EvalSymlinks(dir)
	if err != nil {
		return 0
	}
	_ = filepath.WalkDir(root, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			if d != nil && d.IsDir() && p != root {
				return filepath.SkipDir
			}
			return nil
		}
		if d.IsDir() && p != root {
			if rel, _ := filepath.Rel(root, p); rel == manifest.SnapDirName || rel == manifest.LockDirName {
				return filepath.SkipDir
			}
		}
		if d.Type().IsRegular() {
			if info, err := d.Info(); err == nil && info.ModTime().Unix() > newest {
				newest = info.ModTime().Unix()
			}
		}
		return nil
	})
	return newest
}

// LockInfo is status's probe: the hub lock owner's first three lines (host,
// pid, time) joined by spaces, or "" when the lock is free.
func (h *Hub) LockInfo() string {
	out, _ := h.Exec.Output(io.Discard, lockInfoScript, filepath.Dir(strings.TrimRight(h.Path, "/"))+"/"+lock.DirName)
	return out
}
