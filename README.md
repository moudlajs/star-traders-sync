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

---

## More

- **[docs/install.md](docs/install.md)** — install, ssh setup, what must match, seeding the hub
- **[docs/backups.md](docs/backups.md)** — scheduled backups to an external disk, and restoring
- **[docs/troubleshooting.md](docs/troubleshooting.md)** — what `doctor` checks, every exit code, and a row per failure
- **[docs/design.md](docs/design.md)** — architecture, what lives in the save directory, why conflicts refuse, the openrsync and path notes
- **[CONTRIBUTING.md](CONTRIBUTING.md)** — conventions, testing, how to submit a change
