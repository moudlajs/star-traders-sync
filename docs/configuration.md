# Configuration

The config lives at `~/.config/star-traders-sync/config` (or under
`$XDG_CONFIG_HOME` if you set it). `install.sh` and the setup app both
write a short working one. [`config.example`](../config.example) lists
every key with a one-line note; this page is the full reference.

## Format

- `KEY=value`, one per line. Blank lines and lines starting with `#` are
  ignored. Whitespace around the key and the value is trimmed.
- The file is **parsed, never sourced**: no shell syntax, no quotes, no
  `$VARIABLES`. An unknown key is a hard error (exit 11), so a typo cannot
  silently fall back to a default.
- A leading `~/` is expanded in the four path keys only, per machine.
  Trailing slashes on paths are dropped.
- Path values may contain only letters, digits and `. _ / @ + -`. No
  spaces or quotes: rsync hands remote paths to a shell, see
  [design.md](design.md#notes-on-paths).

## Required keys

`sts` refuses to run (exit 12) unless all eight of these are set, and lists
every missing one at once. `sts doctor` checks the same eight.

`BACKUP_VOLUME` and `BACKUP_DEST` are only ever used by `sts backup` on the
hub host, but are currently required on every machine (#53). The setup app
writes `/Volumes/sts-no-backup-disk` on a machine without a disk.

## All keys

"Scope" says whether a key must be the **same** on every machine, or is
**per machine**.

| Key | Required | Default | Scope | What it is |
|---|---|---|---|---|
| `HUB_HOST` | yes | — | same | Tailscale node name of the hub machine, as `tailscale status` shows it. Case-insensitive. On the hub itself, the hub is reached by local path instead of ssh. |
| `HUB_USER` | yes | — | same | The account **on the hub** that ssh logs in as. Ignored on the hub. |
| `HUB_PATH` | yes | — | same | Absolute path of the hub directory on the hub host. Must start with `/`, because it is evaluated there, where `~` is the hub user's home. |
| `LOCAL_SAVE_PATH` | yes | — | per machine | The game's save directory on this machine, usually `~/Library/StarTradersFrontiers`. See [finding it](design.md#finding-your-save-directory). |
| `STEAM_APPID` | yes | — | same | `335620`, Star Traders: Frontiers. `sts play` launches it through Steam. |
| `GAME_PROCESS_NAME` | yes | — | same | `StarTradersFrontiers`. Push and pull refuse while a process of this name runs. |
| `BACKUP_VOLUME` | yes (#53) | — | per machine | Mount point of the backup disk. Hub host only in practice. |
| `BACKUP_DEST` | yes (#53) | — | per machine | Where timestamped backups go. Must be under `BACKUP_VOLUME`. |
| `SYNC_EXCLUDE` | no | empty | same | File names never transferred, space separated. See below. |
| `GAME_START_TIMEOUT` | no | `90` | per machine | Seconds `sts play` waits for the game to appear. If it never does, nothing is pushed. |
| `SSH_PORT` | no | `22` | per machine | ssh port on the hub. |
| `SSH_CONNECT_TIMEOUT` | no | `10` | per machine | Seconds before an ssh connection attempt gives up. |
| `SSH_EXTRA_OPTS` | no | empty | per machine | Extra ssh options, space separated. `BatchMode`, `ConnectTimeout` and `StrictHostKeyChecking` are always set and cannot be overridden. |
| `PREFER_MAGICDNS` | no | `1` | per machine | `1` tries the MagicDNS name first and falls back to the tailnet IP; `0` always uses the IP. |
| `SNAPSHOT_KEEP` | no | `10` | per machine | Snapshots kept per side. Pruning is suspended while the live directory is empty, so the last copy cannot age out. |
| `LOCK_TTL_SECONDS` | no | `3600` | per machine | A hub lock left by a crashed run **on this machine** is cleared once older than this, logged at WARN. A lock held by another machine is never cleared automatically. |
| `CLOCK_SKEW_TOLERANCE` | no | `300` | per machine | Warn when the hub's clock differs by more than this many seconds. Only the timestamps shown to you are affected; decisions use content fingerprints. |
| `BACKUP_KEEP` | no | `30` | per machine | Backup directories kept. `0` disables pruning. |
| `BACKUP_MOUNT_WAIT` | no | `0` | per machine | Seconds `sts backup` waits for the disk to mount. `0` is right for an interactive run; the nightly job installer sets `180`, because a disk can take a moment to remount after wake. |
| `LOG_MAX_BYTES` | no | `5242880` | per machine | Log rotation size, 5 MB. The log is `~/Library/Logs/star-traders-sync/star-traders-sync.log`. |
| `LOG_KEEP` | no | `3` | per machine | Rotated log files kept. |
| `LOG_LEVEL` | no | `INFO` | per machine | `DEBUG`, `INFO`, `WARN` or `ERROR`, for the log file. `--verbose` mirrors the log to stderr regardless. |

## HUB_PATH and LOCAL_SAVE_PATH

They must be different directories, and neither may be inside the other,
on every machine including the hub (exit 11). On the hub both are local
paths, and nesting them would let a push move the live save directory out
from under the game.

## SYNC_EXCLUDE

`install.sh` and the setup app both write:

```
SYNC_EXCLUDE=data.db steam_autocloud.vdf
```

Keep it. `data.db` is static game content that ships with the game binary,
not a save; syncing it between two different game versions would be
harmful. `steam_autocloud.vdf` is an inert Steam marker holding your
account id. Without the line, nothing is excluded.

Excluded files are **per machine**. They are never sent in either
direction, and a sync carries each side's own copy across the directory
swap, so they are preserved rather than deleted. The list itself should be
the same on both machines.
