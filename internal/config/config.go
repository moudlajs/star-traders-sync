// Package config reads the KEY=value config as the bash script does: parsed, never evaluated, keys whitelisted.
package config

import (
	"bufio"
	"bytes"
	"fmt"
	"os"
	"os/user"
	"strconv"
	"strings"

	"github.com/moudlajs/star-traders-sync/internal/exitcode"
	"github.com/moudlajs/star-traders-sync/internal/fail"
)

// Failure is a refusal (see package fail).
type Failure = fail.Failure

func refuse(code exitcode.Code, format string, a ...any) *Failure {
	return fail.New(code, "config", format, a...)
}

var known = []string{
	"HUB_HOST", "HUB_USER", "HUB_PATH",
	"LOCAL_SAVE_PATH",
	"STEAM_APPID", "GAME_PROCESS_NAME", "GAME_START_TIMEOUT",
	"SSH_PORT", "SSH_EXTRA_OPTS", "SSH_CONNECT_TIMEOUT", "PREFER_MAGICDNS",
	"SYNC_EXCLUDE",
	"SNAPSHOT_KEEP", "LOCK_TTL_SECONDS", "CLOCK_SKEW_TOLERANCE",
	"BACKUP_VOLUME", "BACKUP_DEST", "BACKUP_KEEP", "BACKUP_MOUNT_WAIT",
	"LOG_MAX_BYTES", "LOG_KEEP", "LOG_LEVEL",
}

var defaults = map[string]string{
	"GAME_START_TIMEOUT": "90", "SSH_PORT": "22", "SSH_CONNECT_TIMEOUT": "10",
	"PREFER_MAGICDNS": "1", "SNAPSHOT_KEEP": "10", "LOCK_TTL_SECONDS": "3600",
	"CLOCK_SKEW_TOLERANCE": "300", "BACKUP_KEEP": "30", "BACKUP_MOUNT_WAIT": "0",
	"LOG_MAX_BYTES": "5242880", "LOG_KEEP": "3", "LOG_LEVEL": "INFO",
}

var required = []string{"HUB_HOST", "HUB_USER", "HUB_PATH", "LOCAL_SAVE_PATH",
	"STEAM_APPID", "GAME_PROCESS_NAME", "BACKUP_VOLUME", "BACKUP_DEST"}

var numeric = []string{"GAME_START_TIMEOUT", "SSH_PORT", "SSH_CONNECT_TIMEOUT", "PREFER_MAGICDNS",
	"SNAPSHOT_KEEP", "LOCK_TTL_SECONDS", "CLOCK_SKEW_TOLERANCE", "BACKUP_KEEP",
	"BACKUP_MOUNT_WAIT", "LOG_MAX_BYTES", "LOG_KEEP"}

var pathKeys = []string{"HUB_PATH", "LOCAL_SAVE_PATH", "BACKUP_VOLUME", "BACKUP_DEST"}

func isKnown(k string) bool {
	for _, x := range known {
		if x == k {
			return true
		}
	}
	return false
}

func isPath(k string) bool {
	for _, x := range pathKeys {
		if x == k {
			return true
		}
	}
	return false
}

// Config is the parsed file: every known key, defaults filled in.
type Config struct {
	File   string
	values map[string]string
}

// Get returns a key's value ("" when unset and without a default).
func (c *Config) Get(key string) string { return c.values[key] }

// Int returns a numeric key. Only meaningful after Validate.
func (c *Config) Int(key string) int {
	n, _ := strconv.Atoi(c.values[key])
	return n
}

// Exclude is SYNC_EXCLUDE split on whitespace, as the script's unquoted loop splits it.
func (c *Config) Exclude() []string { return strings.Fields(c.values["SYNC_EXCLUDE"]) }

// Load parses the file. home expands a leading ~ in path keys.
func Load(path, home string) (*Config, *Failure) {
	st, err := os.Stat(path)
	if err != nil {
		return nil, refuse(exitcode.ConfigMissing, "no config at %s - copy config.example there and edit it", path)
	}
	if !st.Mode().IsRegular() {
		return nil, refuse(exitcode.ConfigMissing, "%s exists but is not a regular file", path)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, refuse(exitcode.ConfigMissing, "%s is not readable by %s", path, whoami())
	}

	c := &Config{File: path, values: map[string]string{}}
	for k, v := range defaults {
		c.values[k] = v
	}
	sc := bufio.NewScanner(bytes.NewReader(data))
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	lineno := 0
	for sc.Scan() {
		lineno++
		// ScanLines drops one trailing CR, so a CRLF file parses.
		line := sc.Text()
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		eq := strings.IndexByte(line, '=')
		if eq < 0 {
			return nil, refuse(exitcode.ConfigMalformed, "%s line %d is not KEY=value: %s", path, lineno, line)
		}
		// The script deletes every whitespace character from the key (tr -d '[:space:]'), not only the ends.
		key := strings.Map(func(r rune) rune {
			if strings.ContainsRune(" \t\n\v\f\r", r) {
				return -1
			}
			return r
		}, line[:eq])
		if !isKnown(key) {
			return nil, refuse(exitcode.ConfigMalformed, "%s line %d: unknown key '%s' - see config.example", path, lineno, key)
		}
		val := strings.Trim(line[eq+1:], " \t\n\v\f\r")
		if isPath(key) && val != "" {
			val = expandTilde(val, home)
			for len(val) > 1 && strings.HasSuffix(val, "/") {
				val = strings.TrimSuffix(val, "/")
			}
		}
		c.values[key] = val
	}
	return c, nil
}

func expandTilde(p, home string) string {
	switch {
	case p == "~":
		return home
	case strings.HasPrefix(p, "~/"):
		return home + "/" + p[2:]
	}
	return p
}

func whoami() string {
	if u, err := user.Current(); err == nil {
		return u.Username
	}
	return "this user"
}

func onlyChars(s, allowed string) bool {
	for _, r := range s {
		if !strings.ContainsRune(allowed, r) {
			return false
		}
	}
	return true
}

const alnum = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

// Validate makes the script's checks, in its order, with its messages.
func (c *Config) Validate() *Failure {
	var missing []string
	for _, k := range required {
		if c.values[k] == "" {
			missing = append(missing, k)
		}
	}
	if len(missing) > 0 {
		lines := []string{"error: required config keys are missing or empty:"}
		for _, k := range missing {
			lines = append(lines, "  "+k)
		}
		lines = append(lines, fmt.Sprintf("edit %s - see config.example for what each one means", c.File))
		return fail.Printed(exitcode.ConfigIncomplete, "config", "missing required keys: "+strings.Join(missing, " "), lines...)
	}

	for _, k := range numeric {
		v := c.values[k]
		if v == "" || !onlyChars(v, "0123456789") {
			return refuse(exitcode.ConfigMalformed, "%s must be a non-negative integer, got '%s'", k, v)
		}
	}

	switch c.values["LOG_LEVEL"] {
	case "DEBUG", "INFO", "WARN", "ERROR":
	default:
		return refuse(exitcode.ConfigMalformed, "LOG_LEVEL must be DEBUG, INFO, WARN or ERROR, got '%s'", c.values["LOG_LEVEL"])
	}

	hub := c.values["HUB_PATH"]
	if !strings.HasPrefix(hub, "/") {
		return refuse(exitcode.ConfigMalformed, "HUB_PATH must be absolute - it is evaluated on the hub host, where ~ is the hub user's home, got '%s'", hub)
	}

	// openrsync has no --protect-args, so a remote path goes through the hub's login shell (#42).
	for _, k := range pathKeys {
		v := c.values[k]
		if !onlyChars(v, alnum+"._/@+-") {
			return refuse(exitcode.ConfigMalformed, "%s contains a character that cannot survive being passed to a remote shell: '%s'. Allowed: letters, digits, and . _ / @ + - (no spaces, quotes or shell metacharacters).", k, v)
		}
	}
	for _, name := range c.Exclude() {
		if !onlyChars(name, alnum+"._*@+-") {
			return refuse(exitcode.ConfigMalformed, "SYNC_EXCLUDE entry '%s' contains an unsafe character", name)
		}
	}

	local := c.values["LOCAL_SAVE_PATH"]
	if hub == local {
		return refuse(exitcode.ConfigMalformed, "HUB_PATH and LOCAL_SAVE_PATH are the same directory. The hub must be separate from the game's save directory, on every machine including the hub itself.")
	}
	if strings.HasPrefix(local+"/", hub+"/") {
		return refuse(exitcode.ConfigMalformed, "LOCAL_SAVE_PATH (%s) is inside HUB_PATH (%s) - a push would move the live save directory out from under the game", local, hub)
	}
	if strings.HasPrefix(hub+"/", local+"/") {
		return refuse(exitcode.ConfigMalformed, "HUB_PATH (%s) is inside LOCAL_SAVE_PATH (%s) - the hub would be synced into itself", hub, local)
	}

	vol, dest := c.values["BACKUP_VOLUME"], c.values["BACKUP_DEST"]
	if !strings.HasPrefix(dest, vol+"/") {
		return refuse(exitcode.ConfigMalformed, "BACKUP_DEST (%s) must live under BACKUP_VOLUME (%s)", dest, vol)
	}
	return nil
}
