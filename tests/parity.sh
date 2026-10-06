#!/bin/bash
#
# Runs bin/star-traders-sync and the Go build (cmd/sts) side by side on the
# same arguments and configs, and diffs exit code, stdout and stderr. While
# both exist the bash script is the reference: the Go build must refuse the
# same things with the same codes and the same words (#20, #25).
#
#   tests/parity.sh            build the Go binary, then compare
#   STS_GO=/path/sts tests/parity.sh
#
# Never touches a real config: HOME, XDG_CONFIG_HOME and XDG_STATE_HOME
# all point into a throwaway sandbox.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BASH_STS="$REPO/bin/star-traders-sync"
SB="$(mktemp -d "${TMPDIR:-/tmp}/sts-parity.XXXXXX")"
SB="$(cd "$SB" && pwd -P)"
trap 'chmod -R u+rwx "$SB" 2>/dev/null; rm -rf "$SB"' EXIT

GO_STS="${STS_GO:-}"
if [ -z "$GO_STS" ]; then
    GO_STS="$SB/sts-go"
    (cd "$REPO" && go build -o "$GO_STS" ./cmd/sts) || { echo "go build failed"; exit 1; }
fi

export HOME="$SB/home" XDG_CONFIG_HOME="$SB/cfg" XDG_STATE_HOME="$SB/state"
mkdir -p "$HOME"
CFG="$XDG_CONFIG_HOME/star-traders-sync/config"

PASS=0
FAIL=0

# compare NAME ARGS... - both must agree exactly.
compare() {
    local name="$1"; shift
    local brc grc
    "$BASH_STS" "$@" >"$SB/b.out" 2>"$SB/b.err"; brc=$?
    "$GO_STS"   "$@" >"$SB/g.out" 2>"$SB/g.err"; grc=$?
    if [ "$brc" = "$grc" ] && cmp -s "$SB/b.out" "$SB/g.out" && cmp -s "$SB/b.err" "$SB/g.err"; then
        PASS=$((PASS + 1)); printf '  ok   %s (%s)\n' "$name" "$brc"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL %s: bash %s, go %s\n' "$name" "$brc" "$grc"
        diff -u "$SB/b.out" "$SB/g.out" | sed 's/^/       /' | head -20
        diff -u "$SB/b.err" "$SB/g.err" | sed 's/^/       /' | head -20
    fi
}

# accepted NAME - a config both accept: bash goes on to its next check
# (never a config code, 10-12), the Go build stops where it ends (1).
accepted() {
    local name="$1" brc grc
    "$BASH_STS" status >/dev/null 2>&1; brc=$?
    "$GO_STS"   status >"$SB/g.out" 2>"$SB/g.err"; grc=$?
    if [ "$brc" -ge 10 ] && [ "$brc" -le 12 ] || [ "$grc" != 1 ] || ! grep -q "not in the Go build yet" "$SB/g.err"; then
        FAIL=$((FAIL + 1)); printf '  FAIL %s: bash %s, go %s (both should accept the config)\n' "$name" "$brc" "$grc"
        sed 's/^/       /' "$SB/g.err" | head -5
    else
        PASS=$((PASS + 1)); printf '  ok   %s (accepted)\n' "$name"
    fi
}

config() { mkdir -p "$(dirname "$CFG")"; rm -rf "$CFG"; printf '%b' "$1" > "$CFG"; }

GOOD='HUB_HOST=hubhost\nHUB_USER=me\nHUB_PATH=/srv/sts/hub\nLOCAL_SAVE_PATH=/srv/sts/local\nSTEAM_APPID=335620\nGAME_PROCESS_NAME=game\nBACKUP_VOLUME=/Volumes/B\nBACKUP_DEST=/Volumes/B/sts\n'
with() { config "$GOOD$1"; }   # GOOD, then lines that override it

echo "arguments"
compare "--version" --version
compare "--help" --help
compare "no command" 
compare "two commands" pull push
compare "unknown argument" bogus
compare "empty argument" ""
compare "unknown flag" status --nope
compare "pull --force=local" pull --force=local
compare "push --force=hub" push --force=hub
compare "--force=both" push --force=both
compare "--force without a value" push --force
compare "--fix without doctor" status --fix
compare "--expect-decision on status" status --expect-decision=HUB_ONLY
compare "--expect-decision lower case" pull --expect-decision=hub_only
compare "--expect-decision empty" pull --expect-decision=
compare "--json on pull" pull --json
compare "restore, two names" restore a b
compare "restore --json with a name" restore --json a
compare "restore --dry-run" restore --dry-run
compare "restore --force" restore --force=hub x
compare "a name before restore" x restore
compare "--help after an error" bogus --help

echo "the config file"
rm -rf "$XDG_CONFIG_HOME"
compare "no config" status
mkdir -p "$CFG"
compare "config is a directory" status
rm -rf "$CFG"
with ''; chmod 000 "$CFG"
compare "config unreadable" status
chmod 644 "$CFG"

echo "lines and keys"
config 'HUB_HOST hubhost\n';                    compare "a line without =" status
config 'NOPE=1\n';                              compare "unknown key" status
config 'HUB HOST=x\n';                          compare "space inside a key" status
config '# only a comment\n\n';                  compare "everything missing" status
config 'HUB_HOST=h\nHUB_USER=u\n';              compare "some keys missing" status
config "${GOOD}HUB_USER=\n";                    compare "a required key emptied" status
with 'SSH_PORT=22x\n';                          compare "non-numeric SSH_PORT" status
with 'SNAPSHOT_KEEP=-1\n';                      compare "negative SNAPSHOT_KEEP" status
with 'LOG_KEEP=\n';                             compare "empty numeric LOG_KEEP" status
with 'LOG_LEVEL=LOUD\n';                        compare "bad LOG_LEVEL" status
with 'HUB_PATH=srv/hub\n';                      compare "relative HUB_PATH" status
with 'LOCAL_SAVE_PATH=/srv/My Saves\n';         compare "a space in LOCAL_SAVE_PATH" status
with "BACKUP_DEST=/Volumes/B/it's\n";           compare "a quote in BACKUP_DEST" status
with 'SYNC_EXCLUDE=data.db a;b\n';              compare "unsafe SYNC_EXCLUDE entry" status
with 'LOCAL_SAVE_PATH=/srv/sts/hub\n';          compare "hub and saves the same" status
with 'LOCAL_SAVE_PATH=/srv/sts/hub/\n';         compare "the same, trailing slash" status
with 'LOCAL_SAVE_PATH=/srv/sts/hub/saves\n';    compare "saves inside the hub" status
with 'HUB_PATH=/srv/sts/local/hub\n';           compare "hub inside the saves" status
with 'BACKUP_DEST=/Volumes/Other/sts\n';        compare "BACKUP_DEST outside BACKUP_VOLUME" status
with 'BACKUP_DEST=/Volumes/B\n';                compare "BACKUP_DEST is BACKUP_VOLUME" status

echo "accepted configs"
with '';                                        accepted "the good config"
# A blank line saved with CRLF is just "\r": it must still read as blank.
config "$(printf '%b' "# saved on Windows\n\n$GOOD" | sed 's/$/\r/')"; accepted "CRLF line endings, blank line included"
config '# comment\n\nHUB_HOST = hubhost \nHUB_USER=me\nHUB_PATH=/srv/sts/hub///\nLOCAL_SAVE_PATH=/srv/sts/local\nSTEAM_APPID=335620\nGAME_PROCESS_NAME=game\nBACKUP_VOLUME=/Volumes/B/\nBACKUP_DEST=/Volumes/B/sts\n'
                                                accepted "spaces around =, trailing slashes, comments"
with 'HUB_HOST=other\nSYNC_EXCLUDE=data.db *.vdf\n'; accepted "a later line wins; a glob exclude"
config "${GOOD%\\n}";                           accepted "no newline at the end"
with 'HUB_PATH=~/hub\n';                        accepted "HUB_PATH with ~, expanded before the absolute check"

echo
echo "parity.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
