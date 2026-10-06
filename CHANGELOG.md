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

- **Disconnect this Mac…** in the gear menu. It removes the app's `sts`
  and `star-traders-sync` links from `~/bin` and moves the config to a
  dated backup. Your saves, their safety copies and the Hub are not
  touched, and setup connects it again. "Run setup again…" is now
  **Change hub, account or backup disk…** and opens the wizard with the
  current settings filled in ([#75])
- `sts restore` lists this Mac's safety copies (the snapshots taken before
  every overwrite), and `sts restore NAME` puts one back. The saves it
  replaces become a new safety copy first, so a restore can be undone,
  and nothing is pruned. `--json` lists them for the app ([#90])
- The app's gear menu has **Restore previous saves…**: this Mac's safety
  copies with their date and campaigns. Restoring one runs `sts restore`,
  so it is undoable the same way ([#90])
- A menu bar icon showing how things stand (up to date, syncing, saves to
  sync, needs you). Its popover has Play, both sides, the automatic-sync
  and Open-at-login switches, Health check and Quit. With the icon on,
  closing the window no longer stops automatic sync. It can be turned off
  in the gear menu ([#91])

### Fixed

- The updater waits up to about 30 seconds, not 7, for a busy disk image
  before giving up ([#124])

## [1.5.6] - 2026-10-06

### Security

- The app now installs an update only if the dmg carries a valid Ed25519
  signature from this project's release key, which is built into the app.
  Before this, the only checks were GitHub's SHA-256 digest and an ad-hoc
  codesign, both of which someone controlling the GitHub account or the
  release download could have produced. Releases are signed in CI ([#108])

### Fixed

- The hub lock is also released when a run on a client Mac (not the Hub
  host) is cut short by a closed pipe. 1.5.5 fixed this on the Hub host
  only ([#129])
- The app's updater retries a disk image that macOS reports as busy
  ("Resource temporarily unavailable") a few times before giving up. It
  used to fail the update at once with a misleading "could not be opened"
  ([#124])
- Two runs clearing the same stale hub lock at the same moment can no
  longer delete the fresh lock one of them just took. Only one run clears
  at a time, and it checks again that the lock is still the stale one
  before removing it ([#132])
- A push from a client no longer deletes a `SYNC_EXCLUDE` file on the hub
  that it could not carry across the swap. It refuses with 63 instead, as
  a push from the Hub host already did. `SYNC_EXCLUDE` patterns with a
  glob now match on the hub side too ([#128])

## [1.5.5] - 2026-10-06

### Fixed

- A run cut short by a closed pipe (`sts play | head -1`) or a closed
  terminal no longer leaves the hub lock behind. The leftover lock then
  blocked the other Mac, and this one too, with "locked by this machine
  from an earlier run" until `LOCK_TTL_SECONDS` passed ([#129])
- A run interrupted in the instant between moving a directory aside and
  moving the new copy in is now recognised as mid-swap, so its staged copy
  is kept for recovery instead of swept away

## [1.5.4] - 2026-10-06

### Fixed

- `sts play` no longer starts the game when this Mac's save folder was
  emptied after a sync. It used to read that as "this machine is ahead of
  the hub", launch with no saves, and could then send a new game over the
  Hub's saves. It now refuses (61) and says how to restore them:
  `sts pull --force=hub` ([#126])

### Added

- This changelog, backfilled from the git history for every release. The
  release workflow now refuses to publish a tag that has no section here
  ([#49])

### Changed

- A fresh install's config now defaults `HUB_HOST` to `your-hub-tailnet-name`
  and the backup volume to `/Volumes/YourDisk`, instead of names from one
  particular setup. `sts doctor` reports both as placeholders still to fill
  in ([#47])

## [1.5.3] - 2026-10-06

### Changed

- Automatic sync is one switch in the app's toolbar, labelled Auto sync,
  always in view; the line under Play and the settings-menu item are gone
  ([#120])
- The checks the app starts itself, when its window comes forward and
  every minute, no longer turn the refresh button into a spinner; only a
  check you ask for does ([#120])

## [1.5.2] - 2026-10-05

### Fixed

- Automatic sync could be switched off by accident from the settings menu,
  where it was the first item, with nothing on screen saying so. The window
  now says when it is off, and the switch moved down the menu ([#118])
- The update download shows a spinner instead of a percentage that raced
  past ([#118])

## [1.5.1] - 2026-10-05

The first version delivered by the app's own updater.

### Fixed

- The This Mac | Hub strip cut off the last-played time; it is two lines
  now ([#114])
- The tick replayed its animation whenever the window came forward; it
  only celebrates right after a sync ([#114])
- The health check slid each section in as it finished, overlapping the
  next row. Every section is drawn from the start and changes in place;
  sections that never ran say "not checked" ([#114])

## [1.5.0] - 2026-10-05

The last version you install by hand.

### Added

- **The app updates itself**, Tailscale-style: Update, a progress ring,
  Restart to update. The download must match GitHub's SHA-256 digest and
  come from this repository's own releases over HTTPS; the app inside must
  be ours, exactly the advertised version, and pass a strict signature
  check; it is swapped in atomically, never during a sync. A self-downloaded
  update carries no quarantine flag, so macOS does not ask to Open Anyway
  again ([#107])

### Changed

- **The final window design.** Every state uses the same slots: the face,
  a headline, one status line, the action slot and the This Mac | Hub
  strip, so nothing jumps. Running work is a status pill (Syncing…, In
  game · 12:04 with a live clock), and a sync ends with a green Synced
  moment before Play returns ([#110])
- Conflicts recommend the side played more recently as "Keep the newer
  saves", but only when the last-played times differ by at least 30
  minutes; otherwise both choices are neutral and named by side ([#110],
  [#89])
- "Hub" is written with a capital H throughout the app ([#110])

## [1.4.0] - 2026-10-05

The setup app becomes **Star Traders Sync**, the app you keep.

### Added

- A main window: what the next sync would do, both sides' campaigns and
  last-played times, and when this Mac last synced ([#78])
- **Play**, and a button for every other state, offered only where the
  script accepts that command: Send to the Hub, Get the Hub's saves now,
  and for a conflict, Keep the Hub's saves or Keep this Mac's saves, each
  confirmed with both sides named ([#83])
- **Automatic sync**: when only the Hub changed, or only this Mac, the app
  fetches or sends by itself; never with `--force`, never while the game
  runs, and never on a conflict ([#95])
- `sts status --json`, and its `decision`: what pull and push would
  actually do, from the same function they use ([#77], [#80])
- `pull` and `push` accept `--expect-decision`, checked under the Hub lock;
  a choice confirmed against a situation that has since changed is refused
  (exit 64) and nothing is touched ([#86])
- An app icon ([#84])

### Changed

- `sts play` notices a closed game in about 9 seconds instead of 20, and
  says "game closed" straight away ([#93])
- When only this Mac changed, `sts play` plays and sends the saves
  afterwards instead of refusing ([#100])
- A compact main window with the health check inside it ([#94])

### Fixed

- A Tailscale answer that was not JSON, such as a version warning or a
  disconnected app's sentence, crashed every command with a Python
  traceback; it now refuses with exit 22 and says Tailscale is not
  connected ([#98])
- Bringing Tailscale up on a playing Mac corrupted the status it read
  next, with the same traceback ([#104])
- The app could keep running an old copy of the script after an upgrade;
  it now refreshes it before every check ([#102])

## [1.3.0] - 2026-09-27

### Added

- **A setup app for people who do not use the terminal**: it checks
  Tailscale, picks the Hub from your Tailscale devices, sets up the ssh key
  (confirming the Hub's fingerprint, using the Hub password once and never
  storing it), writes the config and runs `sts doctor --fix` ([#63])

### Changed

- The README is a landing page; installation, backups, configuration and
  troubleshooting moved into `docs/` ([#66])
- Setup shows its install steps one by one ([#69])

### Fixed

- The setup app's Tailscale step could not read the Tailscale app's
  answer; it now tolerates it and logs what it got ([#65])

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

[Unreleased]: https://github.com/moudlajs/star-traders-sync/compare/v1.5.6...HEAD
[1.5.6]: https://github.com/moudlajs/star-traders-sync/compare/v1.5.5...v1.5.6
[1.5.5]: https://github.com/moudlajs/star-traders-sync/compare/v1.5.4...v1.5.5
[1.5.4]: https://github.com/moudlajs/star-traders-sync/compare/v1.5.3...v1.5.4
[1.5.3]: https://github.com/moudlajs/star-traders-sync/compare/v1.5.2...v1.5.3
[1.5.2]: https://github.com/moudlajs/star-traders-sync/compare/v1.5.1...v1.5.2
[1.5.1]: https://github.com/moudlajs/star-traders-sync/compare/v1.5.0...v1.5.1
[1.5.0]: https://github.com/moudlajs/star-traders-sync/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/moudlajs/star-traders-sync/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/moudlajs/star-traders-sync/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/moudlajs/star-traders-sync/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/moudlajs/star-traders-sync/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/moudlajs/star-traders-sync/releases/tag/v1.0.0
[#7]: https://github.com/moudlajs/star-traders-sync/issues/7
[#27]: https://github.com/moudlajs/star-traders-sync/issues/27
[#47]: https://github.com/moudlajs/star-traders-sync/issues/47
[#49]: https://github.com/moudlajs/star-traders-sync/issues/49
[#63]: https://github.com/moudlajs/star-traders-sync/issues/63
[#65]: https://github.com/moudlajs/star-traders-sync/issues/65
[#66]: https://github.com/moudlajs/star-traders-sync/issues/66
[#69]: https://github.com/moudlajs/star-traders-sync/issues/69
[#77]: https://github.com/moudlajs/star-traders-sync/issues/77
[#78]: https://github.com/moudlajs/star-traders-sync/issues/78
[#80]: https://github.com/moudlajs/star-traders-sync/issues/80
[#83]: https://github.com/moudlajs/star-traders-sync/issues/83
[#84]: https://github.com/moudlajs/star-traders-sync/issues/84
[#86]: https://github.com/moudlajs/star-traders-sync/issues/86
[#89]: https://github.com/moudlajs/star-traders-sync/issues/89
[#93]: https://github.com/moudlajs/star-traders-sync/issues/93
[#94]: https://github.com/moudlajs/star-traders-sync/issues/94
[#95]: https://github.com/moudlajs/star-traders-sync/issues/95
[#98]: https://github.com/moudlajs/star-traders-sync/issues/98
[#100]: https://github.com/moudlajs/star-traders-sync/issues/100
[#102]: https://github.com/moudlajs/star-traders-sync/issues/102
[#104]: https://github.com/moudlajs/star-traders-sync/issues/104
[#107]: https://github.com/moudlajs/star-traders-sync/issues/107
[#110]: https://github.com/moudlajs/star-traders-sync/issues/110
[#114]: https://github.com/moudlajs/star-traders-sync/issues/114
[#118]: https://github.com/moudlajs/star-traders-sync/issues/118
[#120]: https://github.com/moudlajs/star-traders-sync/issues/120
[#126]: https://github.com/moudlajs/star-traders-sync/issues/126
[#75]: https://github.com/moudlajs/star-traders-sync/issues/75
[#90]: https://github.com/moudlajs/star-traders-sync/issues/90
[#91]: https://github.com/moudlajs/star-traders-sync/issues/91
[#108]: https://github.com/moudlajs/star-traders-sync/issues/108
[#124]: https://github.com/moudlajs/star-traders-sync/issues/124
[#128]: https://github.com/moudlajs/star-traders-sync/issues/128
[#129]: https://github.com/moudlajs/star-traders-sync/issues/129
[#132]: https://github.com/moudlajs/star-traders-sync/issues/132
