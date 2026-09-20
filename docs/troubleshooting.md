# Troubleshooting

Start with `sts doctor` — it checks every prerequisite and prints exactly
how to fix each problem, which is faster than reading a table.

This page is the reference for when you already have an exit code, or want
to know what a particular failure means before it happens.

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
| 38 | `<volume> exists but is NOT a mount point` | 70 | The disk is unplugged, and `/Volumes/Backup` is a plain empty directory on the internal disk. Detected by comparing device ids, not by `-d`. Nothing is written. |
| 39 | `backup only runs on the hub host` | 71 | Run it on the mini. |
| 40 | `the hub has 0 files and this machine has N` | 62 | Syncing *from* an empty side is refused unconditionally — `--force=hub` will not override it. An empty hub means something went wrong there, not that your saves should be deleted. |
| 41 | `this machine has 0 files and the hub has N` | 61 | The symmetric case. Refused the same way. |
| 42 | `snapshot ... is INCOMPLETE - N files in the source, only M copied` | 63 | Some files could not be read, so the snapshot cannot protect them. Nothing was overwritten. Fix permissions on the source directory. |
| 43 | `a previous run was interrupted while swapping directories` | 13 | Your saves are intact under `<path>.sts-old-<pid>`. The exact `mv` to restore them is printed. Nothing else runs until you do. |
| 44 | `HUB_PATH contains a character that cannot survive...` | 11 | Paths are passed to a remote shell and openrsync has no `--protect-args`. Use only letters, digits and `. _ / @ + -` — no spaces or quotes. |
| 45 | `HUB_PATH and LOCAL_SAVE_PATH are the same directory` | 11 | The hub must be separate from the game's save directory on every machine, including the hub itself. Nesting either inside the other is also refused. |

