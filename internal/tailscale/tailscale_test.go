package tailscale

import (
	"encoding/json"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"testing"
)

const sample = `{"BackendState":"Running",
 "Self":{"HostName":"thisclient","DNSName":"thisclient.t.ts.net.","TailscaleIPs":["100.64.0.9"],"Online":true},
 "Peer":{"z":{"HostName":"remotehub","DNSName":"remotehub.t.ts.net.","TailscaleIPs":["fd7a::1","100.64.0.1"],"Online":true},
         "a":{"HostName":"remotehub","DNSName":"remotehub-1.t.ts.net.","TailscaleIPs":["100.64.0.2"],"Online":false},
         "m":{"HostName":"Renamed","DNSName":"oldname.t.ts.net.","TailscaleIPs":["fd7a::9"],"Online":true}}}`

func parse(t *testing.T) *Status {
	t.Helper()
	var st Status
	if err := json.Unmarshal([]byte(sample), &st); err != nil {
		t.Fatal(err)
	}
	return &st
}

func TestFindPeerAsTheScript(t *testing.T) {
	st := parse(t)
	for host, want := range map[string]Found{
		// Two peers share a HostName: the first in the document wins, with its first IPv4 address.
		"remotehub":          {DNS: "remotehub.t.ts.net", IP: "100.64.0.1", Online: true},
		"REMOTEHUB":          {DNS: "remotehub.t.ts.net", IP: "100.64.0.1", Online: true},
		"remotehub-1":        {DNS: "remotehub-1.t.ts.net", IP: "100.64.0.2", Online: false},
		"oldname":            {DNS: "oldname.t.ts.net", IP: "fd7a::9", Online: true}, // no IPv4: the first address
		"renamed":            {DNS: "oldname.t.ts.net", IP: "fd7a::9", Online: true},
		"remotehub.t.ts.net": {DNS: "remotehub.t.ts.net", IP: "100.64.0.1", Online: true},
		"thisclient":         {DNS: "thisclient.t.ts.net", IP: "100.64.0.9", Online: true}, // Self last
	} {
		got, ok := FindPeer(st, host)
		if !ok || got != want {
			t.Errorf("%s: %+v %v, want %+v", host, got, ok, want)
		}
	}
	if _, ok := FindPeer(st, "nope"); ok {
		t.Error("found a host that is not there")
	}
	for i := 0; i < 50; i++ { // document order, every time
		if got, _ := FindPeer(parse(t), "remotehub"); got.IP != "100.64.0.1" {
			t.Fatal("peer order is not stable")
		}
	}
}

func TestHubIsSelfByHostNameOrShortDNS(t *testing.T) {
	st := parse(t)
	for host, want := range map[string]bool{"thisclient": true, "ThisClient": true, "thisclient.t.ts.net": false, "remotehub": false} {
		if got, _ := HubIsSelf(st, host); got != want {
			t.Errorf("%s: %v", host, got)
		}
	}
	st.Self.HostName = "renamed-in-console"
	if got, _ := HubIsSelf(st, "thisclient"); !got {
		t.Error("the short MagicDNS label still names this machine after a rename")
	}
}

// The script's ts_find_peer, run on the same JSON, for every name above.
func TestFindPeerMatchesTheScript(t *testing.T) {
	src, err := os.ReadFile("../../bin/star-traders-sync")
	if err != nil {
		t.Fatal(err)
	}
	fn := regexp.MustCompile(`(?ms)^ts_find_peer\(\) \{\n.*?^\}\n`).Find(src)
	if fn == nil {
		t.Fatal("ts_find_peer not found")
	}
	st := parse(t)
	for _, host := range []string{"remotehub", "REMOTEHUB", "remotehub-1", "oldname", "renamed", "remotehub.t.ts.net", "thisclient", "nope"} {
		out, err := exec.Command("/bin/bash", "-c", string(fn)+`ts_find_peer "$1" "$2"`, "x", sample, host).Output()
		if err != nil {
			t.Fatal(err)
		}
		want := strings.TrimRight(string(out), "\n")
		got := ""
		if f, ok := FindPeer(st, host); ok {
			online := "0"
			if f.Online {
				online = "1"
			}
			got = f.DNS + "\t" + f.IP + "\t" + online
		}
		if got != want {
			t.Errorf("%s: go %q, script %q", host, got, want)
		}
	}
}
