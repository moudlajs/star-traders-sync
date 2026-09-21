# Design notes

Why the tool is shaped the way it is. Read this if you are changing it, or
if you want to know why it refuses things other sync tools guess at.

## Architecture

```
   MacBook  (my-macbook)                    Mac mini  (my-mac-mini)
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
              /Volumes/Backup/Backups/star-traders-sync/<ISO>/
```

The hub is a plain directory on the Mac mini. It is **not** a game save
directory, even on the mini itself. Both machines are clients of it,
including the mini, which uses a local path copy instead of ssh — every
other code path is identical.

One script, identical on both machines. All differences live in
`~/.config/star-traders-sync/config`.


## Finding your save directory

Never copy a path out of this file into the config without checking it.
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


## Data safety

**Every overwrite snapshots the target first.** Before any transfer, the
receiving side is copied to:

```
<target>/../star-traders-sync-snapshots/<ISO timestamp>/
```

pruned to the last `SNAPSHOT_KEEP`. `rsync --delete` is only
ever reached *after* that snapshot exists.

Restoring one, and restoring from a backup, is in
[backups.md](backups.md#restoring).

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

ISO timestamp, level, step, and result, rotated at `LOG_MAX_BYTES` keeping
`LOG_KEEP` files. stdout stays short;
detail goes to the log. `--verbose` mirrors the log to stderr.


## Notes on paths

Config paths are restricted to `A-Za-z0-9._/@+-` — no spaces, quotes or
shell metacharacters.

That is a limitation of **rsync**, not of this tool's own plumbing. Commands
sent to the hub pass values as positional parameters, so a path containing a
quote or a semicolon is inert. But rsync hands a remote path to the hub's
login shell itself, and openrsync has no `--protect-args`, so a space still
splits a transfer into two arguments and a metacharacter still reaches a
shell. Lifting the restriction means solving that first.

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

