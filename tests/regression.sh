#!/bin/bash
#
# Regression suite for star-traders-sync.
#
# Every case here corresponds to a bug that was actually found and fixed,
# or to a guarantee the README makes. Runs entirely in a sandbox under
# $TMPDIR; never touches a real save directory, hub, or backup volume.
#
#   ./tests/regression.sh            run everything
#   ./tests/regression.sh -v         show output of failing cases

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
STS="$REPO/bin/star-traders-sync"
SB="$(mktemp -d "${TMPDIR:-/tmp}/sts-tests.XXXXXX")"
VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

PASS=0; FAIL=0
trap 'rm -rf "$SB"' EXIT

# This machine must self-detect as the hub so no ssh is needed.
HUBNAME="$(hostname -s | tr '[:upper:]' '[:lower:]')"

newcase() {
    CASE="$SB/$1"
    rm -rf "$CASE"
    mkdir -p "$CASE"/cfg/star-traders-sync "$CASE"/state "$CASE"/local "$CASE"/hub "$CASE"/vol/b
    cat > "$CASE/cfg/star-traders-sync/config" <<EOF
HUB_HOST=$HUBNAME
HUB_USER=$(whoami)
HUB_PATH=$CASE/hub
LOCAL_SAVE_PATH=$CASE/local
STEAM_APPID=335620
GAME_PROCESS_NAME=sts-no-such-process
SYNC_EXCLUDE=data.db steam_autocloud.vdf
SNAPSHOT_KEEP=3
BACKUP_VOLUME=$CASE/vol
BACKUP_DEST=$CASE/vol/b
EOF
    export XDG_CONFIG_HOME="$CASE/cfg" XDG_STATE_HOME="$CASE/state"
    for f in core.db game_1.db map_1.db template_1.json; do
        printf 'v1-%s\n' "$f" > "$CASE/local/$f"
    done
    printf 'static content\n' > "$CASE/local/data.db"
}

# check NAME EXPECTED_RC COMMAND...
check() {
    local name="$1" exp="$2"; shift 2
    local out rc
    out="$("$@" 2>&1)"; rc=$?
    if [ "$rc" = "$exp" ]; then
        PASS=$((PASS + 1)); printf '  ok   %s\n' "$name"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL %s (rc=%s, wanted %s)\n' "$name" "$rc" "$exp"
        [ "$VERBOSE" -eq 1 ] && printf '%s\n' "$out" | sed 's/^/       /'
    fi
}

section() { printf '\n%s\n' "$1"; }

# --------------------------------------------------------------------------
section "seeding and the empty-side guards"
newcase seed
check "empty hub: push refuses to seed silently"        62 "$STS" push
check "empty hub: --force=local seeds"                   0 "$STS" push --force=local
check "excluded data.db stayed local"                    0 test -f "$CASE/local/data.db"
check "excluded data.db not sent to the hub"             1 test -f "$CASE/hub/data.db"
check "in sync: push is a no-op"                         0 "$STS" push
check "in sync: pull is a no-op"                         0 "$STS" pull

rm -f "$CASE/hub"/*.db "$CASE/hub"/*.json
check "emptied hub: pull refuses"                       62 "$STS" pull
check "emptied hub: --force=hub does NOT override"      62 "$STS" pull --force=hub
check "local saves survived"                             0 test -f "$CASE/local/core.db"

newcase emptylocal
"$STS" push --force=local >/dev/null 2>&1
rm -f "$CASE/local"/*.db "$CASE/local"/*.json
check "emptied local: push refuses to wipe the hub"     61 "$STS" push
check "hub survived"                                     0 test -f "$CASE/hub/core.db"

# --------------------------------------------------------------------------
section "conflicts"
newcase conflict
"$STS" push --force=local >/dev/null 2>&1
printf 'local-edit\n' > "$CASE/local/game_1.db"
printf 'hub-edit\n'   > "$CASE/hub/game_2.db"
check "both changed: pull refuses"                      60 "$STS" pull
check "both changed: push refuses"                      60 "$STS" push
check "both changed: --force=local resolves"             0 "$STS" push --force=local

newcase forcedir
check "pull --force=local rejected at parse time"        2 "$STS" pull --force=local
check "push --force=hub rejected at parse time"          2 "$STS" push --force=hub
check "play --force rejected (used to fail post-game)"   2 "$STS" play --force=hub

# --------------------------------------------------------------------------
section "locking"
newcase locks
"$STS" push --force=local >/dev/null 2>&1
check "no hub lock left after an INSYNC push"            1 test -d "$CASE/.sts-lock"
check "no hub lock left after an INSYNC pull"            1 sh -c '"$1" pull >/dev/null 2>&1; test -d "$2/.sts-lock"' _ "$STS" "$CASE"

mkdir -p "$CASE/state/star-traders-sync/local.lock.d"
printf '99999\n' > "$CASE/state/star-traders-sync/local.lock"
check "stale local lock (dead pid) is broken"            0 "$STS" status
mkdir -p "$CASE/state/star-traders-sync/local.lock.d"
printf '%s\n' "$$" > "$CASE/state/star-traders-sync/local.lock"
check "live local lock is respected"                    52 "$STS" status
rm -rf "$CASE/state/star-traders-sync/local.lock.d" "$CASE/state/star-traders-sync/local.lock"

mkdir -p "$CASE/.sts-lock"
check "ownerless hub lock below TTL refuses"            50 "$STS" pull
rm -rf "$CASE/.sts-lock"

chmod 555 "$CASE"
check "unwritable hub parent: terminates, no recursion" 51 "$STS" push
chmod 755 "$CASE"

# --------------------------------------------------------------------------
section "interrupted swaps"
newcase orphan
"$STS" push --force=local >/dev/null 2>&1
mv "$CASE/local" "$CASE/local.sts-old-99999"
check "local orphan: refuses with restore instructions" 13 "$STS" status
mv "$CASE/local.sts-old-99999" "$CASE/local"

mv "$CASE/hub" "$CASE/hub.sts-old-99999"
check "hub orphan: status refuses"                      14 "$STS" status
check "hub orphan: pull refuses"                        14 "$STS" pull
check "hub orphan: push refuses (would have orphaned)"  14 "$STS" push --force=local
check "parked hub copy untouched"                        0 test -f "$CASE/hub.sts-old-99999/core.db"
mv "$CASE/hub.sts-old-99999" "$CASE/hub"

newcase staging
mkdir -p "$CASE/.sts-incoming-99999"; : > "$CASE/.sts-incoming-99999/f"
check "status does not delete a staging directory"       0 "$STS" status
check "  staging directory survived"                     0 test -d "$CASE/.sts-incoming-99999"

# --------------------------------------------------------------------------
section "excluded files and directories"
newcase excl
sed -i '' 's|^SYNC_EXCLUDE=.*|SYNC_EXCLUDE=data.db mods|' "$CASE/cfg/star-traders-sync/config"
mkdir -p "$CASE/local/mods"; printf 'MY-MOD\n' > "$CASE/local/mods/m1.txt"
"$STS" push --force=local >/dev/null 2>&1
printf 'hub-change\n' > "$CASE/hub/game_1.db"
check "pull with an excluded directory present"          0 "$STS" pull
check "  excluded directory survived the swap"           0 test -f "$CASE/local/mods/m1.txt"
check "  its contents are intact"                        0 grep -q MY-MOD "$CASE/local/mods/m1.txt"
check "  no false conflict on the next run"              0 "$STS" pull

# --------------------------------------------------------------------------
section "fingerprinting"
newcase hashable
"$STS" push --force=local >/dev/null 2>&1
touch "$CASE/local/$(printf 'bad\nname.db')"
check "unhashable file: refuses instead of 'in sync'"   13 "$STS" status
rm -f "$CASE/local/"$'bad\nname.db'
check "  normal again once removed"                      0 "$STS" status

# --------------------------------------------------------------------------
section "config handling"
newcase cfg
sed -i '' "s|^LOCAL_SAVE_PATH=.*|LOCAL_SAVE_PATH=$CASE/local/|" "$CASE/cfg/star-traders-sync/config"
check "trailing slash in a path is tolerated"            0 "$STS" push --force=local
sed -i '' "s|^HUB_HOST=.*|HUB_HOST = $HUBNAME|" "$CASE/cfg/star-traders-sync/config"
check "spaces around = are tolerated"                    0 "$STS" status
sed -i '' "s|^HUB_HOST.*|HUB_HOST=$HUBNAME|" "$CASE/cfg/star-traders-sync/config"
printf 'NOT_A_REAL_KEY=1\n' >> "$CASE/cfg/star-traders-sync/config"
check "unknown key is a hard error"                     11 "$STS" status
sed -i '' '/^NOT_A_REAL_KEY=/d' "$CASE/cfg/star-traders-sync/config"
printf 'HUB_PATH=/tmp/x;touch /tmp/sts-pwned;echo \n' >> "$CASE/cfg/star-traders-sync/config"
rm -f /tmp/sts-pwned
check "shell metacharacters in a path are rejected"     11 "$STS" status
check "  nothing executed"                               1 test -e /tmp/sts-pwned

# --------------------------------------------------------------------------
section "dry run writes nothing"
newcase dry
"$STS" push --force=local >/dev/null 2>&1
printf 'change\n' > "$CASE/hub/game_1.db"
BEFORE="$(find "$CASE/local" "$CASE/hub" -type f -exec shasum {} + | shasum)"
check "pull --dry-run succeeds"                          0 "$STS" pull --dry-run
AFTER="$(find "$CASE/local" "$CASE/hub" -type f -exec shasum {} + | shasum)"
check "  nothing changed on either side"                 0 test "$BEFORE" = "$AFTER"

# --------------------------------------------------------------------------
section "backup"
newcase backup
"$STS" push --force=local >/dev/null 2>&1
check "backup refuses a non-mount-point volume"         70 "$STS" backup

printf '\n%s: %s passed, %s failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
