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

## Install

Download **Star-Traders-Sync-Setup.dmg** from the
[latest release](https://github.com/moudlajs/star-traders-sync/releases/latest)
and open the app. It sets up Tailscale, the hub, the ssh key and the
config, then checks everything. Set up the hub Mac first, then each Mac
you play on.

The app is not notarized yet (#61): on first launch, go to **System
Settings > Privacy & Security** and click **Open Anyway**.

Prefer the command line? [docs/install.md](docs/install.md) has
`install.sh`, the ssh setup and seeding the hub.

## Every day

```bash
sts play
```

That is the whole loop: pull from the hub, launch the game, wait for you to
quit, push back. Same command on either machine. To launch the game
yourself instead, `sts pull` before playing and `sts push` after you quit.

**One rule: push before switching machines.** If you forget, nothing breaks
— the next `pull` refuses, shows you both sides with timestamps and
campaign counts, and waits for you to pick:

```bash
sts pull --force=hub      # keep what is on the hub
sts push --force=local    # keep what is on this machine
```

Every overwrite snapshots the target first, so a wrong choice is
recoverable.

## Commands

| | |
|---|---|
| `sts doctor` | check everything, say how to fix each problem. Read-only. |
| `sts status` | what is where, which side is newer, lock state. Read-only. |
| `sts pull` | hub → this machine |
| `sts push` | this machine → hub |
| `sts play` | pull, launch, wait, push |
| `sts backup` | hub → external disk, timestamped. Hub host only. [Scheduling it](docs/backups.md) |

| Flag | |
|---|---|
| `--dry-run` | print the real rsync plan for **both** directions, touch nothing |
| `--verbose` | mirror the log to stderr |
| `--force=local` | resolve a conflict by keeping this machine's saves |
| `--force=hub` | resolve a conflict by keeping the hub's saves |
| `--offline-ok` | let `play` run on the local save when the hub is unreachable |
| `--json` | with `status`: one JSON object on stdout, for scripts and the app |
| `--fix` | `doctor` only: apply the safe repairs |

Something wrong? Run `sts doctor` first. `sts --help` lists every exit code.

## Docs

- **[Install](docs/install.md)**: the setup app, the command line, ssh, seeding the hub
- **[Configuration](docs/configuration.md)**: every config key, its default, and which must match across machines
- **[Backups and restoring](docs/backups.md)**: the nightly backup job, Full Disk Access, restoring a snapshot
- **[Troubleshooting](docs/troubleshooting.md)**: what `sts doctor` checks, every exit code, a row per failure
- **[Design](docs/design.md)**: architecture, what lives in the save directory, the openrsync and path notes
- **[Contributing](CONTRIBUTING.md)**: conventions, testing, how to submit a change

## License

MIT, see [LICENSE](LICENSE).
