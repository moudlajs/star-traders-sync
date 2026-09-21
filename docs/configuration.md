# Configuration

`~/.config/star-traders-sync/config`, created by `install.sh` from
`config.example`. This page is the reference for every key; `config.example`
is the annotated starting point.

## Format

`KEY=value`, one per line. Blank lines and lines starting with `#` are
ignored, and a trailing carriage return is stripped so a file edited on
another platform still parses.

**The file is parsed, never sourced.** No shell syntax, no quotes, no command
substitution, no variable expansion — a config file must not be able to
execute code. A line that is not `KEY=value` is exit 11, and so is an
**unknown key**: a typo is a hard error rather than a silently ignored
setting.

A leading `~/` is expanded, and only in the four path keys below. Nothing
else is expanded anywhere.

## Every key

Defaults are the values the tool uses when the key is absent. This table is
the only place they are written down; anywhere else that mentions one links
here.

| Key | Required | Default | |
|---|---|---|---|
| `HUB_HOST` | **yes** | — | Tailscale node name of the machine hosting the hub, as `tailscale status` shows it. Matched case-insensitively. When it names this machine, the hub is reached by local path copy instead of ssh. |
| `HUB_USER` | **yes** | — | SSH account **on the hub**. Ignored when running on the hub itself. |
| `HUB_PATH` | **yes** | — | The hub directory, **on the hub host**. Must be absolute, since it is evaluated remotely where `~` is the hub user's home. |
| `LOCAL_SAVE_PATH` | **yes** | — | Where the game keeps its saves on *this* machine. Verify it rather than trusting the example — see [design.md](design.md#finding-your-save-directory). |
| `STEAM_APPID` | **yes** | — | From `appmanifest_<id>.acf`. `335620` is Star Traders: Frontiers. |
| `GAME_PROCESS_NAME` | **yes** | — | Name for `pgrep -x`. `push` and `pull` refuse while it is running. |
| `BACKUP_VOLUME` | **yes** | — | Mount point that must be present for `sts backup`. Checked by comparing device ids, so an unmounted volume is detected rather than silently written to on the internal disk. |
| `BACKUP_DEST` | **yes** | — | Where timestamped backups go. Must live under `BACKUP_VOLUME`. |
| `SYNC_EXCLUDE` | no | empty | Space-separated file names never transferred in either direction. May contain `*`. |
| `GAME_START_TIMEOUT` | no | `90` | Seconds `sts play` waits for the game to appear before declaring it never started. Nothing is pushed in that case. |
| `SSH_PORT` | no | `22` | |
| `SSH_CONNECT_TIMEOUT` | no | `10` | |
| `SSH_EXTRA_OPTS` | no | empty | Extra ssh options, space separated. `BatchMode`, `ConnectTimeout` and `StrictHostKeyChecking` are always set by the tool and cannot be overridden here. |
| `PREFER_MAGICDNS` | no | `1` | `1` tries MagicDNS and falls back to the tailnet IP; `0` always uses the IP. The fallback is normal where `tailscaled` installs no system resolver, and which one was used is logged. |
| `SNAPSHOT_KEEP` | no | `10` | Snapshots kept per side. Pruning is suspended while the live directory is empty, so the last copy cannot be aged out. |
| `LOCK_TTL_SECONDS` | no | `3600` | A hub lock left by a crashed run **on this machine** is cleared once older than this, logged at WARN. A lock held by any other machine is never cleared automatically, at any age. |
| `CLOCK_SKEW_TOLERANCE` | no | `300` | Warn when the hub's clock differs by more than this many seconds. |
| `BACKUP_KEEP` | no | `30` | Timestamped backup directories to keep. `0` disables pruning. |
| `BACKUP_MOUNT_WAIT` | no | `0` | Seconds to wait for `BACKUP_VOLUME` to appear. The launchd installer raises this to 180, because a scheduled run can fire moments after wake. `0` is right for an interactive run. |
| `LOG_MAX_BYTES` | no | `5242880` | Rotation threshold for `~/Library/Logs/star-traders-sync/star-traders-sync.log`. |
| `LOG_KEEP` | no | `3` | Rotated log files kept. |
| `LOG_LEVEL` | no | `INFO` | `DEBUG`, `INFO`, `WARN` or `ERROR`. Affects the log file; `--verbose` mirrors to stderr regardless. |

All eight required keys are checked at once and every missing one is listed
together, rather than one per run (exit 12).

`BACKUP_VOLUME` and `BACKUP_DEST` are required **even if you never run
`sts backup`**. Set them to a path on a disk you own and ignore them if
backups are not for you.

## What must match, and what must not

| | |
|---|---|
| `HUB_HOST`, `HUB_USER`, `HUB_PATH` | **must match** on every machine — they name one hub, and two machines pointing at different hubs are not syncing with each other |
| `SYNC_EXCLUDE` | **must match** on every machine. The excluded *files* are machine-local, but the *list* is not: fingerprint manifests are built with these names excluded, so if the two sides disagree about the list their manifests can never agree, and every sync reports a conflict |
| `STEAM_APPID`, `GAME_PROCESS_NAME` | the same game, so in practice the same value |
| `LOCAL_SAVE_PATH` | per machine. Usually the same string, but it is resolved locally and nothing compares them |
| `BACKUP_VOLUME`, `BACKUP_DEST` | per machine, and only meaningful on the hub host — `sts backup` exits 71 anywhere else |
| `LOCK_TTL_SECONDS` | per machine, but it decides when *this* machine's own stale hub lock is cleared, so a much larger value on one machine means its abandoned locks sit there longer |
| everything else | per machine, no coordination needed |

## Rules the tool enforces

Each of these is exit 11 with a message naming the key:

- **`HUB_PATH` must be absolute.** It is evaluated on the hub, where `~` is
  the hub user's home, not yours.
- **`HUB_PATH` and `LOCAL_SAVE_PATH` must be different directories**, and
  neither may be nested inside the other. On the hub host both are local
  paths, so nesting would let a push move the live save directory out from
  under the game. The hub is never a game save directory, on any machine.
- **`BACKUP_DEST` must live under `BACKUP_VOLUME`**, or the mount check
  protects nothing.
- **Path keys accept only `A-Za-z0-9._/@+-`** — no spaces, quotes or shell
  metacharacters. This is a limitation of rsync rather than of this tool; the
  reasoning is in [design.md](design.md#notes-on-paths), and lifting it is
  [#42](https://github.com/moudlajs/star-traders-sync/issues/42).
- **`SYNC_EXCLUDE` entries accept `A-Za-z0-9._*@+-`** — as above, plus `*`.
- **Numeric keys must be non-negative integers.** `GAME_START_TIMEOUT`,
  `SSH_PORT`, `SSH_CONNECT_TIMEOUT`, `PREFER_MAGICDNS`, `SNAPSHOT_KEEP`,
  `LOCK_TTL_SECONDS`, `CLOCK_SKEW_TOLERANCE`, `BACKUP_KEEP`,
  `BACKUP_MOUNT_WAIT`, `LOG_MAX_BYTES`, `LOG_KEEP`. A non-numeric value fails
  here rather than making later arithmetic quietly wrong.
- **`LOG_LEVEL` must be one of the four levels.**

`sts doctor` reports which required keys are still at their example
placeholders, and `sts doctor --fix` never edits this file.

## A note on SYNC_EXCLUDE

An excluded file is never transferred, but a transfer replaces the whole
directory, so a file that was never transferred would simply be absent from
the replacement. Excluded files are therefore copied from the live directory
into the staging directory before the swap, on both sides — this is the one
place where "never touched" needs active work to stay true. See
[design.md](design.md#data-safety).
