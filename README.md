# star-traders-sync

[![CI](https://github.com/moudlajs/star-traders-sync/actions/workflows/ci.yml/badge.svg)](https://github.com/moudlajs/star-traders-sync/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/moudlajs/star-traders-sync?sort=semver)](https://github.com/moudlajs/star-traders-sync/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platform: macOS](https://img.shields.io/badge/platform-macOS-lightgrey)
![Shell: bash 3.2](https://img.shields.io/badge/bash-3.2-4EAA25)

Sync [Star Traders: Frontiers](https://store.steampowered.com/app/335620/)
saves between two Macs over Tailscale.

The game has no working cloud save on macOS — Steam autocloud is disabled
for this title, because its cloud rules only cover Windows paths. So this
does it instead, over `rsync` and `ssh` on your tailnet. No Syncthing, no
iCloud, no third-party service, no background daemon.

**It refuses rather than guesses.** The save files are encrypted blobs that
cannot be merged, only moved whole — so when both machines have changed,
it stops, shows you both sides, and makes you choose. Running the wrong
command at the wrong time may refuse to work. It will not lose a save.

---

## Every day

```bash
sts play
```

That is the whole loop: pull from the hub, launch the game, wait for you to
quit, push back. Same command on either machine.

Prefer to launch the game yourself?

```bash
sts pull        # before playing
# ... play ...
sts push        # after you quit
```

**One rule: push before switching machines.** If you forget, nothing breaks
— the next `pull` refuses, shows you both sides with timestamps and
campaign counts, and waits for you to pick:

```bash
sts pull --force=hub      # keep what is on the hub
sts push --force=local    # keep what is on this machine
```

Every overwrite snapshots the target first, so a wrong choice is
recoverable.

## When something is not working

```bash
sts doctor
```

Checks every prerequisite, never stops at the first problem, and says
exactly how to fix each one. Read-only. `sts doctor --fix` applies the
repairs that are safe and reversible; it never accepts an SSH host key,
changes a system setting, or grants a permission.

Full failure reference: **[docs/troubleshooting.md](docs/troubleshooting.md)**

## Commands

| | |
|---|---|
| `sts doctor` | check everything, say how to fix each problem. Read-only. |
| `sts status` | what is where, which side is newer, lock state. Read-only. |
| `sts pull` | hub → this machine |
| `sts push` | this machine → hub |
| `sts play` | pull, launch, wait, push |
| `sts backup` | hub → external disk, timestamped. Hub host only. |

| Flag | |
|---|---|
| `--dry-run` | print the real rsync plan for **both** directions, touch nothing |
| `--verbose` | mirror the log to stderr |
| `--force=local` | resolve a conflict by keeping this machine's saves |
| `--force=hub` | resolve a conflict by keeping the hub's saves |
| `--offline-ok` | let `play` run on the local save when the hub is unreachable |
| `--fix` | `doctor` only: apply the safe repairs |

`sts --help` lists every exit code.

---

## Install

On each machine:

```bash
git clone <this repo> ~/Repos/star-traders-sync
cd ~/Repos/star-traders-sync
./install.sh
$EDITOR ~/.config/star-traders-sync/config
sts status
```

Then run `sts doctor` — it tells you what is still missing and exactly how
to fix it. The hub also needs a one-time key-based ssh setup, once per
client.

Full procedure, what has to match across the two machines, and seeding the
hub for the first time: **[docs/install.md](docs/install.md)**

## Scheduled backups (hub host only)

```bash
./launchd/install-backup-job.sh              # install, load, and test-run it
./launchd/install-backup-job.sh --uninstall
```

The plist is generated from your config rather than shipped, because it
needs absolute paths. Re-run the installer after changing `HUB_PATH`,
`BACKUP_VOLUME` or `BACKUP_DEST`.

It pins `PATH`, `HOME`, `XDG_CONFIG_HOME` and `XDG_STATE_HOME`, because
launchd does not read your shell profile. The `XDG_*` ones matter more than
they look: if the job and your terminal disagree about them, they compute
different lock paths and the mutual exclusion between a scheduled backup and
an interactive run silently disappears.

The installer runs the job once after loading, so you find out immediately
whether it works under launchd rather than discovering it failed at 04:00
three weeks later.

### macOS will block it from writing to an external disk

A launchd job is denied access to removable volumes **silently, with no
prompt**. The symptom is:

```
mkdir: /Volumes/YourDisk/...: Operation not permitted
```

on a volume that is mounted and writable, from a job whose identical
command works fine when you run it in a terminal.

To allow it: **System Settings > Privacy & Security > Full Disk Access**,
then add `/bin/bash` (press ⌘⇧G in the file picker to type the path).

Be aware of what that grants: every bash script run on the machine, not
just this one. If that is too broad, the alternatives are to keep
`BACKUP_DEST` on the internal disk, or to run `sts backup` interactively
rather than on a schedule.

A powered-off Mac misses its slot entirely — launchd only catches up from
sleep, not from being off:

```bash
sudo pmset repeat wakeorpoweron MTWRFSU 03:55:00
```

---

## More

- **[docs/install.md](docs/install.md)** — install, ssh setup, what must match, seeding the hub
- **[docs/troubleshooting.md](docs/troubleshooting.md)** — what `doctor` checks, every exit code, and a row per failure
- **[docs/design.md](docs/design.md)** — architecture, what lives in the save directory, why conflicts refuse, the openrsync and path notes
- **[CONTRIBUTING.md](CONTRIBUTING.md)** — conventions, testing, how to submit a change
