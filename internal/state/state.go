// Package state is the last-sync record (last-sync.json, version 2), in the format the script and the app share.
package state

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/moudlajs/star-traders-sync/internal/decide"
)

type record struct {
	Version          int    `json:"version"`
	Direction        string `json:"direction"`
	Timestamp        string `json:"timestamp"`
	Epoch            int64  `json:"epoch"`
	LocalFingerprint string `json:"local_fingerprint"`
	HubFingerprint   string `json:"hub_fingerprint"`
	HubHost          string `json:"hub_host"`
	HubPath          string `json:"hub_path"`
}

// Read returns the recorded state for this hub; anything else is a first run, never "nothing changed".
func Read(path, hubHost, hubPath string) decide.State {
	first := decide.State{FirstRun: true}
	data, err := os.ReadFile(path)
	if err != nil {
		return first
	}
	var raw map[string]any
	if json.Unmarshal(data, &raw) != nil {
		return first
	}
	if v, ok := raw["version"].(float64); !ok || v != 2 {
		return first
	}
	if raw["hub_host"] != hubHost || raw["hub_path"] != hubPath {
		return first
	}
	var st decide.State
	for _, f := range []struct {
		key string
		dst *string
	}{{"direction", &st.Direction}, {"epoch", &st.Epoch},
		{"local_fingerprint", &st.LocalFP}, {"hub_fingerprint", &st.HubFP}} {
		v, ok := raw[f.key]
		if !ok || v == nil {
			return first
		}
		switch x := v.(type) {
		case string:
			*f.dst = x
		case float64:
			*f.dst = fmt.Sprintf("%d", int64(x))
		default:
			return first
		}
	}
	return st
}

// Write records a sync atomically (temp file and rename), in the bytes the script writes.
func Write(path, direction, localFP, hubFP, hubHost, hubPath string, now time.Time) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(record{Version: 2, Direction: direction,
		Timestamp: now.UTC().Format("2006-01-02T15:04:05Z"), Epoch: now.Unix(),
		LocalFingerprint: localFP, HubFingerprint: hubFP, HubHost: hubHost, HubPath: hubPath}); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, buf.Bytes(), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
