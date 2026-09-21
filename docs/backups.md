# Backups

A second copy of the hub on an external disk, timestamped, on the hub host
only. This is separate from snapshots: a snapshot protects you from the
*previous command*, a backup protects you from the disk.

```bash
sts backup
```

Exit 71 if you run it anywhere but the hub host, 70 if the backup volume is
not mounted.

## Running it on a schedule

```bash
./launchd/install-backup-job.sh              # install, load, and test-run it
./launchd/install-backup-job.sh --uninstall
```

The installer refuses to run anywhere but the hub host, and prints the
`launchctl` commands for inspecting and kicking the job afterwards.

**The plist is generated from your config rather than shipped**, because it
needs absolute paths and this repository is public. Re-run the installer
after changing `HUB_PATH`, `BACKUP_VOLUME` or `BACKUP_DEST`.

It pins `PATH`, `HOME`, `XDG_CONFIG_HOME` and `XDG_STATE_HOME`, because
launchd does not read your shell profile. The `XDG_*` pair matters more than
it looks: if the job and your terminal disagree about them, they compute
different lock paths, and the mutual exclusion between a scheduled backup and
an interactive run silently disappears.

**The installer runs the job once after loading**, so you find out
immediately whether it works under launchd rather than discovering it failed
at 04:00 three weeks later. Two real failures were caught exactly this way,
and neither would have shown up in a sandbox.

It also raises `BACKUP_MOUNT_WAIT` to 180 if it is lower, because a scheduled
run can fire moments after wake, before an external disk has remounted.

## macOS will block it from writing to an external disk

A launchd job is denied access to removable volumes **silently, with no
prompt**. The symptom is:

```
mkdir: /Volumes/YourDisk/...: Operation not permitted
```

on a volume that is mounted and writable, from a job whose identical command
works fine when you run it in a terminal.

To macOS privacy protection, a launchd job that runs a shell script *is*
`/bin/bash`, so granting that job access to the disk would grant it to every
shell script that ever runs on the machine. The installer avoids this: it
compiles `launchd/backup-launcher.c` into an ad-hoc-signed binary at
`~/Library/Application Support/star-traders-sync/sts-backup-launcher` and
runs the job as that instead. TCC attributes a child process to whatever
spawned it, so the permission is held by that one binary rather than by the
system shell.

**Grant access to the launcher, not to `/bin/bash`.** The installer prints
the exact path to paste — take it from there rather than from this page,
because it falls back to `/bin/bash` when `clang` is unavailable and the
target genuinely differs in that case.

```
System Settings > Privacy & Security > Full Disk Access
press Cmd-Shift-G in the file picker and paste the path the installer printed
```

Then reload the job, or launchd keeps the old decision:

```bash
launchctl bootout   gui/$(id -u)/com.github.moudlajs.star-traders-sync.backup
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.github.moudlajs.star-traders-sync.backup.plist
launchctl kickstart -k gui/$(id -u)/com.github.moudlajs.star-traders-sync.backup
```

If a Full Disk Access grant is too broad whatever it lands on, the
alternatives are to keep `BACKUP_DEST` on the internal disk, or to run
`sts backup` interactively rather than on a schedule.

## A powered-off Mac misses its slot

launchd catches up from sleep, not from being powered off:

```bash
sudo pmset repeat wakeorpoweron MTWRFSU 03:55:00
```

## Restoring

**From a snapshot** — what the tool took automatically before the last
overwrite, kept on the same machine. This is what you want after a wrong
`--force`:

```bash
ls ~/Library/star-traders-sync-snapshots/
cp -Rp ~/Library/star-traders-sync-snapshots/<stamp>/ ~/Library/StarTradersFrontiers/
```

Snapshots are pruned to the last `SNAPSHOT_KEEP`. Why they exist
and what is asserted about them is in [design.md](design.md#data-safety).

**From a backup** — a copy of the hub on the external disk, kept for
`BACKUP_KEEP` runs. Copy the timestamped directory you want back
over the hub, then pull it to each machine:

```bash
ls /Volumes/YourDisk/Backups/star-traders-sync/
# on the hub host, with nothing else running:
cp -Rp /Volumes/YourDisk/Backups/star-traders-sync/<stamp>/ <HUB_PATH>/
# then on each machine:
sts pull --force=hub
```

## Known limitation

On a volume without hard-link support — exFAT, notably — `--link-dest` does
nothing and every backup is a full copy rather than an incremental one. It
still works; it just costs `BACKUP_KEEP` times the size of your saves. See
[#41](https://github.com/moudlajs/star-traders-sync/issues/41).
