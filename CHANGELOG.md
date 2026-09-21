# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Entries describe what changed for someone running the tool. A version bump, a
CI change or a docs-only change does not get an entry unless it changed
something observable. A `Security` entry always says what the exposure was,
because that is the one category where a reader has to decide whether to
upgrade now rather than later.

## [Unreleased]

### Added

- This changelog, backfilled from the git history for every release so far.
  The release workflow now refuses to publish a tag that has no section here
  ([#49])

### Changed

- The README leads with the everyday workflow; reference material moved into
  `docs/`
- Issues follow a fixed structure - Problem, Proposal, Acceptance criteria -
  with templates that enforce it and blank issues disabled ([#50])
- `CLAUDE.md` correctly states the regression suite size (104 cases, not 44)

## [1.2.0] - 2026-09-20

### Added

- `sts doctor`: runs every prerequisite check, aborts on none, and prints one
  report saying exactly how to fix each problem. A check gated behind a failed
  one reports `skipped` rather than failing, so a broken host key does not
  present itself as a key-auth problem. Read-only.
- `sts doctor --fix`: applies only repairs that are safe, reversible and
  idempotent - creating directories, generating an ssh key, adding `~/bin` to
  `~/.zshrc` with a backup, clearing a stale local lock whose owner is gone.
  It never accepts an ssh host key, enables Remote Login, grants Full Disk
  Access or logs in to Tailscale; those it explains, and it reports which
  later checks it skipped as a result.

Setting a machine up was previously a ten-step procedure, half of it prose to
be followed by hand in the right order, and since every other command aborts
on its first problem it was also a loop: fix one thing, re-run, find the next.

## [1.1.0] - 2026-09-20

### Added

- `sts backup` as a scheduled job: `launchd/install-backup-job.sh` generates
  the plist from your config rather than shipping one, refuses to install
  anywhere but the hub host, and runs the job once immediately after loading
  so a launchd-only failure surfaces then rather than at 04:00 three weeks
  later.
- An ad-hoc-signed launcher binary for that job, so the Full Disk Access grant
  needed to write to an external disk can land on one executable instead of on
  `/bin/bash` and therefore every shell script on the machine.
- `BACKUP_MOUNT_WAIT`, so a backup firing just after wake waits for the disk
  instead of losing the day's run.

### Fixed

- The hub lock identified this machine by `hostname -s`, which on macOS can
  change with DHCP. If it changed, this machine's own lock was thereafter seen
  as another machine's - and a lock from another machine is never cleared at
  any age, so recovery meant deleting it by hand on the hub from the other
  machine. The lock now carries a stable id kept in the state directory. The
  hostname is still recorded and still what messages display. A lock written
  by an older version has no id line and falls back to the hostname
  comparison, so upgrading mid-lock still behaves. ([#7])

### Security

- **Arbitrary code execution on both machines via a config value.** Every
  command sent to the hub was built by interpolating config values into shell
  text, which made those values executable - including at the sites running
  `rm -rf` and `mv` on the hub. A path containing a single quote is ordinary
  on macOS and was enough to trigger it. All seventeen sites now pass values
  as positional parameters, with the remote script fed to `bash -s` over
  stdin so it never reaches the remote shell's command line parser.
  Upgrade from 1.0.0. ([#27])

## [1.0.0] - 2026-09-20

First release: the tool, and the guarantees it is built around.

### Added

- Sync of Star Traders: Frontiers saves between two Macs over Tailscale,
  through a hub directory that is the single source of truth. One script,
  identical on both machines; all differences live in the config.
- `sts pull`, `sts push`, `sts status`, `sts play` (pull, launch, wait for you
  to quit, push back) and `sts backup`.
- **Conflict refusal.** The save files are encrypted blobs that cannot be
  merged, only moved whole, so when both sides have changed the tool stops,
  describes both sides with file counts and timestamps, and makes you choose
  with `--force=local` or `--force=hub`. It never picks for you.
- **Decisions made on SHA-256 manifests, not timestamps or sizes.** `core.db`
  is the same 12288 bytes on both machines while holding entirely different
  saves, so size and mtime comparison would be actively misleading.
- **A snapshot before every overwrite**, pruned to `SNAPSHOT_KEEP`, with the
  snapshot's file count asserted against its source - `find | cpio` will exit
  0 having copied only part of a tree. `rsync --delete` is only reachable
  after that assertion passes.
- **Staged transfers.** rsync writes into `.sts-incoming-<pid>` beside the
  target and is moved into place with two renames only on exit 0, so a dropped
  connection leaves the target byte-identical. An interrupt mid-swap is
  trapped, and the next run refuses to do anything until the orphaned
  `.sts-old-<pid>` is restored, so an empty save directory can never be
  created on top of a pending recovery.
- **An empty side never propagates.** Syncing from a directory with zero files
  is refused unconditionally and no `--force` overrides it, in both
  directions.
- Hub and local locking, so two machines and a scheduled backup cannot
  transfer at once. The hub lock lives beside `HUB_PATH`, not inside it,
  because the swap replaces the whole directory.
- A distinct exit code per failure state, each with a row in the
  troubleshooting reference, and a rotating log.
- `install.sh`, an annotated `config.example`, the regression suite, macOS CI,
  and the tag-driven release pipeline.

Three rounds of adversarial review before this tag found real data-loss
defects in code that looked careful; the most severe was that excluded files
were deleted by the staged swap. `SYNC_EXCLUDE` marks a file as machine-local
and never transferred, but the swap replaces the whole directory, so a file
that was never transferred was simply absent from the replacement - taking
`data.db` and `steam_autocloud.vdf` with it. Excluded files are now carried
from the live directory into the staging directory before the swap. Every one
of those findings has a case in `tests/regression.sh`.

[Unreleased]: https://github.com/moudlajs/star-traders-sync/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/moudlajs/star-traders-sync/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/moudlajs/star-traders-sync/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/moudlajs/star-traders-sync/releases/tag/v1.0.0
[#7]: https://github.com/moudlajs/star-traders-sync/issues/7
[#27]: https://github.com/moudlajs/star-traders-sync/issues/27
[#49]: https://github.com/moudlajs/star-traders-sync/issues/49
[#50]: https://github.com/moudlajs/star-traders-sync/issues/50
