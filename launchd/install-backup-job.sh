#!/bin/bash
#
# Installs the daily `sts backup` LaunchAgent on the hub host.
#
# The plist is generated from your config rather than shipped, because it
# has to carry absolute paths and this repository is public. Re-run it after
# changing HUB_PATH, BACKUP_VOLUME or BACKUP_DEST.
#
#   ./launchd/install-backup-job.sh            install and test
#   ./launchd/install-backup-job.sh --uninstall

set -euo pipefail

PROG="star-traders-sync"
LABEL="com.github.moudlajs.star-traders-sync.backup"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/$PROG/config"
LOG_DIR="$HOME/Library/Logs/$PROG"
HOUR=4
MINUTE=0

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
note() { printf '  %s\n' "$*"; }

# --------------------------------------------------------------------------
if [ "${1:-}" = "--uninstall" ]; then
    if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
        launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
        note "job unloaded"
    fi
    [ -f "$PLIST" ] && rm -f "$PLIST" && note "removed $PLIST"
    printf '\nUninstalled. Backups already on disk are untouched.\n'
    exit 0
fi

[ "$(id -u)" -ne 0 ] || fail "do not run this as root - a LaunchAgent belongs to your user"
[ -f "$CONFIG" ] || fail "no config at $CONFIG - run ./install.sh first"

# Read the handful of values we need. The config is KEY=value and is parsed,
# never sourced, exactly as the tool itself does it.
cfg() { grep -E "^$1=" "$CONFIG" | tail -1 | cut -d= -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

HUB_HOST="$(cfg HUB_HOST)"
BACKUP_VOLUME="$(cfg BACKUP_VOLUME)"
BACKUP_DEST="$(cfg BACKUP_DEST)"

[ -n "$HUB_HOST" ]      || fail "HUB_HOST is not set in $CONFIG"
[ -n "$BACKUP_VOLUME" ] || fail "BACKUP_VOLUME is not set in $CONFIG"
[ -n "$BACKUP_DEST" ]   || fail "BACKUP_DEST is not set in $CONFIG"

# `sts backup` refuses to run anywhere but the hub, so installing the job
# elsewhere would only schedule a nightly exit 71.
THIS_HOST="$(hostname -s | tr '[:upper:]' '[:lower:]')"
THIS_LOCAL="$(scutil --get LocalHostName 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
WANT="$(printf '%s' "$HUB_HOST" | tr '[:upper:]' '[:lower:]')"
if [ "$WANT" != "$THIS_HOST" ] && [ "$WANT" != "$THIS_LOCAL" ]; then
    fail "this is $THIS_HOST, but HUB_HOST is $HUB_HOST - the backup job only belongs on the hub"
fi

STS="$HOME/bin/$PROG"
[ -x "$STS" ] || fail "$STS not found or not executable - run ./install.sh first"

mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIR"

# BACKUP_MOUNT_WAIT matters for a scheduled run: the job can fire moments
# after wake, before an external disk has remounted.
if grep -qE '^BACKUP_MOUNT_WAIT=' "$CONFIG"; then
    current="$(cfg BACKUP_MOUNT_WAIT)"
    if [ "${current:-0}" -lt 60 ]; then
        note "BACKUP_MOUNT_WAIT is ${current:-0}; a scheduled run should wait for the disk"
        note "setting it to 180 in $CONFIG"
        sed -i '' 's/^BACKUP_MOUNT_WAIT=.*/BACKUP_MOUNT_WAIT=180/' "$CONFIG"
    fi
else
    printf 'BACKUP_MOUNT_WAIT=180\n' >> "$CONFIG"
    note "added BACKUP_MOUNT_WAIT=180 to $CONFIG"
fi

# --------------------------------------------------------------------------
# launchd does not read your shell profile, so everything the script resolves
# from the environment is pinned here. In particular XDG_* must match what an
# interactive shell uses, or the job and your terminal would compute
# different lock paths and the mutual exclusion would silently disappear.
cat > "$PLIST" <<PEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>

  <key>ProgramArguments</key>
  <array>
    <string>$STS</string>
    <string>backup</string>
  </array>

  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>HOME</key>
    <string>$HOME</string>
    <key>XDG_CONFIG_HOME</key>
    <string>${XDG_CONFIG_HOME:-$HOME/.config}</string>
    <key>XDG_STATE_HOME</key>
    <string>${XDG_STATE_HOME:-$HOME/.local/state}</string>
  </dict>

  <key>WorkingDirectory</key>
  <string>$HOME</string>

  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key><integer>$HOUR</integer>
    <key>Minute</key><integer>$MINUTE</integer>
  </dict>

  <key>RunAtLoad</key><false/>

  <key>StandardOutPath</key>
  <string>$LOG_DIR/backup.launchd.out</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/backup.launchd.err</string>

  <key>ProcessType</key><string>Background</string>
  <key>LowPriorityIO</key><true/>
  <key>Nice</key><integer>5</integer>

  <!-- Deliberately no KeepAlive: with the disk unplugged, backup exits 70,
       and KeepAlive would spin on that forever. -->
</dict>
</plist>
PEOF
note "wrote $PLIST"

plutil -lint "$PLIST" >/dev/null || fail "generated plist is not valid"
note "plist validates"

launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
note "job loaded, scheduled daily at $(printf '%02d:%02d' "$HOUR" "$MINUTE")"

printf '\nRunning it once now to prove it works under launchd, not just in your shell:\n\n'
launchctl kickstart -k "gui/$(id -u)/$LABEL"
sleep 8

STATUS="$(launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -E 'last exit code' | head -1 | tr -d ' ')"
printf '  %s\n' "${STATUS:-last exit code = unknown}"

if [ -s "$LOG_DIR/backup.launchd.err" ]; then
    printf '\n  stderr from that run:\n'
    sed 's/^/    /' "$LOG_DIR/backup.launchd.err" | tail -10
fi
if [ -s "$LOG_DIR/backup.launchd.out" ]; then
    printf '\n  stdout from that run:\n'
    sed 's/^/    /' "$LOG_DIR/backup.launchd.out" | tail -10
fi

cat <<MSG

Installed. Useful commands:

  launchctl print gui/$(id -u)/$LABEL | grep -E 'state|last exit'
  launchctl kickstart -k gui/$(id -u)/$LABEL      run it now
  tail -f $LOG_DIR/$PROG.log                      the tool's own log
  ./launchd/install-backup-job.sh --uninstall

A powered-off Mac misses its slot entirely; launchd only catches up from
sleep. If that matters:

  sudo pmset repeat wakeorpoweron MTWRFSU 03:55:00
MSG
