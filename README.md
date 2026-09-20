# star-traders-sync

Sync [Star Traders: Frontiers](https://store.steampowered.com/app/335620/)
save files between two Macs over Tailscale.

The game has no working cloud save on macOS — Steam autocloud is disabled
for this title, because its cloud rules only cover Windows paths. Steam's
own `cloud_log.txt` says so on every launch:

```
[AppID 335620] AutoCloud is disabled.
[AppID 335620]     Skipping rule N because it does not run on our platform   (x14)
```

So this tool does it instead, over `rsync` and `ssh` on the tailnet. No
Syncthing, no iCloud, no third-party service, no background daemon.

## Architecture

```
   MacBook  (workmac)                    Mac mini  (nebulaplex01)
   ~/Library/StarTradersFrontiers        ~/Library/StarTradersFrontiers
            |                                       |
            |  rsync over ssh                       |  local path copy
            |  to the tailnet address               |  (same code path)
            v                                       v
                  ~/star-traders-sync-hub
                   single source of truth
                            |
                            |  sts backup  (hub host only, daily)
                            v
              /Volumes/T9/Backups/star-traders-sync/<ISO>/
```

The hub is a plain directory on the Mac mini. It is **not** a game save
directory, even on the mini itself. Both machines are clients of it,
including the mini, which uses a local path copy instead of ssh — every
other code path is identical.

One script, identical on both machines. All differences live in
`~/.config/star-traders-sync/config`.

## Install

On each machine:

```bash
git clone <this repo> ~/Repos/star-traders-sync
cd ~/Repos/star-traders-sync
./install.sh
$EDITOR ~/.config/star-traders-sync/config
sts status
```

`install.sh` symlinks `star-traders-sync` and the short alias `sts` into
`~/bin`, creates the config directory, and copies `config.example` into
place **only if no config exists** — it never overwrites one. If `~/bin`
is not on your `PATH` it warns and carries on rather than failing.

### One-time SSH setup on each client

The hub must accept a non-interactive key-based login. `BatchMode=yes`
cannot type a password, so a key is required, not a convenience.

```bash
# 1. ON THE HUB - print its real host key fingerprint
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub

# 2. ON THE CLIENT - confirm the same fingerprint comes back over the wire
ssh-keyscan -t ed25519 <hub-tailnet-ip> 2>/dev/null | ssh-keygen -lf -

# 3. ON THE CLIENT - only if they match
ssh-keyscan -t ed25519 <hub-tailnet-ip> >> ~/.ssh/known_hosts
[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -N "" -C "sts@$(hostname -s)"
ssh-copy-id -i ~/.ssh/id_ed25519.pub <hubuser>@<hub-tailnet-ip>

# 4. ON THE CLIENT - prove it is non-interactive
ssh -o BatchMode=yes <hubuser>@<hub-tailnet-ip> 'echo OK'
```

`ssh-copy-id` asks for the **hub account's** password, not the client's.
If it keeps rejecting you, that is almost always the cause. You can skip
it entirely by appending the client's `~/.ssh/id_ed25519.pub` to the hub's
`~/.ssh/authorized_keys` by hand.

Remote Login must be on at the hub: System Settings → General → Sharing →
Remote Login. Check that your user is permitted:

```bash
dseditgroup -o checkmember -m <hubuser> com.apple.access_ssh
```

## Finding your save directory

Never copy a path out of this README into the config without checking it.
On both machines tested it is `~/Library/StarTradersFrontiers` — directly
under `~/Library`, **not** under `Application Support` — but verify:

```bash
# with the game running, ask the process itself
lsof -p "$(pgrep -x StarTradersFrontiers)" | grep -i library

# or diff the filesystem across a launch
touch /tmp/marker
# ... launch the game, save, quit ...
find ~/Library -newer /tmp/marker -not -path "*/Caches/*" 2>/dev/null
```

Confirm the appid from Steam's own manifest rather than trusting a wiki:

```bash
grep -E '"(appid|name)"' /path/to/SteamLibrary/steamapps/appmanifest_335620.acf
```

### What lives in there

| File | Role | Synced |
|---|---|---|
| `core.db` | save index / profile | yes |
| `game_N.db` | one campaign each | yes |
| `game_N.db.1` | the game's own rotation backup | yes |
| `map_N.db` | per-campaign map state | yes |
| `template_N.json` | character creation templates | yes |
| `data.db` | 2.4 MB static game content | **no** — see `SYNC_EXCLUDE` |
| `steam_autocloud.vdf` | inert Steam marker, holds your account id | **no** |

`core.db`, `data.db` and every `game_*.db` are **encrypted blobs** with no
recognisable header. They can never be inspected, diffed or merged — only
moved whole. That is why a two-sided change is always a conflict you
resolve by hand, and never something this tool tries to be clever about.

## Commands

| Command | Effect |
|---|---|
| `sts status` | read-only. File counts, newest timestamps, fingerprints, which side is newer, hub lock, tailscale state, whether the game is running. |
| `sts pull` | hub → this machine. Run before playing. |
| `sts push` | this machine → hub. Run after playing. |
| `sts play` | pull, launch the game, wait for it to exit, push. |
| `sts backup` | hub → external disk, timestamped. Hub host only. |

### Flags

| Flag | Effect |
|---|---|
| `--dry-run` | print the real rsync plan for **both** directions, touch nothing |
| `--verbose` | mirror the log to stderr |
| `--force=local` | resolve a conflict by keeping this machine's saves |
| `--force=hub` | resolve a conflict by keeping the hub's saves |
| `--offline-ok` | let `play` run on the local save when the hub is unreachable |

## Everyday use

```bash
sts play            # the whole loop: pull, play, push
```

Or by hand:

```bash
sts status          # always safe
sts pull            # before playing
# ... play ...
sts push            # after playing
```

The first time, the hub is empty and must be seeded deliberately from
whichever machine holds the real saves:

```bash
sts push --force=local
```

On the *other* machine, the first `sts pull` will report a conflict,
because that machine already has a save directory of its own (the game
creates `core.db` and the templates on first launch, even with no
campaigns). That is correct behaviour, not a bug. Resolve it once:

```bash
sts pull --force=hub
```

## Exit codes

| Code | Meaning |
|---|---|
| 0 | success |
| 2 | usage error |
| 10 | config file missing or unreadable |
| 11 | config malformed: unparseable line or unknown key |
| 12 | required config keys missing or empty (all listed at once) |
| 13 | `LOCAL_SAVE_PATH` missing/not a directory, or a run was interrupted mid-swap |
| 14 | hub path does not exist on the hub host |
| 15 | running as root (refused) |
| 16 | bash older than 3.2 (refused) |
| 17 | `rsync`, `ssh` or `python3` not on `PATH` |
| 20 | tailscale binary not found |
| 21 | `tailscaled` not running |
| 22 | node logged out or Stopped, still down after one `tailscale up` |
| 23 | tailscale needs interactive login or reauth |
| 24 | hub host not present in the tailnet at all |
| 25 | hub host present but offline |
| 26 | hub online but `tailscale ping` failed |
| 30 | non-interactive ssh failed |
| 31 | ssh host key unknown or changed |
| 32 | hub user cannot read or write the hub directory |
| 33 | rsync exited non-zero |
| 34 | out of disk space |
| 40 | the game is running on this machine |
| 41 | the game never started |
| 50 | hub lock held by another machine |
| 51 | hub lock could not be created |
| 52 | another `sts` already running on this machine |
| 60 | both sides changed since the last sync |
| 61 | first run with saves on both sides, or this machine is empty and pushing would wipe the hub |
| 62 | hub is empty; seeding needs `push --force=local`, or the hub is empty and pulling would wipe this machine |
| 63 | snapshot failed or was incomplete, so nothing was overwritten |
| 70 | backup volume not mounted |
| 71 | `backup` run on a machine that is not the hub host |

## Troubleshooting

| # | Symptom | Code | What to do |
|---|---|---|---|
| 1 | `no config at ~/.config/star-traders-sync/config` | 10 | Run `./install.sh`, then edit the config. |
| 2 | `unknown key 'FOO'` or `line N is not KEY=value` | 11 | Compare against `config.example`. The file is parsed, never sourced, so shell syntax is not valid here. |
| 3 | `required config keys are missing or empty` | 12 | Every missing key is listed at once. Fill them all in. |
| 4 | `LOCAL_SAVE_PATH does not exist` | 13 | Launch the game once so it creates the directory, then re-run. |
| 5 | `hub path does not exist on <host>` | 14 | `mkdir -p` it on the hub, or seed it with `sts push --force=local`. |
| 6 | `~/bin is not on your PATH` at install | — | Warning only. Add `export PATH="$HOME/bin:$PATH"` to `~/.zshrc`. |
| 7 | `refusing to run as root` | 15 | Run as your normal user. Saves belong to you; root would leave files you cannot rewrite. |
| 8 | `bash 3.2 or newer required` | 16 | You are on something ancient. macOS ships 3.2.57, which is fine. |
| 9 | `required tools not on PATH: rsync ssh` | 17 | Install them. macOS ships both; check a mangled `PATH`. |
| 10 | `tailscale not found` | 20 | Install the Tailscale app, or `brew install tailscale`. Both the App Store path and `PATH` are checked. |
| 11 | `tailscaled is not running` | 21 | Start the Tailscale app, or `sudo tailscaled install-system-daemon`. |
| 12 | `still <state> after one tailscale up` | 22 | The real `tailscale up` output is printed. Fix what it says. One attempt is made, never a retry loop. |
| 13 | `Tailscale needs an interactive login` | 23 | The login URL is printed. Open it, then re-run. The tool never hangs waiting. |
| 14 | `hub host '<name>' is not in this tailnet at all` | 24 | `HUB_HOST` is wrong, or that machine never joined. Compare with `tailscale status`. Use the tailnet node name, not `foo.local`. |
| 15 | `hub host is offline` | 25 | Wake it. Or `sts play --offline-ok` to play on the local save — nothing syncs, and it warns loudly. |
| 16 | `tailscale ping failed` | 26 | The peer claims to be online but is unreachable. Check the hub's network. |
| 17 | `MagicDNS did not resolve, using tailnet IP` | 0 | Not an error. Expected when `tailscaled` came from Homebrew, which does not install a system resolver. The IP from `tailscale status --json` is used and logged. |
| 18 | `could not ssh to the hub non-interactively` | 30 | The exact command to reproduce by hand is printed. If it prompts for a password, key auth is not set up — see **One-time SSH setup**. |
| 19 | `host key is not trusted yet` | 31 | Never auto-accepted. Verify out of band with the two commands printed, then add it to `known_hosts`. |
| 20 | `host key has CHANGED` | 31 | Either the hub was reinstalled or something is wrong. Verify on the hub itself before running the `ssh-keygen -R` it suggests. |
| 21 | `hub user cannot READ/WRITE <path>` | 32 | Fix ownership and mode on the hub. |
| 22 | `rsync failed with its own exit code N` | 33 | rsync's real code and stderr are printed, never swallowed. The target was not modified — transfers stage into a temp directory. |
| 23 | Connection dropped mid-transfer | 33 | The target is untouched. rsync ran into `.sts-incoming-<pid>` on the receiving side and is only moved into place on exit 0. Just re-run. |
| 24 | `out of disk space during transfer` | 34 | `df -h` commands for both sides are printed. |
| 25 | `StarTradersFrontiers is running` | 40 | Quit the game. It holds `core.db` open read-write; any copy taken now would be torn. |
| 26 | `the game never started` | 41 | Nothing is pushed — an unchanged save is not worth recording. Check `STEAM_APPID` and that Steam is installed. |
| 27 | Game crashed or was force quit during `sts play` | 0 | The save is still pushed. The log says which case it was, detected from a crash report in `~/Library/Logs/DiagnosticReports` newer than the launch. |
| 28 | `the hub is locked by another machine` | 50 | Who holds it and since when are printed. A lock from another host is **never** cleared automatically, at any age. |
| 29 | `locked by this machine from an earlier run` | 50 | Cleared automatically once older than `LOCK_TTL_SECONDS` (default 3600), and that clearing is logged at WARN. |
| 30 | `could not create the hub lock` | 51 | The hub directory is not writable, or is read-only. |
| 31 | `another star-traders-sync is already running` | 52 | Local lock via `shlock`. Wait for the other run. |
| 32 | State file missing or corrupt | — | Treated as a first run, never as "no changes". That means the next sync will ask you to resolve a conflict rather than guess. |
| 33 | `first run on this machine, and BOTH sides already have saves` | 61 | A conflict, not a fresh start. Both sides are described with file counts and timestamps. Pick with `--force=local` or `--force=hub`. |
| 34 | `both sides changed since the last sync` | 60 | Nothing is merged and nothing is auto-picked. Read the two summaries, then re-run with `--force=`. |
| 35 | `the hub is empty` | 62 | Seeding is a one-way decision and is never silent. `sts push --force=local`. |
| 36 | `first seed: this machine has no saves` | 0 | A pull is allowed, and logged as a first seed rather than an ordinary pull. |
| 37 | `the hub's clock is Ns away from this machine's` | 0 | Warning. Timestamps shown become unreliable; the decision is made on content fingerprints, which do not care about clocks. |
| 38 | `<volume> exists but is NOT a mount point` | 70 | The disk is unplugged, and `/Volumes/T9` is a plain empty directory on the internal disk. Detected by comparing device ids, not by `-d`. Nothing is written. |
| 39 | `backup only runs on the hub host` | 71 | Run it on the mini. |
| 40 | `the hub has 0 files and this machine has N` | 62 | Syncing *from* an empty side is refused unconditionally — `--force=hub` will not override it. An empty hub means something went wrong there, not that your saves should be deleted. |
| 41 | `this machine has 0 files and the hub has N` | 61 | The symmetric case. Refused the same way. |
| 42 | `snapshot ... is INCOMPLETE - N files in the source, only M copied` | 63 | Some files could not be read, so the snapshot cannot protect them. Nothing was overwritten. Fix permissions on the source directory. |
| 43 | `a previous run was interrupted while swapping directories` | 13 | Your saves are intact under `<path>.sts-old-<pid>`. The exact `mv` to restore them is printed. Nothing else runs until you do. |
| 44 | `HUB_PATH contains a character that cannot survive...` | 11 | Paths are passed to a remote shell and openrsync has no `--protect-args`. Use only letters, digits and `. _ / @ + -` — no spaces or quotes. |
| 45 | `HUB_PATH and LOCAL_SAVE_PATH are the same directory` | 11 | The hub must be separate from the game's save directory on every machine, including the hub itself. Nesting either inside the other is also refused. |

## Data safety

**Every overwrite snapshots the target first.** Before any transfer, the
receiving side is copied to:

```
<target>/../star-traders-sync-snapshots/<ISO timestamp>/
```

pruned to the last `SNAPSHOT_KEEP` (default 10). `rsync --delete` is only
ever reached *after* that snapshot exists.

To recover, just copy a snapshot back:

```bash
ls ~/Library/star-traders-sync-snapshots/
cp -Rp ~/Library/star-traders-sync-snapshots/<stamp>/ ~/Library/StarTradersFrontiers/
```

**Transfers are staged.** rsync writes into `.sts-incoming-<pid>` next to
the target and is moved into place with two renames only after it exits 0.
A dropped connection leaves the target byte-identical to how it started.

**Fingerprints decide, not timestamps.** On these two machines `core.db`
is 12288 bytes on *both* while holding completely different saves. Size
and mtime comparison would be actively misleading, so every decision is
made on a SHA-256 manifest of the directory. Timestamps are shown to you,
but they are not what the tool reasons about.

**An empty side never propagates.** Syncing *from* a directory with zero
files is refused unconditionally, and no `--force` overrides it. An empty
hub means something went wrong on the hub, never that your saves should be
deleted. The same guard applies in both directions.

**Snapshots are verified, not assumed.** The file count of every snapshot
is compared against its source, and a short count aborts the run before
anything is overwritten. This matters because `find | cpio` will happily
exit 0 after copying only part of a tree when a subdirectory is unreadable.

**An interrupted swap is recoverable.** The moment between the two renames
is the only time the save directory does not exist. `SIGINT`/`SIGTERM` are
trapped, the cleanup sweep is suppressed while a swap is in flight, and the
next run detects the orphaned `<path>.sts-old-<pid>` and refuses to do
anything until you restore it — so an empty save directory can never be
created on top of a pending recovery.

**Running the wrong command at the wrong time may refuse to work, but will
not lose a save.**

## Logging

```
~/Library/Logs/star-traders-sync/star-traders-sync.log
```

ISO timestamp, level, step, and result, rotated at `LOG_MAX_BYTES`
(default 5 MB) keeping `LOG_KEEP` (default 3) files. stdout stays short;
detail goes to the log. `--verbose` mirrors the log to stderr.

## Notes on rsync

macOS 15 ships **openrsync** (`protocol version 29`, "rsync 2.6.9
compatible"), not GNU rsync. Everything used here was tested against it:
`-a`, `-n`, `-i`, `--delete`, `--link-dest`, `--exclude`, `-e`. Dry-run
itemizing is accurate.

`-E` is deliberately **not** used. It means `--extended-attributes` in
openrsync but `--executability` in GNU rsync, so it would silently change
meaning if either machine ever got a Homebrew rsync. The only extended
attribute these files carry is `com.apple.provenance`, which is local
macOS bookkeeping that should not cross machines anyway.
