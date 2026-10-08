// Package tailscale finds the hub on the tailnet as the script does: binary, daemon, one "tailscale up", peer.
package tailscale

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strings"

	"github.com/moudlajs/star-traders-sync/internal/exitcode"
	"github.com/moudlajs/star-traders-sync/internal/fail"
	"github.com/moudlajs/star-traders-sync/internal/logx"
	"github.com/moudlajs/star-traders-sync/internal/platform"
)

// AppPath is the App Store build's CLI, preferred over PATH; STS_TS_APP_PATH overrides it for the suite.
func AppPath(getenv func(string) string) string {
	if p := getenv("STS_TS_APP_PATH"); p != "" {
		return p
	}
	return platform.TailscaleAppPath
}

// Find is find_tailscale.
func Find(appPath string, lookPath func(string) (string, error), log *logx.Logger) (string, *fail.Failure) {
	if st, err := os.Stat(appPath); err == nil && !st.IsDir() && st.Mode()&0o111 != 0 {
		log.Log("DEBUG", "tailscale", "using App Store binary %s", appPath)
		return appPath, nil
	}
	if p, err := lookPath("tailscale"); err == nil {
		log.Log("DEBUG", "tailscale", "using PATH binary %s", p)
		return p, nil
	}
	return "", fail.New(exitcode.TSMissing, "tailscale",
		"tailscale not found at %s nor on PATH - install the Tailscale app or 'brew install tailscale'", appPath)
}

// Peer is one node in tailscale status --json.
type Peer struct {
	HostName     string   `json:"HostName"`
	DNSName      string   `json:"DNSName"`
	TailscaleIPs []string `json:"TailscaleIPs"`
	Online       bool     `json:"Online"`
}

// Status is what the tool reads of tailscale status --json; Peers keep document order, as the script takes the first match.
type Status struct {
	BackendState string
	Self         *Peer
	Peers        []Peer
}

func (s *Status) UnmarshalJSON(b []byte) error {
	var raw struct {
		BackendState string          `json:"BackendState"`
		Self         *Peer           `json:"Self"`
		Peer         json.RawMessage `json:"Peer"`
	}
	if err := json.Unmarshal(b, &raw); err != nil {
		return err
	}
	s.BackendState, s.Self, s.Peers = raw.BackendState, raw.Self, nil
	if len(raw.Peer) == 0 || string(raw.Peer) == "null" {
		return nil
	}
	dec := json.NewDecoder(bytes.NewReader(raw.Peer))
	if t, err := dec.Token(); err != nil || t != json.Delim('{') {
		return fmt.Errorf("Peer is not an object")
	}
	for dec.More() {
		if _, err := dec.Token(); err != nil {
			return err
		}
		var p Peer
		if err := dec.Decode(&p); err != nil {
			return err
		}
		s.Peers = append(s.Peers, p)
	}
	return nil
}

// Client runs one tailscale binary.
type Client struct {
	Bin    string
	Log    *logx.Logger
	Stderr interface{ Write([]byte) (int, error) }
}

func (c *Client) run(args ...string) (stdout, stderr string, code int) {
	var o, e bytes.Buffer
	cmd := exec.Command(c.Bin, args...)
	cmd.Stdout, cmd.Stderr = &o, &e
	err := cmd.Run()
	code = 0
	if err != nil {
		code = 1
		if ee, ok := err.(*exec.ExitError); ok {
			code = ee.ExitCode()
		}
	}
	return o.String(), e.String(), code
}

func trimNL(s string) string { return strings.TrimRight(s, "\n") }

func firstLines(s string, n int) string {
	lines := strings.Split(s, "\n")
	if len(lines) > n {
		lines = lines[:n]
	}
	return strings.Join(lines, "\n")
}

// Status is ts_status_json: stdout alone is the JSON (a version warning on stderr once broke every parser).
func (c *Client) Status() (*Status, string, *fail.Failure) {
	out, errOut, code := c.run("status", "--json")
	out, errOut = trimNL(out), trimNL(errOut)
	if code != 0 {
		both := out + " " + errOut
		for _, s := range []string{"is not running", "connect: no such file or directory", "failed to connect to local backend", "Connection refused"} {
			if strings.Contains(both, s) {
				return nil, "", fail.New(exitcode.TSDaemon, "tailscale",
					"tailscaled is not running - start the Tailscale app, or 'sudo tailscaled install-system-daemon'")
			}
		}
		return nil, "", fail.New(exitcode.TSDaemon, "tailscale",
			"tailscale status failed (rc=%d): %s", code, firstLines(out+" "+errOut, 3))
	}
	if errOut != "" {
		c.Log.Log("WARN", "tailscale", "status --json warned: %s", firstLines(errOut, 1))
	}
	var st Status
	if json.Unmarshal([]byte(out), &st) != nil {
		c.Log.Log("ERROR", "tailscale", "status --json was not JSON: %s", firstLines(out, 1))
		said := out
		if said == "" {
			said = errOut
		}
		return nil, "", fail.New(exitcode.TSLoggedOut, "tailscale",
			"Tailscale did not report its status - it is probably not connected on this Mac. Connect it (menu bar > Connect) and try again. It said: %s", firstLines(said, 1))
	}
	return &st, out, nil
}

var loginURL = regexp.MustCompile(`https://login\.tailscale\.com/[A-Za-z0-9/._-]*`)

// EnsureUp is ts_ensure_up: one "tailscale up"; a login URL needs a human, so stop, never wait.
func (c *Client) EnsureUp() (*Status, *fail.Failure) {
	st, _, f := c.Status()
	if f != nil {
		return nil, f
	}
	c.Log.Log("DEBUG", "tailscale", "backend state %s", st.BackendState)
	if st.BackendState == "Running" {
		return st, nil
	}
	state := st.BackendState
	c.Log.Log("WARN", "tailscale", "backend state is %s, attempting 'tailscale up' once", state)
	fmt.Fprintf(c.Stderr, "Tailscale is %s - bringing it up (one attempt)...\n", state)

	so, se, rc := c.run("up", "--timeout=30s")
	out := trimNL(so + se) // the script merges them: 2>&1
	if strings.Contains(out, "https://login.tailscale.com/") {
		url := loginURL.FindString(out)
		c.Log.Log("ERROR", "tailscale", "interactive login required: %s", url)
		return nil, fail.Printed(exitcode.TSInteractive, "tailscale", "",
			"error: Tailscale needs an interactive login or reauth.",
			"Open this URL, then re-run:", "  "+url)
	}
	for _, s := range []string{"Reauthentication required", "key expired", "NeedsLogin"} {
		if strings.Contains(out, s) {
			c.Log.Log("ERROR", "tailscale", "reauth required: %s", out)
			return nil, fail.Printed(exitcode.TSInteractive, "tailscale", "",
				"error: Tailscale needs reauthentication. Run:", "  "+c.Bin+" up")
		}
	}
	st, _, f = c.Status()
	if f != nil {
		return nil, f
	}
	if st.BackendState != "Running" {
		c.Log.Log("ERROR", "tailscale", "still %s after 'tailscale up' (rc=%d): %s", st.BackendState, rc, out)
		return nil, fail.Printed(exitcode.TSLoggedOut, "tailscale", "",
			fmt.Sprintf(`error: Tailscale is still %s after one "tailscale up".`, st.BackendState),
			"tailscale up said:", out)
	}
	c.Log.Log("INFO", "tailscale", "backend now Running after one 'tailscale up'")
	return st, nil
}

// Found is ts_find_peer's answer: the MagicDNS name (no trailing dot), first IPv4, and whether online.
type Found struct {
	DNS    string
	IP     string
	Online bool
}

// FindPeer looks the hub up among the peers, then Self, by HostName or DNS name, case-insensitively.
func FindPeer(st *Status, host string) (Found, bool) {
	want := strings.ToLower(host)
	all := append([]Peer(nil), st.Peers...)
	if st.Self != nil {
		all = append(all, *st.Self)
	}
	for _, p := range all {
		dns := strings.TrimRight(p.DNSName, ".")
		short := strings.SplitN(dns, ".", 2)[0]
		if want == strings.ToLower(p.HostName) || want == strings.ToLower(short) || want == strings.ToLower(dns) {
			ip := ""
			for _, a := range p.TailscaleIPs {
				if !strings.Contains(a, ":") {
					ip = a
					break
				}
			}
			if ip == "" && len(p.TailscaleIPs) > 0 {
				ip = p.TailscaleIPs[0]
			}
			return Found{DNS: dns, IP: ip, Online: p.Online}, true
		}
	}
	return Found{}, false
}

// HubIsSelf is hub_host_matches against Self, by HostName or short MagicDNS label (they differ after a rename).
func HubIsSelf(st *Status, hubHost string) (bool, string) {
	if st.Self == nil {
		return false, ""
	}
	want := strings.ToLower(hubHost)
	short := strings.SplitN(strings.TrimRight(st.Self.DNSName, "."), ".", 2)[0]
	return want == strings.ToLower(st.Self.HostName) || want == strings.ToLower(short), st.Self.HostName
}
