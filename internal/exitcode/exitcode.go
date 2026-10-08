// Package exitcode is the exit code table, the tool's documented interface; the numbers are the bash script's.
package exitcode

// Code is a process exit status from the table.
type Code int

const (
	OK    Code = 0
	Usage Code = 2

	ConfigMissing    Code = 10 // config absent or unreadable
	ConfigMalformed  Code = 11 // unparseable line or unknown key
	ConfigIncomplete Code = 12 // required keys missing or empty
	LocalSaveBad     Code = 13 // local save path missing/not a dir/empty
	HubPathMissing   Code = 14 // hub path absent on the hub host
	Root             Code = 15 // running as root
	BashOld          Code = 16 // bash older than 3.2 (bash build only)
	ToolMissing      Code = 17 // rsync or ssh not on PATH

	TSMissing     Code = 20 // tailscale binary not found
	TSDaemon      Code = 21 // tailscaled not running
	TSLoggedOut   Code = 22 // node logged out or Stopped
	TSInteractive Code = 23 // tailscale up needs a browser login
	TSNoPeer      Code = 24 // hub host absent from the tailnet
	TSPeerOffline Code = 25 // hub host present but offline
	TSPing        Code = 26 // tailscale ping failed or timed out

	SSHFailed  Code = 30 // non-interactive ssh failed
	SSHHostkey Code = 31 // host key unknown or changed
	HubPerms   Code = 32 // remote user cannot read/write hub dir
	Rsync      Code = 33 // rsync exited non-zero
	DiskFull   Code = 34 // no space on either side

	GameRunning Code = 40 // game is running on this machine
	GameNoStart Code = 41 // game never started

	LockRemote Code = 50 // hub lock held by another host
	LockCreate Code = 51 // lock could not be created
	LockLocal  Code = 52 // another sts is running on this machine

	Conflict         Code = 60 // both sides changed since last sync
	ConflictFirstRun Code = 61 // first run, both sides non-empty
	HubEmpty         Code = 62 // hub empty, explicit first push needed
	Snapshot         Code = 63 // snapshot failed, so no overwrite allowed
	StateChanged     Code = 64 // --expect-decision no longer true; nothing done
	NoSnapshot       Code = 65 // restore: no such safety copy, or an empty one

	BackupNotMounted Code = 70 // backup volume not mounted
	BackupNotHub     Code = 71 // sts backup run off the hub host
)

// ByScriptName maps the bash script's EX_ names to codes, for the parity test.
var ByScriptName = map[string]Code{
	"EX_OK": OK, "EX_USAGE": Usage,
	"EX_CONFIG_MISSING": ConfigMissing, "EX_CONFIG_MALFORMED": ConfigMalformed,
	"EX_CONFIG_INCOMPLETE": ConfigIncomplete, "EX_LOCAL_SAVE_BAD": LocalSaveBad,
	"EX_HUB_PATH_MISSING": HubPathMissing, "EX_ROOT": Root, "EX_BASH_OLD": BashOld,
	"EX_TOOL_MISSING": ToolMissing,
	"EX_TS_MISSING":   TSMissing, "EX_TS_DAEMON": TSDaemon, "EX_TS_LOGGED_OUT": TSLoggedOut,
	"EX_TS_INTERACTIVE": TSInteractive, "EX_TS_NO_PEER": TSNoPeer,
	"EX_TS_PEER_OFFLINE": TSPeerOffline, "EX_TS_PING": TSPing,
	"EX_SSH_FAILED": SSHFailed, "EX_SSH_HOSTKEY": SSHHostkey, "EX_HUB_PERMS": HubPerms,
	"EX_RSYNC": Rsync, "EX_DISK_FULL": DiskFull,
	"EX_GAME_RUNNING": GameRunning, "EX_GAME_NO_START": GameNoStart,
	"EX_LOCK_REMOTE": LockRemote, "EX_LOCK_CREATE": LockCreate, "EX_LOCK_LOCAL": LockLocal,
	"EX_CONFLICT": Conflict, "EX_CONFLICT_FIRSTRUN": ConflictFirstRun,
	"EX_HUB_EMPTY": HubEmpty, "EX_SNAPSHOT": Snapshot, "EX_STATE_CHANGED": StateChanged,
	"EX_NO_SNAPSHOT":        NoSnapshot,
	"EX_BACKUP_NOT_MOUNTED": BackupNotMounted, "EX_BACKUP_NOT_HUB": BackupNotHub,
}
