# Backups and restoring

Two things keep old copies of your saves:

- **Snapshots**, automatic, on every machine. Every overwrite snapshots
  the target first, into `star-traders-sync-snapshots/` next to it. Kept:
  [`SNAPSHOT_KEEP`](configuration.md#all-keys).
- **Backups**, on the hub host only, to an external disk: `sts backup`,
  run by hand or every night by the job below.

## Installing and removing the nightly job

On the hub host:

```bash
./launchd/install-backup-job.sh              # install, load, and test-run it
./launchd/install-backup-job.sh --uninstall
```

The installer runs the job once after loading, so you find out immediately
whether it works under launchd rather than discovering it failed at 04:00
three weeks later.

## Why the job is generated, and when to re-run the installer

The plist is generated from your config rather than shipped, because it
needs absolute paths. Re-run the installer after changing `HUB_PATH`,
`BACKUP_VOLUME` or `BACKUP_DEST`.

## Why the job pins its environment

It pins `PATH`, `HOME`, `XDG_CONFIG_HOME` and `XDG_STATE_HOME`, because
launchd does not read your shell profile. The `XDG_*` ones matter more than
they look: if the job and your terminal disagree about them, they compute
different lock paths and the mutual exclusion between a scheduled backup and
an interactive run silently disappears.

## Full Disk Access: macOS will block writes to an external disk

Read this before granting anything.

A launchd job is denied access to removable volumes **silently, with no
prompt**. The symptom is:

```
mkdir: /Volumes/YourDisk/...: Operation not permitted
```

on a volume that is mounted and writable, from a job whose identical
command works fine when you run it in a terminal.

The installer builds a small launcher binary when `clang` is available, so
that the grant can go to that one program. Without it, the job runs the
script through `/bin/bash`, and the grant has to go to `/bin/bash`:
**System Settings > Privacy & Security > Full Disk Access**, then add the
program (press ⌘⇧G in the file picker to type the path). The installer
prints which one it set up.

Be aware of what a `/bin/bash` grant means: every bash script run on the
machine, not just this one. If that is too broad, the alternatives are to
keep `BACKUP_DEST` on the internal disk, or to run `sts backup`
interactively rather than on a schedule.

## A Mac that is off at 04:00

A powered-off Mac misses its slot entirely — launchd only catches up from
sleep, not from being off:

```bash
sudo pmset repeat wakeorpoweron MTWRFSU 03:55:00
```

## Restoring

Quit the game first, and make sure no `sts` is running on **either**
machine. Every restore below moves the current directory aside instead of
deleting it, so a restore is itself undoable. The aside copy is named with
the current time, so restoring twice never moves one into the other.

### A save on one machine, from a snapshot

Snapshots of this machine's saves are in
`~/Library/star-traders-sync-snapshots/`, one directory per overwrite,
named by UTC time. `sts restore` lists them and puts one back:

```bash
sts restore                          # list them, newest first
sts restore 2026-10-06T12:00:00Z     # put that one back
```

A restore works like a pull. It stages the copy, snapshots the saves that
are here now (so `sts restore` with that new name undoes it), then swaps.
It never prunes, so the copy you restored from is still there afterwards.
It refuses while the game is running (40), and refuses a name that is
not one of the listed copies (65). It touches nothing on the hub.

Afterwards this machine usually differs from the hub. `sts status` says
what the next sync will do: usually `sts push` sends the restored saves,
and the hub's are snapshotted there first. If the hub also changed since
this machine last synced, push reports a conflict; `sts push --force=local`
keeps the restored save.

### The hub, from a snapshot or a backup

On the hub host. Hub snapshots are in `star-traders-sync-snapshots/` next
to `HUB_PATH`. Backups are in `BACKUP_DEST`; use only a backup that
contains a `.sts-complete` file, because one without it was interrupted.

```bash
mv <HUB_PATH> <HUB_PATH>.before-restore-$(date +%s)
cp -Rp <BACKUP_DEST>/<stamp> <HUB_PATH>
rm -f <HUB_PATH>/.sts-complete
```

Each machine then gets it with `sts pull`, or `sts pull --force=hub` if
that machine has changes of its own that you do not want.
