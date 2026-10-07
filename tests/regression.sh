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
# STS_BIN runs the suite against another build of the tool - the Go one
# (#25) - which must pass it unchanged.
STS="${STS_BIN:-$REPO/bin/star-traders-sync}"
# Cases that test the script's own functions read them from here, whatever
# build $STS is.
BASH_STS="$REPO/bin/star-traders-sync"
SB="$(mktemp -d "${TMPDIR:-/tmp}/sts-tests.XXXXXX")"
REAL_HOME="$HOME"
VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

PASS=0; FAIL=0
trap 'rm -rf "$SB"' EXIT

# Every case needs this machine to self-detect as the hub, so no ssh is
# involved. That means HUB_HOST must equal whatever the script's own
# tailscale lookup reports as Self.
#
# find_tailscale prefers /Applications/Tailscale.app over PATH, so a stub on
# PATH cannot override a real App Store install. Where one exists, ask it
# for the real node name; otherwise stub the whole thing, which is what CI
# runners need since they have no tailscaled at all.
TS_APP="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
if [ -x "$TS_APP" ]; then
    HUBNAME="$("$TS_APP" status --json 2>/dev/null \
        | python3 -c 'import json,sys;print((json.load(sys.stdin).get("Self",{}).get("HostName") or "").lower())' 2>/dev/null)"
    if [ -z "$HUBNAME" ]; then
        printf 'cannot reach the local tailscaled; start Tailscale or remove the app to use the stub\n' >&2
        exit 1
    fi
    printf 'using the installed Tailscale, node name: %s\n' "$HUBNAME"
else
    HUBNAME="$(hostname -s | tr '[:upper:]' '[:lower:]')"
    printf 'no Tailscale app present, stubbing it; node name: %s\n' "$HUBNAME"
fi

# The suite exercises sync logic, not Tailscale, and CI runners have no
# tailscaled. Stub it so the tests do not depend on a live tailnet: it
# reports this machine as Self, Running, with the hub name the cases use.
mkdir -p "$SB/bin"
cat > "$SB/bin/tailscale" <<STUB
#!/bin/bash
case "\$*" in
    *"status --json"*)
        cat <<JSON
{"BackendState":"Running",
 "Self":{"HostName":"$HUBNAME","DNSName":"$HUBNAME.test.ts.net.",
         "TailscaleIPs":["100.64.0.1"],"Online":true},
 "Peer":{}}
JSON
        ;;
    *"status"*)  printf '100.64.0.1  %s  test  macOS  -\n' "$HUBNAME" ;;
    *"ping"*)    printf 'pong from %s (100.64.0.1) in 1ms\n' "$HUBNAME" ;;
    *"version"*) printf 'stub\n' ;;
    *) exit 0 ;;
esac
STUB
chmod +x "$SB/bin/tailscale"
PATH="$SB/bin:$PATH"
export PATH

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
    mkdir -p "$CASE/home"
    export XDG_CONFIG_HOME="$CASE/cfg" XDG_STATE_HOME="$CASE/state"
    export HOME="$CASE/home"
    for f in core.db game_1.db map_1.db template_1.json; do
        printf 'v1-%s\n' "$f" > "$CASE/local/$f"
    done
    printf 'static content\n' > "$CASE/local/data.db"
}

# check NAME EXPECTED_RC COMMAND...
check() {
    if [ "$SKIPPING" -eq 1 ]; then SKIPPED=$((SKIPPED + 1)); return 0; fi
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

# STS_SKIP: a regex of section titles not run - for a build that does not
# have those commands yet (the Go one, #25). Skipped checks are counted and
# reported, never passed silently.
SKIPPED=0
SKIPPING=0
section() {
    printf '\n%s\n' "$1"
    SKIPPING=0
    if [ -n "${STS_SKIP:-}" ] && printf '%s' "$1" | grep -qE "$STS_SKIP"; then
        SKIPPING=1
        printf '  (skipped: STS_SKIP)\n'
    fi
}

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
# Brand new with a dead pid: most likely a run between its mkdir and its
# pid write (the file still names the run before it), so not cleared (#151).
check "brand-new local lock, dead pid: refused (52)"   52 "$STS" status
check "  and says another run is starting"                0 sh -c '"$1" status 2>&1 | grep -q "is starting"' _ "$STS"
touch -t 202001010000 "$CASE/state/star-traders-sync/local.lock.d"
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

newcase hostid
"$STS" push --force=local >/dev/null 2>&1
MYID="$(cat "$CASE/state/star-traders-sync/host-id" 2>/dev/null || true)"
check "a stable host id was recorded"                    0 test -n "$MYID"

# A lock whose stable id is not ours belongs to another machine, and must
# never be cleared automatically - even though the hostname matches, which
# is what the old hostname-only comparison went on.
mkdir -p "$CASE/.sts-lock"
printf '%s\n1234\n2020-01-01T00:00:00Z\n1577836800\nnonce\nsomeone-elses-uuid\n' \
    "$(hostname -s)" > "$CASE/.sts-lock/owner"
check "lock with a foreign id: refused despite same host" 50 "$STS" pull
check "  and not cleared"                                 0 test -d "$CASE/.sts-lock"

# Our own lock, ancient, is cleared past the TTL even if the hostname has
# changed since - which is the case the old comparison got wrong.
printf 'some-old-hostname\n1234\n2020-01-01T00:00:00Z\n1577836800\nnonce\n%s\n' \
    "$MYID" > "$CASE/.sts-lock/owner"
printf 'LOCK_TTL_SECONDS=1\n' >> "$CASE/cfg/star-traders-sync/config"
check "our own stale lock cleared despite a renamed host"  0 "$STS" pull
check "  lock released"                                    1 test -d "$CASE/.sts-lock"

# An owner file written by a version predating the stable id has five lines
# and no id. The comparison must fall back to the hostname, or an upgrade
# performed while a lock is held would orphan that lock.
mkdir -p "$CASE/.sts-lock"
printf '%s\n1234\n2020-01-01T00:00:00Z\n1577836800\nnonce\n' "$(hostname -s)" \
    > "$CASE/.sts-lock/owner"
check "old 5-line owner file: ours by hostname, TTL clears"  0 "$STS" pull
check "  lock released"                                      1 test -d "$CASE/.sts-lock"

mkdir -p "$CASE/.sts-lock"
printf 'some-other-machine\n1234\n2020-01-01T00:00:00Z\n1577836800\nnonce\n' \
    > "$CASE/.sts-lock/owner"
check "old 5-line owner file from another host: refused"    50 "$STS" pull
check "  and not cleared"                                    0 test -d "$CASE/.sts-lock"
rm -rf "$CASE/.sts-lock"

# The id's first write must be atomic: backup and the sync commands hold
# different local locks, so they can reach this concurrently on a machine
# that has no id yet.
newcase hostid_race
RACE="$CASE/racefn.sh"
sed -n '/^stable_host_id() {/,/^}/p' "$BASH_STS" > "$RACE"
mkdir -p "$CASE/raceout"
i=1
while [ "$i" -le 20 ]; do
    (
        STATE_DIR="$CASE/racestate"
        . "$RACE"
        this_host_id() { echo testhost; }
        stable_host_id > "$CASE/raceout/$i"
    ) &
    i=$((i + 1))
done
wait
RACE_DISTINCT="$(cat "$CASE"/raceout/* 2>/dev/null | sort -u | grep -c . || echo 0)"
check "20 concurrent first-runs agree on one id"             0 test "$RACE_DISTINCT" = "1"
check "  and it matches what is on disk"                     0 sh -c 'test "$(cat "$1"/raceout/1)" = "$(cat "$1"/racestate/host-id)"' _ "$CASE"

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

# A SYNC_EXCLUDE entry containing a glob is legal per validate_config. If
# the manifest expands it against the save directory instead of handing it
# to find as a pattern, find rejects the expression and the manifest comes
# back EMPTY - with no unhashable marker, so nothing downstream notices.
# Two machines with the same config would then both fingerprint as empty,
# compare equal, and report "in sync" forever while syncing nothing.
newcase globexclude
sed -i '' 's|^SYNC_EXCLUDE=.*|SYNC_EXCLUDE=*.bak|' "$CASE/cfg/star-traders-sync/config"
printf 'junk\n' > "$CASE/local/notes.bak"
printf 'junk\n' > "$CASE/local/other.bak"
GLOB_FILES="$("$STS" status 2>/dev/null | grep -oE 'files: +[0-9]+' | head -1 | grep -oE '[0-9]+')"
check "glob in SYNC_EXCLUDE: manifest is not empty"      0 test "${GLOB_FILES:-0}" -gt 0
check "  and the excluded files are excluded"            0 test "${GLOB_FILES:-0}" = "5"
check "  push still works with a glob exclude"           0 "$STS" push --force=local
check "  the .bak files did not reach the hub"           1 test -f "$CASE/hub/notes.bak"
check "  real saves did reach the hub"                   0 test -f "$CASE/hub/core.db"

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
section "remote command construction"
newcase inject
INJ="$CASE/injfn.sh"
sed -n '/^shq() {/,/^}/p; /^hub_exec_args() {/,/^}/p' "$BASH_STS" > "$INJ"
rm -f "$CASE/PWNED"
INJ_OK=1
# Values that would be code if they were interpolated into shell text.
for v in "plain" "with space" "it's quoted" "semi;colon" "dollar\$HOME" \
         'back`id`tick' "pipe|and&" "\$(touch $CASE/PWNED)" "; touch $CASE/PWNED"; do
    got="$(
        IS_HUB=1
        . "$INJ"
        hub_exec_args 'printf "%s" "$1"' "$v"
    )"
    [ "$got" = "$v" ] || INJ_OK=0
done
check "hostile values survive as literal arguments"      0 test "$INJ_OK" = "1"
check "  and none of them executed"                      1 test -e "$CASE/PWNED"

MULTI="$(IS_HUB=1; . "$INJ"; hub_exec_args 'printf "[%s][%s]" "$1" "$2"' "a b" "c'd")"
check "multiple arguments stay separate"                 0 test "$MULTI" = "[a b][c'd]"

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
section "doctor"
newcase doctor_ok
"$STS" push --force=local >/dev/null 2>&1
check "healthy machine: doctor exits 0"                  0 "$STS" doctor
check "  and reports zero problems"                      0 sh -c '"$1" doctor 2>&1 | grep -qE "Everything checks out|0 problem"' _ "$STS"

# A missing config must be reported, not crashed on: doctor exists precisely
# for the state where nothing else can run.
newcase doctor_noconfig
mkdir -p "$CASE/home/bin"
PATH="$CASE/home/bin:$PATH"
rm -f "$CASE/cfg/star-traders-sync/config"
check "no config: doctor exits 1 rather than dying"      1 "$STS" doctor
check "  names the missing file"                         0 sh -c '"$1" doctor 2>&1 | grep -q "no config at"' _ "$STS"
check "  and skips the rest instead of guessing"         0 sh -c '"$1" doctor 2>&1 | grep -q "nothing else can be checked"' _ "$STS"
check "  does not offer a repair that cannot help"       0 sh -c '"$1" doctor 2>&1 | grep -q "None of these can be repaired"' _ "$STS"
PATH="${PATH#"$CASE/home/bin:"}"

# The most common half-finished install: install.sh ran, config never edited.
newcase doctor_placeholder
sed -i '' 's|^HUB_USER=.*|HUB_USER=youruser|' "$CASE/cfg/star-traders-sync/config"
check "placeholder config: reported as a problem"        1 "$STS" doctor
check "  names the key still on its placeholder"         0 sh -c '"$1" doctor 2>&1 | grep -q "placeholders.*HUB_USER"' _ "$STS"

# The shipped defaults must stay ones doctor recognises (#47): a default
# that reads like a real hostname would pass as configured.
for src in "$REPO/config.example" "$REPO/install.sh"; do
    newcase doctor_shipped_defaults
    for k in HUB_HOST BACKUP_VOLUME BACKUP_DEST; do
        v="$(grep -m1 "^$k=" "$src" | cut -d= -f2)"
        check "${src##*/} ships a $k default"              0 test -n "$v"
        sed -i '' "s|^$k=.*|$k=$v|" "$CASE/cfg/star-traders-sync/config"
    done
    for k in HUB_HOST BACKUP_VOLUME BACKUP_DEST; do
        check "  doctor flags its default $k"             0 sh -c '"$1" doctor 2>&1 | grep -q "placeholders.*$2"' _ "$STS" "$k"
    done
done

# doctor without --fix must change nothing at all.
newcase doctor_readonly
rm -rf "$CASE/state"
# Its own log does not count: that is doctor recording what it did, not
# changing anything it inspected.
snap_case() { find "$CASE" -type f ! -path "*/Library/Logs/*" 2>/dev/null | LC_ALL=C sort | shasum; }
BEFORE="$(snap_case)"
"$STS" doctor >/dev/null 2>&1 || true
AFTER="$(snap_case)"
check "doctor without --fix changes nothing"             0 test "$BEFORE" = "$AFTER"

# --fix may only create things, never destroy.
newcase doctor_fix
rm -rf "$CASE/state"
"$STS" doctor --fix >/dev/null 2>&1 || true
check "doctor --fix created the state directory"         0 test -d "$CASE/state/star-traders-sync"
check "  and left the saves alone"                       0 test -f "$CASE/local/core.db"

# --fix edits ~/.zshrc only with a backup beside it. When the backup cannot
# be written, the file is left exactly as it was.
newcase doctor_rc_backup
mkdir -p "$CASE/home/.zshrc.sts-backup"; chmod 555 "$CASE/home/.zshrc.sts-backup"
printf 'alias ll="ls -l"\n' > "$CASE/home/.zshrc"
RC_OUT="$(PATH="${PATH//:$HOME\/bin/}" "$STS" doctor --fix 2>&1 || true)"
check "rc backup fails: ~/.zshrc is not changed"         0 test "$(cat "$CASE/home/.zshrc")" = 'alias ll="ls -l"'
check "  and doctor says so"                             0 sh -c 'printf "%s" "$1" | grep -q "could not back up"' _ "$RC_OUT"
chmod 755 "$CASE/home/.zshrc.sts-backup"

# The bug that made all of this necessary: doctor's helpers return non-zero
# for ordinary first-run states, and under set -e a bare call aborted the
# whole report at the first problem - the one thing doctor exists not to do.
# The most likely first-run state of all is "the game has never been
# launched", so there is no save directory yet.
newcase doctor_continues
rm -rf "$CASE/local"
check "a later failure does not truncate the report"     1 "$STS" doctor
check "  the summary line still prints"                  0 sh -c '"$1" doctor 2>&1 | grep -qE "problem\(s\)"' _ "$STS"
check "  the reassurance still prints"                   0 sh -c '"$1" doctor 2>&1 | grep -q "Nothing above was changed"' _ "$STS"
check "  and later sections still ran"                   0 sh -c '"$1" doctor 2>&1 | grep -q "tailscale"' _ "$STS"

# A symlinked save folder is followed by every other command; doctor's
# count used to stop at the link and call it empty (#168).
newcase doctor_symlinked_saves
mv "$CASE/local" "$CASE/real-local"; ln -s "$CASE/real-local" "$CASE/local"
check "symlinked save folder: its files are counted"   0 sh -c '"$1" doctor 2>&1 | grep -q "save directory, [1-9]"' _ "$STS"
check "  and it is not called empty"                   1 sh -c '"$1" doctor 2>&1 | grep -q "save directory is empty"' _ "$STS"

# doctor must reach the same verdict as the real commands. It used to
# hand-roll a subset of the validation and miss the nesting rule, so it
# could report the config fine for a config push would refuse.
newcase doctor_agrees
mkdir -p "$CASE/hub/saves"
printf 'x\n' > "$CASE/hub/saves/core.db"
sed -i '' "s|^LOCAL_SAVE_PATH=.*|LOCAL_SAVE_PATH=$CASE/hub/saves|" "$CASE/cfg/star-traders-sync/config"
check "nested paths: doctor rejects them"                1 "$STS" doctor
check "  push rejects them too"                         11 "$STS" push
check "  and both give the same reason"                  0 sh -c '"$1" doctor 2>&1 | grep -q "is inside HUB_PATH"' _ "$STS"

# The same set -e class again, on two paths the suite could not previously
# reach: a launchd job that is loaded but has never run emits no
# "last exit code" line, and a tailscale that prints anything other than
# clean JSON. Both aborted the whole report.
newcase doctor_stubs
mkdir -p "$CASE/stub"
cat > "$CASE/stub/launchctl" <<'STUB'
#!/bin/bash
# A job that is loaded but has never run: no "last exit code" line at all.
case "$1" in
    print) printf 'state = not running\npath = /dev/null\n'; exit 0 ;;
    *) exit 0 ;;
esac
STUB
chmod +x "$CASE/stub/launchctl"
PATH_SAVED="$PATH"
PATH="$CASE/stub:$PATH"
check "launchd job loaded but never run: report survives"  0 "$STS" doctor
check "  summary still printed"                            0 sh -c '"$1" doctor 2>&1 | grep -qE "problem\(s\)"' _ "$STS"
PATH="$PATH_SAVED"

cat > "$CASE/stub/tailscale" <<'STUB'
#!/bin/bash
# Something printed ahead of the JSON, as older clients and warnings do.
case "$*" in
    *"status --json"*) printf 'warning: something\n{ not valid json\n'; exit 0 ;;
    *) exit 0 ;;
esac
STUB
chmod +x "$CASE/stub/tailscale"
PATH="$CASE/stub:$PATH"
check "malformed tailscale JSON: report survives"          1 "$STS" doctor
check "  says it could not read the status"                0 sh -c '"$1" doctor 2>&1 | grep -q "not valid JSON"' _ "$STS"
check "  summary still printed"                            0 sh -c '"$1" doctor 2>&1 | grep -qE "problem\(s\)"' _ "$STS"
PATH="$PATH_SAVED"

# doctor used to compare only HostName when deciding whether this machine is
# the hub, while every other command also accepts the short MagicDNS label.
# When the two differ - a rename in the admin console, or Tailscale
# suffixing -1 to resolve a name collision between two Macs - doctor decided
# the hub was remote, tried to ssh to itself, and skipped every hub check
# without saying so. The default stub gives both names the same value, which
# is why nothing caught it.
newcase doctor_hubname
mkdir -p "$CASE/stub"
cat > "$CASE/stub/tailscale" <<STUB
#!/bin/bash
case "\$*" in
    *"status --json"*)
        cat <<JSON
{"BackendState":"Running",
 "Self":{"HostName":"renamed-in-admin-console",
         "DNSName":"$HUBNAME.test.ts.net.",
         "TailscaleIPs":["100.64.0.1"],"Online":true},
 "Peer":{}}
JSON
        ;;
    *"ping"*) printf 'pong\n' ;;
    *) exit 0 ;;
esac
STUB
chmod +x "$CASE/stub/tailscale"
PATH_SAVED="$PATH"; PATH="$CASE/stub:$PATH"
check "hub recognised by DNS name when HostName differs"   0 sh -c '"$1" doctor 2>&1 | grep -q "IS the hub"' _ "$STS"
check "  so the hub checks actually run"                   0 sh -c '"$1" doctor 2>&1 | grep -q "hub duties"' _ "$STS"
check "  and it does not try to ssh to itself"             1 sh -c '"$1" doctor 2>&1 | grep -q "cannot ssh to the hub"' _ "$STS"
PATH="$PATH_SAVED"

check "--fix is rejected on commands other than doctor"    2 "$STS" status --fix

# Until now every case made the test machine self-detect as the hub, so
# doc_ssh always took its early return and the entire ssh path - not just
# its failure branch - had zero coverage. That is how an unguarded
# assignment survived three reviews in a row.
newcase doctor_ssh
mkdir -p "$CASE/stub"
sed -i '' 's|^HUB_HOST=.*|HUB_HOST=some-other-machine|' "$CASE/cfg/star-traders-sync/config"
cat > "$CASE/stub/tailscale" <<'STUB'
#!/bin/bash
case "$*" in
    *"status --json"*)
        cat <<JSON
{"BackendState":"Running",
 "Self":{"HostName":"this-client","DNSName":"this-client.test.ts.net.",
         "TailscaleIPs":["100.64.0.9"],"Online":true},
 "Peer":{"x":{"HostName":"some-other-machine",
              "DNSName":"some-other-machine.test.ts.net.",
              "TailscaleIPs":["100.64.0.1"],"Online":true}}}
JSON
        ;;
    *"ping"*) printf 'pong\n'; exit 0 ;;
    *) exit 0 ;;
esac
STUB
# Host key "trusted", auth succeeds, but the hub probe loses the connection -
# the exact sequence that used to kill the report mid-way.
cat > "$CASE/stub/ssh-keygen" <<'STUB'
#!/bin/bash
case "$*" in
    *-F*) printf 'found\n'; exit 0 ;;
    *) exit 0 ;;
esac
STUB
cat > "$CASE/stub/ssh" <<'STUB'
#!/bin/bash
case "$*" in
    *"echo STS_OK"*) printf 'STS_OK\n'; exit 0 ;;
    *"bash -s"*)     printf 'client_loop: send disconnect\n' >&2; exit 255 ;;
    *) exit 0 ;;
esac
STUB
chmod +x "$CASE/stub/tailscale" "$CASE/stub/ssh-keygen" "$CASE/stub/ssh"

# Self-contained HOME. doc_ssh looks for ~/.ssh/id_ed25519, which exists on
# a developer machine and not on a fresh CI runner - so this case passed
# locally and failed in CI, which is the test depending on the environment
# rather than on the code.
mkdir -p "$CASE/home/.ssh"
: > "$CASE/home/.ssh/id_ed25519"
DOCTOR_SSH_CASE="$CASE"

doctor_ssh_says() {
    # Capture first, then match. grep -q closes the pipe as soon as it hits,
    # and under pipefail that surfaces as SIGPIPE (141) from doctor.
    local out
    out="$(HOME="$DOCTOR_SSH_CASE/home" \
           PATH="$DOCTOR_SSH_CASE/stub:$PATH" \
           XDG_CONFIG_HOME="$DOCTOR_SSH_CASE/cfg" \
           XDG_STATE_HOME="$DOCTOR_SSH_CASE/state" \
           "$STS" doctor 2>&1 || true)"
    printf '%s' "$out" | grep -q "$1"
}

check "non-hub machine: the ssh path actually runs"        0 doctor_ssh_says "key auth works"
check "connection lost mid-probe: report survives"         0 doctor_ssh_says "problem"
check "  and says what happened"                           0 doctor_ssh_says "lost the connection"
check "  reassurance still printed"                        0 doctor_ssh_says "Nothing above was changed"

# The fifth-round fix that this covers closed a real path to losing saves:
# --fix recreating HUB_PATH while a swap has it renamed aside turns the
# in-flight `mv staged hub` into a move INTO the new empty directory. mv
# exits 0, so the swap's own check reports success, and the pre-swap copy
# is then deleted. It had no test until now.
newcase doctor_hub_busy
"$STS" push --force=local >/dev/null 2>&1
rm -rf "$CASE/hub"                 # what a swap leaves behind, briefly
mkdir -p "$CASE/.sts-lock"         # ... while holding the hub lock
HUB_BUSY_OUT="$("$STS" doctor --fix 2>&1 || true)"
check "hub locked: --fix refuses to recreate HUB_PATH"   1 test -d "$CASE/hub"
check "  and says why"                                   0 sh -c 'printf "%s" "$1" | grep -q "a sync is running"' _ "$HUB_BUSY_OUT"
check "  report still completes"                         0 sh -c 'printf "%s" "$1" | grep -q "Nothing above was changed"' _ "$HUB_BUSY_OUT"

rm -rf "$CASE/.sts-lock"           # lock released, the repair is allowed
"$STS" doctor --fix >/dev/null 2>&1 || true
check "hub unlocked: --fix creates HUB_PATH"             0 test -d "$CASE/hub"

# doc_state_dirs carries its own copy of acquire_local_lock's kill -0
# liveness check. The existing lock cases only exercise the original, and
# doctor_fix cannot reach this one because it deletes the state directory
# first, so [ -d "$lockdir" ] is never true there.
newcase doctor_stale_lock
mkdir -p "$CASE/state/star-traders-sync/local.lock.d"
printf '%s\n' "$$" > "$CASE/state/star-traders-sync/local.lock"
LIVE_OUT="$("$STS" doctor 2>&1 || true)"
check "a live sts is reported, not cleared"              0 sh -c 'printf "%s" "$1" | grep -q "another sts is running"' _ "$LIVE_OUT"
check "  and its lock is left alone"                     0 test -d "$CASE/state/star-traders-sync/local.lock.d"

# A run between its mkdir and its pid write: the pid file is still empty.
# Clearing that would let two runs in at once (#151).
: > "$CASE/state/star-traders-sync/local.lock"
touch "$CASE/state/star-traders-sync/local.lock.d"
"$STS" doctor --fix >/dev/null 2>&1 || true
check "a lock being taken right now is not cleared"      0 test -d "$CASE/state/star-traders-sync/local.lock.d"
check "  and is reported as starting"                    0 sh -c '"$1" doctor 2>&1 | grep -q "another sts is starting"' _ "$STS"

touch -t 202001010000 "$CASE/state/star-traders-sync/local.lock.d"
printf '99999\n' > "$CASE/state/star-traders-sync/local.lock"
check "a dead owner's lock is reported stale"            0 sh -c '"$1" doctor 2>&1 | grep -q "owner 99999 is gone"' _ "$STS"
check "  but not cleared without --fix"                  0 test -d "$CASE/state/star-traders-sync/local.lock.d"
"$STS" doctor --fix >/dev/null 2>&1 || true
check "  and cleared with --fix"                         1 test -d "$CASE/state/star-traders-sync/local.lock.d"

# --------------------------------------------------------------------------
section "engine shim"
# The app installs macos/engine-shim.sh as star-traders-sync, with the script
# and the Go build beside it (#175). Fake engines say which one ran.
newcase engine_shim
SHIMDIR="$CASE/support/bin"
mkdir -p "$SHIMDIR" "$CASE/home/bin"
sed 's/@STS_VERSION@/9.9.9/' "$REPO/macos/engine-shim.sh" > "$SHIMDIR/star-traders-sync"
printf '#!/bin/bash\necho "bash engine: $*"\n' > "$SHIMDIR/star-traders-sync.bash"
printf '#!/bin/bash\necho "go engine: $*"\n' > "$SHIMDIR/star-traders-sync-go"
chmod 755 "$SHIMDIR"/*
ln -s "$SHIMDIR/star-traders-sync" "$CASE/home/bin/sts"
ENGINE_FILE="$CASE/cfg/star-traders-sync/engine"
shim_says() {   # shim_says EXPECTED [env assignments...] - run ~/bin/sts status
    local want="$1"; shift
    out="$(env "$@" "$CASE/home/bin/sts" status 2>&1)"
    [ "$out" = "$want" ] || { printf '      got: %s\n' "$out"; return 1; }
}
rm -f "$ENGINE_FILE"
check "no engine chosen: the script runs"                0 shim_says "bash engine: status"
echo go > "$ENGINE_FILE"
check "engine file says go: the Go build runs"           0 shim_says "go engine: status"
check "  STS_ENGINE=bash overrides the file"             0 shim_says "bash engine: status" STS_ENGINE=bash
echo "bash # rolled back" > "$ENGINE_FILE"
check "rollback: the first word decides"                 0 shim_says "bash engine: status"
check "  STS_ENGINE=go overrides the file"               0 shim_says "go engine: status" STS_ENGINE=go
mv "$SHIMDIR/star-traders-sync-go" "$SHIMDIR/gone"
check "go chosen but missing: the script runs"           0 sh -c '"$1" status 2>/dev/null | grep -qx "bash engine: status"' _ "$CASE/home/bin/sts" 
check "  and it says why"                                0 sh -c 'STS_ENGINE=go "$1" status 2>&1 >/dev/null | grep -q "engine is go, but .* is missing"' _ "$CASE/home/bin/sts"
mv "$SHIMDIR/gone" "$SHIMDIR/star-traders-sync-go"
check "the shim carries the version the app reads"       0 grep -qx 'readonly STS_VERSION="9.9.9"' "$SHIMDIR/star-traders-sync"

check "  and nothing on stderr when no engine is chosen"   0 test -z "$(rm -f "$ENGINE_FILE"; "$CASE/home/bin/sts" status 2>&1 >/dev/null)"

# The app's "is sts running" check is pgrep -f on bin/sts or
# bin/star-traders-sync. exec -a keeps that name on a binary engine, or the
# app would replace the tool under a running sync. A shebang script would
# not show it, and macOS kills a copied /bin/sleep, so a tiny compiled
# sleeper stands in for the Go build.
if printf '#include <unistd.h>\nint main(void){sleep(5);return 0;}\n' \
        | cc -x c -o "$SHIMDIR/star-traders-sync-go" - 2>/dev/null; then
    STS_ENGINE=go "$CASE/home/bin/sts" & SPID=$!
    sleep 1
    check "a running Go engine is still seen as sts"     0 sh -c 'ps -o args= -p "$1" | grep -qE "bin/(star-traders-sync|sts)( |$)"' _ "$SPID"
    kill "$SPID" 2>/dev/null; wait "$SPID" 2>/dev/null
else
    printf '  skip the running-name check (no C compiler here)\n'
fi

# The real thing: the shim in front of the real script and the Go build.
cp "$BASH_STS" "$SHIMDIR/star-traders-sync.bash"
GO_BUILD=""
[ "$STS" != "$BASH_STS" ] && GO_BUILD="$STS"      # the suite is running against Go
if [ -z "$GO_BUILD" ] && command -v go >/dev/null 2>&1; then
    (cd "$REPO" && go build -o "$CASE/sts-go" ./cmd/sts) && GO_BUILD="$CASE/sts-go"
fi
if [ -n "$GO_BUILD" ]; then
    cp "$GO_BUILD" "$SHIMDIR/star-traders-sync-go"
    WANT="$("$BASH_STS" --version)"
    check "the Go build runs through the shim"           0 test "$(STS_ENGINE=go "$CASE/home/bin/sts" --version)" = "$WANT"
    check "the script runs through the shim"             0 test "$(STS_ENGINE=bash "$CASE/home/bin/sts" --version)" = "$WANT"
    check "  and a refusal keeps its exit code"          2 env STS_ENGINE=go "$CASE/home/bin/sts" bogus
else
    printf '  skip the shim with real engines (no Go build here)\n'
fi

# --------------------------------------------------------------------------
section "status --json"
# jget PATH: run status --json with stderr discarded, so this also proves
# stdout carries only the JSON, then print one dotted field.
jget() {
    "$STS" status --json 2>/dev/null | python3 -c '
import json, sys
v = json.load(sys.stdin)
for k in sys.argv[1].split("."):
    v = v[k]
print(json.dumps(v) if isinstance(v, (bool, type(None))) else v)' "$1"
}
newcase json
check "hub empty: verdict hub_empty"                     0 test "$(jget verdict)" = hub_empty
"$STS" push --force=local >/dev/null 2>&1
check "after seeding: verdict in_sync"                   0 test "$(jget verdict)" = in_sync
check "  stdout is exactly one JSON object"              0 sh -c '"$1" status --json 2>/dev/null | python3 -c "import json,sys; json.load(sys.stdin)"' _ "$STS"
check "  local file count excludes SYNC_EXCLUDE"         0 test "$(jget sides.local.files)" = 4
check "  campaign saves counted"                         0 test "$(jget sides.local.campaign_saves)" = 1
check "  is_hub is a boolean"                            0 test "$(jget is_hub)" = true
check "  last sync direction is push"                    0 test "$(jget last_sync.direction)" = push
LS_AT="$(jget last_sync.at)"; NOW="$(date +%s)"
check "  last sync time is now, not the epoch"           0 test "$LS_AT" -gt $((NOW - 300)) -a "$LS_AT" -le $((NOW + 5))
check "  and agrees with the text status"                0 sh -c '"$1" status 2>/dev/null | grep -q "last sync    : push at "' _ "$STS"
check "  hub lock free"                                  0 test "$(jget hub_lock)" = null
check "  game not running"                               0 test "$(jget game_running)" = false
check "  both fingerprints agree"                        0 test "$(jget sides.local.fingerprint)" = "$(jget sides.hub.fingerprint)"
sleep 1; printf 'newer\n' > "$CASE/local/game_1.db"
check "local edit: verdict local_newer"                  0 test "$(jget verdict)" = local_newer
"$STS" push >/dev/null 2>&1
sleep 1; printf 'hub-newer\n' > "$CASE/hub/game_1.db"
check "hub edit: verdict hub_newer"                      0 test "$(jget verdict)" = hub_newer
check "text status agrees with the JSON verdict"         0 sh -c '"$1" status 2>/dev/null | grep -q "HUB is newer"' _ "$STS"
check "--json is rejected on other commands"             2 "$STS" push --json
printf 'BOGUS_KEY=1\n' >> "$CASE/cfg/star-traders-sync/config"
check "a refusal keeps its exit code under --json"      11 "$STS" status --json
check "  and leaves stdout empty"                        0 test -z "$("$STS" status --json 2>/dev/null)"

# --------------------------------------------------------------------------
section "status --json decision (what pull and push would do)"
STATEF() { printf '%s' "$CASE/state/star-traders-sync/last-sync.json"; }
newcase decide
check "local saves, empty hub: HUB_EMPTY"                0 test "$(jget decision)" = HUB_EMPTY
"$STS" push --force=local >/dev/null 2>&1
check "after seeding: INSYNC"                            0 test "$(jget decision)" = INSYNC
printf 'mine\n' > "$CASE/local/game_1.db"
check "only this machine changed: LOCAL_ONLY"            0 test "$(jget decision)" = LOCAL_ONLY
check "  and pull really refuses it"                    60 "$STS" pull
check "  text status says pull would refuse"             0 sh -c '"$1" status 2>/dev/null | grep -q "pull would refuse"' _ "$STS"
"$STS" push >/dev/null 2>&1
printf 'theirs\n' > "$CASE/hub/game_1.db"
check "only the hub changed: HUB_ONLY"                   0 test "$(jget decision)" = HUB_ONLY
printf 'mine-again\n' > "$CASE/local/core.db"
check "both changed: BOTH_CHANGED"                       0 test "$(jget decision)" = BOTH_CHANGED
check "  and pull really refuses it"                    60 "$STS" pull

newcase decidefirst
"$STS" push --force=local >/dev/null 2>&1
check "  the state file the case removes exists"        0 test -f "$(STATEF)"
rm -f "$(STATEF)"
sleep 1; printf 'other\n' > "$CASE/local/game_1.db"
check "never synced, both have saves: FIRSTRUN_CONFLICT" 0 test "$(jget decision)" = FIRSTRUN_CONFLICT
check "  even though the timestamps say local newer"     0 test "$(jget verdict)" = local_newer
check "  and pull really refuses it"                    61 "$STS" pull
rm -f "$CASE/local"/*.db "$CASE/local"/*.json
check "never synced, this machine empty: FIRST_SEED"     0 test "$(jget decision)" = FIRST_SEED
HUB_BEFORE="$(cat "$CASE/hub/game_1.db")"
check "  and push really refuses it"                    61 "$STS" push
check "  even with --force=local"                       61 "$STS" push --force=local
check "  and the hub kept its saves"                     0 test "$(cat "$CASE/hub/game_1.db")" = "$HUB_BEFORE"

# Emptied after a sync: pull and push refuse in their guards before
# decide() runs, so status must not report decide()'s HUB_ONLY/LOCAL_ONLY.
newcase decideemptied
"$STS" push --force=local >/dev/null 2>&1
rm -f "$CASE/hub"/*.db "$CASE/hub"/*.json
check "hub emptied after a sync: HUB_EMPTY, not HUB_ONLY" 0 test "$(jget decision)" = HUB_EMPTY
check "  and pull really refuses it"                    62 "$STS" pull
check "  and plain push really refuses it"              62 "$STS" push
"$STS" push --force=local >/dev/null 2>&1
rm -f "$CASE/local"/*.db "$CASE/local"/*.json
check "local emptied after a sync: LOCAL_EMPTIED"        0 test "$(jget decision)" = LOCAL_EMPTIED
check "  and push really refuses it"                    61 "$STS" push
check "  and plain pull really refuses it"              61 "$STS" pull
check "  saying the saves are gone, not 'only this machine changed'" 0 sh -c '"$1" pull 2>&1 | grep -q "saves are gone"' _ "$STS"
check "  text says how to restore"                       0 sh -c '"$1" status 2>/dev/null | grep -q "restore them with"' _ "$STS"
check "  and pull --force=hub really restores"           0 "$STS" pull --force=hub
check "  after which: INSYNC"                            0 test "$(jget decision)" = INSYNC

# Diverged: neither side changed since the recorded sync, yet they differ.
# Made by recording a sync, then editing a file on the hub and rewriting
# the record's hub fingerprint to match the edit.
newcase decidediverged
"$STS" push --force=local >/dev/null 2>&1
printf 'edited\n' > "$CASE/hub/game_1.db"
NEWHFP="$(jget sides.hub.fingerprint)"
python3 - "$(STATEF)" "$NEWHFP" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for k in list(d):
    if "hub" in k and "f" in k:
        d[k] = sys.argv[2]
json.dump(d, open(sys.argv[1], "w"))
PY
check "recorded state disagrees with disk: DIVERGED_STATE" 0 test "$(jget decision)" = DIVERGED_STATE
check "  and --force=hub really does not override it"   60 "$STS" pull --force=hub
check "  text says --force does not help"                0 sh -c '"$1" status 2>/dev/null | grep -q "does not override"' _ "$STS"

# --------------------------------------------------------------------------
section "--expect-decision (a confirmed choice cannot run against a changed state)"
newcase expect
"$STS" push --force=local >/dev/null 2>&1
check "status and --expect-decision share one decision"  0 test "$(jget decision)" = INSYNC
check "matching expectation: pull runs"                  0 "$STS" pull --expect-decision=INSYNC
printf 'theirs\n' > "$CASE/hub/game_1.db"
HUB_BEFORE="$(cat "$CASE/hub/game_1.db")"; LOCAL_BEFORE="$(cat "$CASE/local/game_1.db")"
# The app confirmed "hub is empty, send mine" earlier; since then another
# machine pushed. The stale --force must not run.
check "stale expectation: push --force=local refuses"   64 "$STS" push --force=local --expect-decision=HUB_EMPTY
check "  and the hub was not touched"                    0 test "$(cat "$CASE/hub/game_1.db")" = "$HUB_BEFORE"
check "stale expectation: pull --force=hub refuses"     64 "$STS" pull --force=hub --expect-decision=LOCAL_ONLY
check "  and this machine was not touched"               0 test "$(cat "$CASE/local/game_1.db")" = "$LOCAL_BEFORE"
check "  and the hub lock was released"                  0 "$STS" status
check "current expectation: pull runs"                   0 "$STS" pull --expect-decision=HUB_ONLY
check "  and brought the hub's change"                   0 test "$(cat "$CASE/local/game_1.db")" = "$HUB_BEFORE"
rm -f "$CASE/hub"/*.db "$CASE/hub"/*.json
check "emptied hub is expected as HUB_EMPTY"             0 "$STS" push --force=local --expect-decision=HUB_EMPTY
check "--expect-decision is rejected on play"            2 "$STS" play --expect-decision=INSYNC
check "--expect-decision is rejected on status"          2 "$STS" status --expect-decision=INSYNC
check "a malformed decision is a usage error"            2 "$STS" pull "--expect-decision=hub only"

# --------------------------------------------------------------------------
section "tailscale answers that are not clean JSON (#97)"
newcase tsanswers
"$STS" push --force=local >/dev/null 2>&1
mkdir -p "$CASE/stub"
PATH_TS_SAVED="$PATH"
cat > "$CASE/stub/tailscale" <<STUB
#!/bin/bash
# A warning on stderr, valid JSON on stdout: what an updated app prints.
case "\$*" in
    *"status --json"*)
        echo 'Warning: client version "1.94.1" != tailscaled server version "1.102.4"' >&2
        printf '{"BackendState":"Running","Self":{"HostName":"$HUBNAME","DNSName":"$HUBNAME.test.ts.net.","TailscaleIPs":["100.64.0.1"],"Online":true},"Peer":{}}\n' ;;
    *) exit 0 ;;
esac
STUB
chmod +x "$CASE/stub/tailscale"
PATH="$CASE/stub:$PATH_TS_SAVED"
# Without this, a Mac with the Tailscale app would run the real one and
# these cases would test nothing.
export STS_TS_APP_PATH=/nonexistent/Tailscale
check "the stub, not the app, answers in this section"   0 sh -c '"$1" status 2>&1 >/dev/null; grep -q "status --json warned" "$HOME/Library/Logs/star-traders-sync/star-traders-sync.log"' _ "$STS"
check "stderr warning + JSON: status works"               0 "$STS" status
check "  and status --json is still clean"               0 sh -c '"$1" status --json 2>/dev/null | python3 -c "import json,sys; json.load(sys.stdin)"' _ "$STS"

cat > "$CASE/stub/tailscale" <<'STUB'
#!/bin/bash
# Disconnected: a sentence, exit 0, no JSON at all.
case "$*" in
    *"status --json"*) echo "Tailscale is stopped." ;;
    *) exit 0 ;;
esac
STUB
chmod +x "$CASE/stub/tailscale"
check "not JSON: refuses with 22"                        22 "$STS" play
check "  with no Python traceback"                        1 sh -c '"$1" play 2>&1 | grep -q Traceback' _ "$STS"
check "  and says Tailscale is not connected"            0 sh -c '"$1" pull 2>&1 | grep -q "probably not connected"' _ "$STS"
check "  and touched nothing"                            0 test -f "$CASE/local/core.db"
PATH="$PATH_TS_SAVED"
unset STS_TS_APP_PATH
section "bringing tailscale up on a client keeps the JSON clean (#103)"
newcase tsup
"$STS" push --force=local >/dev/null 2>&1
# A client of another hub, which is what the work Mac is: resolve_hub_endpoint
# calls ts_ensure_up, which runs 'tailscale up' when the state is Stopped.
sed -i '' "s/^HUB_HOST=.*/HUB_HOST=otherhub/" "$CASE/cfg/star-traders-sync/config"
mkdir -p "$CASE/stub"
cat > "$CASE/stub/tailscale" <<STUB
#!/bin/bash
FLAG="$CASE/stub/up-ran"
case "\$*" in
    up*) touch "\$FLAG"; exit 0 ;;
    *"status --json"*)
        if [ -f "\$FLAG" ]; then state=Running; else state=Stopped; fi
        printf '{"BackendState":"%s","Self":{"HostName":"$HUBNAME","DNSName":"$HUBNAME.test.ts.net.","TailscaleIPs":["100.64.0.1"],"Online":true},"Peer":{"p":{"HostName":"otherhub","DNSName":"otherhub.test.ts.net.","TailscaleIPs":["100.64.0.9"],"Online":false}}}\n' "\$state" ;;
    *) exit 0 ;;
esac
STUB
chmod +x "$CASE/stub/tailscale"
PATH_UP_SAVED="$PATH"
PATH="$CASE/stub:$PATH"
export STS_TS_APP_PATH=/nonexistent/Tailscale
# Gets past ts_find_peer to the real verdict: the stub's hub is offline (25).
# Before the fix this was a Python traceback and exit 1.
check "Stopped, brought up: reaches the hub check (25)" 25 "$STS" pull
check "  'tailscale up' really ran"                      0 test -f "$CASE/stub/up-ran"
rm -f "$CASE/stub/up-ran"
check "  with no Python traceback"                       1 sh -c '"$1" pull 2>&1 | grep -q Traceback' _ "$STS"
rm -f "$CASE/stub/up-ran"
check "  and still says it is bringing tailscale up"     0 sh -c '"$1" pull 2>&1 | grep -q "bringing it up"' _ "$STS"
PATH="$PATH_UP_SAVED"
unset STS_TS_APP_PATH

# --------------------------------------------------------------------------
section "an interrupted run never leaves the hub lock behind (#129)"
newcase locksignals
"$STS" push --force=local >/dev/null 2>&1
MYID="$(cat "$CASE/state/star-traders-sync/host-id" 2>/dev/null || true)"
NOW="$(date -u +%s)"
# A pid that is certainly not running: find a free one.
DEAD=99999
while ps -p "$DEAD" >/dev/null 2>&1; do DEAD=$((DEAD - 1)); done

# Our own lock, fresh, whose recorded pid is gone, still waits for the TTL.
# A dead sts pid does not prove its work stopped: an rsync child or the
# hub-side swap over ssh can outlive a SIGKILLed client (#131 review).
mkdir -p "$CASE/.sts-lock"
printf '%s\n%s\n2026-01-01T00:00:00Z\n%s\nnonce\n%s\n' \
    "$(hostname -s)" "$DEAD" "$NOW" "$MYID" > "$CASE/.sts-lock/owner"
check "own fresh lock, owner pid dead: still refused"   50 "$STS" pull
check "  and not cleared"                                0 test -d "$CASE/.sts-lock"
rm -rf "$CASE/.sts-lock"

# Two runs judging the same stale lock (#132). A stub mkdir plays the other
# run: just as this run takes the clearing mutex, the other one has already
# cleared the stale lock and taken a fresh one. The clear must re-judge and
# leave that fresh lock alone.
racestub() {   # $1: what the "other run" does first
    cat > "$CASE/racestub/mkdir" <<STUB
#!/bin/sh
case "\$1" in
    */.sts-lock.clearing)
        if [ ! -f "$CASE/racestub/fired" ]; then
            touch "$CASE/racestub/fired"
            $1
        fi ;;
esac
exec /bin/mkdir "\$@"
STUB
    chmod +x "$CASE/racestub/mkdir"
    rm -f "$CASE/racestub/fired"
}
mkdir -p "$CASE/racestub"
printf 'LOCK_TTL_SECONDS=60\n' >> "$CASE/cfg/star-traders-sync/config"
L="$CASE/.sts-lock"
OWNED='rm -rf "'"$L"'"; /bin/mkdir "'"$L"'"; printf "%s\\n%s\\n2026-01-01T00:00:00Z\\n%s\\nother-run\\n%s\\n" "$(hostname -s)" "$$" "$(date -u +%s)" "'"$MYID"'" > "'"$L"'/owner"'
BARE='rm -rf "'"$L"'"; /bin/mkdir "'"$L"'"'
stale_owned() {
    mkdir -p "$L"
    printf '%s\n1234\n2020-01-01T00:00:00Z\n1577836800\nold-run\n%s\n' "$(hostname -s)" "$MYID" > "$L/owner"
}
stale_bare() { mkdir -p "$L"; touch -t 202001010000 "$L"; }

stale_owned; racestub "$OWNED"
check "stale lock retaken mid-clear: refused, not stolen" 50 env PATH="$CASE/racestub:$PATH" "$STS" pull
check "  the other run's lock is untouched"              0 test "$(sed -n 5p "$L/owner")" = other-run
rm -rf "$L"

stale_bare; racestub "$OWNED"
check "ownerless lock retaken mid-clear: refused"       50 env PATH="$CASE/racestub:$PATH" "$STS" pull
check "  the other run's lock is untouched"              0 test "$(sed -n 5p "$L/owner")" = other-run
rm -rf "$L"

# The other run has only just done its mkdir, and has not written its owner
# file yet. It looks ownerless, but it is young, so it is not stale.
stale_bare; racestub "$BARE"
check "ownerless lock retaken, owner not yet written: refused" 50 env PATH="$CASE/racestub:$PATH" "$STS" pull
check "  that fresh lock is untouched"                   0 test -d "$L"
rm -rf "$L"

# Another run is clearing right now.
stale_owned; mkdir "$L.clearing"
check "another run is clearing: refused"                50 "$STS" pull
check "  and says so"                                    0 sh -c '"$1" pull 2>&1 | grep -q "another run is clearing"' _ "$STS"
check "  the stale lock is left for that run"            0 test "$(sed -n 5p "$L/owner")" = old-run
# A clearer that died inside the clear left its mutex. Removing it
# automatically would be check-then-act again, so it is reported.
touch -t 202001010000 "$L.clearing"
check "dead clearer's mutex: refused"                   50 "$STS" pull
check "  and says how to remove it"                      0 sh -c '"$1" pull 2>&1 | grep -q "rmdir .*\.sts-lock\.clearing"' _ "$STS"
check "  the mutex is left alone"                        0 test -d "$L.clearing"
rmdir "$L.clearing"
check "  once removed, the next run clears the stale lock" 0 "$STS" pull
rm -rf "$L"

# A stale lock whose owner record has no nonce cannot be told apart from a
# fresh lock whose owner file is not written yet. Never cleared by itself.
mkdir -p "$L"
printf '%s\n1234\n2020-01-01T00:00:00Z\n1577836800\n' "$(hostname -s)" > "$L/owner"
check "stale lock with no nonce: refused"               50 "$STS" pull
check "  and says how to remove it"                      0 sh -c '"$1" pull 2>&1 | grep -q "rm -rf .*\.sts-lock"' _ "$STS"
check "  and not cleared"                                0 test -f "$L/owner"
check "  nor announced as cleared"                       1 sh -c '"$1" pull 2>&1 | grep -q "clearing a stale hub lock"' _ "$STS"
rm -rf "$L"

# An mtime that cannot be read is never "old": a stat that fails must not
# clear a young lock or a live clearer's mutex.
mkdir -p "$CASE/nostat"
printf '#!/bin/sh\nexit 1\n' > "$CASE/nostat/stat"; chmod +x "$CASE/nostat/stat"
stale_bare
check "unreadable mtime: ownerless lock not cleared"    50 env PATH="$CASE/nostat:$PATH" "$STS" pull
check "  and still there"                                0 test -d "$L"
rm -rf "$L"
stale_owned; mkdir "$L.clearing"; touch -t 202001010000 "$L.clearing"
check "unreadable mtime: the mutex counts as live"       0 sh -c 'PATH="$2:$PATH" "$1" pull 2>&1 | grep -q "another run is clearing"' _ "$STS" "$CASE/nostat"
rmdir "$L.clearing"; rm -rf "$L"

# And the plain stale clears still work.
stale_owned
check "stale lock, no race: cleared"                     0 "$STS" pull
check "  and no mutex left behind"                       1 test -d "$L.clearing"
stale_bare
check "ownerless stale lock, no race: cleared"           0 "$STS" pull
sed -i '' '/^LOCK_TTL_SECONDS=60$/d' "$CASE/cfg/star-traders-sync/config"

# A reader that goes away mid-run (`sts play | head -1`). The lock must be
# gone the moment sts exits, not merely cleared by the next run.
printf 'GAME_START_TIMEOUT=2\n' >> "$CASE/cfg/star-traders-sync/config"
mkdir -p "$CASE/nosteam"
printf '#!/bin/sh\nexit 0\n' > "$CASE/nosteam/open"
chmod +x "$CASE/nosteam/open"
printf 'ahead\n' > "$CASE/local/game_1.db"
# The exit code proves the run really died of the closed pipe, not of
# something else (no game here: 41) that would also have released the lock.
# 141 where SIGPIPE reaches the trap; 1 where the caller started us with it
# ignored (GitHub's runner does), which bash cannot undo - the write then
# fails with EPIPE and set -e ends the run.
check "play into a closed pipe dies of it (141 or 1)"    0 bash -c 'PATH="$2:$PATH" "$1" play 2>&1 | head -c 1 >/dev/null; rc="${PIPESTATUS[0]}"; [ "$rc" = 141 ] || [ "$rc" = 1 ]' _ "$STS" "$CASE/nosteam"
check "  no hub lock left"                               1 test -d "$CASE/.sts-lock"
rm -rf "$CASE/.sts-lock"

# A hangup (terminal closed) while a transfer runs.
mkdir -p "$CASE/slow"
printf '#!/bin/sh\nsleep 2\nexec /usr/bin/rsync "$@"\n' > "$CASE/slow/rsync"
chmod +x "$CASE/slow/rsync"
printf 'ahead again\n' > "$CASE/local/game_1.db"
PATH="$CASE/slow:$PATH" "$STS" push >/dev/null 2>&1 &
BG=$!
# Wait until the lock is this push's own: then sts is past its traps. A
# HUP that lands earlier hits the forked child while it is still a copy of
# this suite, and bash runs the suite's EXIT trap (rm -rf "$SB") in it.
i=0
while [ "$(sed -n 2p "$CASE/.sts-lock/owner" 2>/dev/null)" != "$BG" ] && [ "$i" -lt 100 ]; do
    sleep 0.1; i=$((i + 1))
done
kill -HUP "$BG" 2>/dev/null || true
wait "$BG"; RC=$?
check "push hung up mid-transfer exits 129"              0 test "$RC" -eq 129
check "  no hub lock left"                               1 test -d "$CASE/.sts-lock"
check "  the next push succeeds"                         0 "$STS" push

# A hangup in the instant this machine's saves have been moved aside and the
# staged copy from the hub is not yet in place. Injected through a stub mv,
# so it is about the script: the Go build swaps with rename(2) and holds a
# signal until the swap is done (internal/transfer, TestAnInterruptWaitsForTheSwap).
if [ -z "${STS_BIN:-}" ]; then
newcase swaphup
"$STS" push --force=local >/dev/null 2>&1
printf 'from the other mac\n' > "$CASE/hub/game_1.db"     # the hub moved on
mkdir -p "$CASE/hupmv"
# Hang up our caller while it moves the save folder aside; bash runs the
# trap as soon as this mv returns.
printf '#!/bin/sh\nif [ "$1" = "%s" ]; then kill -HUP "$PPID"; fi\nexec /bin/mv "$@"\n' \
    "$CASE/local" > "$CASE/hupmv/mv"
chmod +x "$CASE/hupmv/mv"
check "pull hung up mid-swap exits 129"                129 env PATH="$CASE/hupmv:$PATH" "$STS" pull
check "  the staged copy is kept"                        0 sh -c 'test -f "$(ls -d "$1"/.sts-incoming-* | head -1)/game_1.db"' _ "$CASE"
check "  the old saves are parked, not lost"             0 sh -c 'test -f "$(ls -d "$1"/local.sts-old-* | head -1)/game_1.db"' _ "$CASE"
check "  no hub lock left"                               1 test -d "$CASE/.sts-lock"
check "  the next pull refuses until they are restored" 13 "$STS" pull
else
    printf '  skip the hangup mid-swap (script-only: the Go build cannot be interrupted between its renames)\n'
fi

# --------------------------------------------------------------------------
section "a client of a remote hub, over a loopback ssh"
# This machine plays a client of "remotehub". The ssh stub does what ssh
# does - joins the remote command and hands it to a shell - only on this
# machine, so the whole client path (hub_exec_args over bash -s, rsync -e
# ssh) runs for real against the sandbox hub. Use client_on / client_off.
client_on() {
    sed -i '' "s/^HUB_HOST=.*/HUB_HOST=remotehub/" "$CASE/cfg/star-traders-sync/config"
    mkdir -p "$CASE/clientstub"
    cat > "$CASE/clientstub/tailscale" <<'STUB'
#!/bin/bash
case "$*" in
    *"status --json"*)
        printf '{"BackendState":"Running","Self":{"HostName":"thisclient","DNSName":"thisclient.test.ts.net.","TailscaleIPs":["100.64.0.9"],"Online":true},"Peer":{"p":{"HostName":"remotehub","DNSName":"remotehub.test.ts.net.","TailscaleIPs":["100.64.0.1"],"Online":true}}}\n' ;;
    *ping*) printf 'pong from remotehub\n' ;;
esac
exit 0
STUB
    cat > "$CASE/clientstub/ssh-keygen" <<'STUB'
#!/bin/bash
case "$*" in *-F*) printf 'remotehub ssh-ed25519 AAAA\n' ;; esac
exit 0
STUB
    # MagicDNS "resolves", as on a real client: no fallback note printed.
    printf '#!/bin/sh\nexit 0\n' > "$CASE/clientstub/ping"
    cat > "$CASE/clientstub/ssh" <<'STUB'
#!/bin/bash
# Skip options, then the destination; the rest is the remote command.
while [ $# -gt 0 ]; do
    case "$1" in
        -o|-p|-l|-i|-F) shift 2 ;;
        -*) shift ;;
        *) shift; break ;;
    esac
done
# drop-carry: the connection dies under the excluded-file carry alone.
if [ -f "${0%/*}/drop-carry" ] && [ "${1%% *}" = bash ]; then   # a bash -s script on stdin; never rsync's stream
    script="$(cat)"
    case "$script" in
        *STS_CARRY_OK*) echo "client_loop: send disconnect" >&2; exit 255 ;;
    esac
    printf '%s\n' "$script" | exec /bin/sh -c "$*"
fi
exec /bin/sh -c "$*"
STUB
    chmod +x "$CASE/clientstub/"*
    CLIENT_PATH_SAVED="$PATH"
    PATH="$CASE/clientstub:$PATH"
    export STS_TS_APP_PATH=/nonexistent/Tailscale
}
client_off() {
    PATH="$CLIENT_PATH_SAVED"
    unset STS_TS_APP_PATH
}

newcase client
client_on
check "client: seed the remote hub"                      0 "$STS" push --force=local
printf 'hub-local\n' > "$CASE/hub/data.db"      # machine-local, never synced
printf 'client change\n' > "$CASE/local/game_1.db"
check "client: status sees the remote hub"               0 test "$(jget decision)" = LOCAL_ONLY
check "client: push over ssh"                            0 "$STS" push
check "  the hub has the change"                         0 test "$(cat "$CASE/hub/game_1.db")" = "client change"
check "  the hub's excluded file was carried across"     0 test "$(cat "$CASE/hub/data.db")" = hub-local

# #128: an excluded file the hub-side carry cannot copy. The swap would
# delete it, so the push must refuse - as it already did from the hub host.
# A cp that fails for data.db alone: the snapshot (cpio) still succeeds,
# so only the carry can stop this push.
printf '#!/bin/sh\nfor a; do case "$a" in *data.db) echo "cp: $a: I/O error" >&2; exit 1 ;; esac; done\nexec /bin/cp "$@"\n' \
    > "$CASE/clientstub/cp"
chmod +x "$CASE/clientstub/cp"
printf 'second change\n' > "$CASE/local/game_1.db"
check "client push, uncopyable excluded file: refuses (63)" 63 "$STS" push
check "  and says why"                                   0 sh -c '"$1" push 2>&1 | grep -q "failed to preserve the excluded path"' _ "$STS"
rm -f "$CASE/clientstub/cp"
check "  the hub is unchanged"                           0 test "$(cat "$CASE/hub/game_1.db")" = "client change"
check "  and still has the excluded file"                0 test "$(cat "$CASE/hub/data.db")" = hub-local
check "  once it can be copied again, the push goes"       0 "$STS" push
check "  and carries it"                                 0 test "$(cat "$CASE/hub/data.db")" = hub-local

# A refusal read through a pipe that closes early, with SIGPIPE ignored the
# way CI's runner starts us. The failed write leaves bash 3.2's stdout
# buffer dirty, and the release used to build its ssh command from $(...)
# calls that came back polluted, leaving the hub lock held (#129, client
# side). Only stdout goes to the pipe, and its reader is gone before sts
# starts, so the first failed write is the one made under the lock.
LEFT=0
for i in 1 2 3; do
    bash -c 'trap "" PIPE; "$1" push 2>/dev/null | true' _ "$STS"
    [ -d "$CASE/.sts-lock" ] && LEFT=$((LEFT + 1)) && rm -rf "$CASE/.sts-lock"
done
check "client refusal into a closed pipe: never leaves the lock" 0 test "$LEFT" -eq 0

# An untrusted host key whose other address is already trusted with the
# same key: the advice says adding it is safe - all of it on stderr, with
# the refusal (its first line once went to stdout).
mkdir -p "$CASE/hkstub"
printf '#!/bin/sh\necho "Host key verification failed." >&2\nexit 255\n' > "$CASE/hkstub/ssh"
printf '#!/bin/sh\ncase "$*" in *-F*) echo "remotehub ssh-ed25519 AAAAsame" ;; esac\nexit 0\n' > "$CASE/hkstub/ssh-keygen"
printf '#!/bin/sh\necho "100.64.0.1 ssh-ed25519 AAAAsame"\n' > "$CASE/hkstub/ssh-keyscan"
chmod +x "$CASE/hkstub/"*
check "untrusted host key: refused (31)"                31 env PATH="$CASE/hkstub:$PATH" "$STS" status
check "  says the same key is already trusted"           0 sh -c 'PATH="$2:$PATH" "$1" status 2>&1 >/dev/null | grep -q "identical host key"' _ "$STS" "$CASE/hkstub"
check "  and prints nothing of it on stdout"             0 test -z "$(PATH="$CASE/hkstub:$PATH" "$STS" status 2>/dev/null)"

# The connection drops while the hub is read back after a transfer: nothing
# is recorded (the script's set -e stops there too), so the next run
# decides from what is really on both sides.
STATE_BEFORE="$(cat "$(STATEF)")"
printf 'after-read change\n' > "$CASE/local/game_1.db"
cat > "$CASE/clientstub/ssh-countdown" <<'STUB'
2
STUB
cp "$CASE/clientstub/ssh" "$CASE/clientstub/ssh.real"
cat > "$CASE/clientstub/ssh" <<STUB
#!/bin/bash
# The second hub manifest read (the one after the transfer) loses the line.
args="\$*"
case "\$args" in *"bash -s"*)
    script="\$(cat)"
    case "\$script" in *STS_UNHASHABLE*)
        n=\$(cat "$CASE/clientstub/ssh-countdown"); n=\$((n - 1)); echo "\$n" > "$CASE/clientstub/ssh-countdown"
        [ "\$n" -le 0 ] && { echo "client_loop: send disconnect" >&2; exit 255; } ;;
    esac
    printf '%s\n' "\$script" | exec "$CASE/clientstub/ssh.real" "\$@" ;;
esac
exec "$CASE/clientstub/ssh.real" "\$@"
STUB
chmod +x "$CASE/clientstub/ssh"
check "hub unreadable after the push: it fails"          1 sh -c '"$1" push >/dev/null 2>&1; [ $? -eq 0 ]' _ "$STS"
check "  and nothing was recorded"                       0 test "$(cat "$(STATEF)")" = "$STATE_BEFORE"
mv "$CASE/clientstub/ssh.real" "$CASE/clientstub/ssh"
rm -f "$CASE/clientstub/ssh-countdown"
# The push itself went through; put both sides back to what the record says.
printf 'second change\n' > "$CASE/hub/game_1.db"
printf 'second change\n' > "$CASE/local/game_1.db"

# The connection drops under the carry itself: no verdict, so no swap.
touch "$CASE/clientstub/drop-carry"
printf 'third change\n' > "$CASE/local/game_1.db"
check "client push, carry check lost: refuses (63)"     63 "$STS" push
check "  and says it could not check"                    0 sh -c '"$1" push 2>&1 | grep -q "could not check the hub.s excluded files"' _ "$STS"
check "  the hub is unchanged"                           0 test "$(cat "$CASE/hub/game_1.db")" = "second change"
check "  and still has the excluded file"                0 test "$(cat "$CASE/hub/data.db")" = hub-local
rm -f "$CASE/clientstub/drop-carry"

# A glob entry matches on the hub side too; it never did before #128.
sed -i '' 's/^SYNC_EXCLUDE=.*/SYNC_EXCLUDE=data.db steam_autocloud.vdf *.local/' "$CASE/cfg/star-traders-sync/config"
printf 'a\n' > "$CASE/hub/a.local"; printf 'b\n' > "$CASE/hub/b.local"
check "client push with a glob exclude"                  0 "$STS" push
check "  carries every match"                            0 test "$(cat "$CASE/hub/a.local" "$CASE/hub/b.local")" = "a
b"
client_off

# --------------------------------------------------------------------------
section "restore a safety copy (#90)"
newcase restore
# Saves and hub as on a real Mac, in different parents: in the sandbox they
# are siblings, and their safety copies would share one directory.
mkdir -p "$CASE/mac" && mv "$CASE/local" "$CASE/mac/local"
sed -i '' "s|^LOCAL_SAVE_PATH=.*|LOCAL_SAVE_PATH=$CASE/mac/local|" "$CASE/cfg/star-traders-sync/config"
ln -s "$CASE/mac/local" "$CASE/local"   # the shared helpers and checks use $CASE/local
SNAPS="$CASE/mac/star-traders-sync-snapshots"
check "no safety copies yet: lists none"                 0 sh -c '"$1" restore 2>&1 | grep -q "no safety copies"' _ "$STS"
check "  and --json says so too"                         0 test "$("$STS" restore --json 2>/dev/null)" = '{"snapshots": []}'
"$STS" push --force=local >/dev/null 2>&1
# The other Mac played: the hub moves on, and a pull overwrites this one.
printf 'from the other mac\n' > "$CASE/hub/game_1.db"
"$STS" pull >/dev/null 2>&1
check "the pull left a safety copy of the old saves"     0 test "$(ls "$SNAPS" | grep -c .)" -eq 1
FIRST="$(ls "$SNAPS")"
check "  restore lists it"                               0 sh -c '"$1" restore 2>&1 | grep -q "$2"' _ "$STS" "$FIRST"
check "  --json lists it with its counts"                0 sh -c '"$1" restore --json 2>/dev/null | python3 -c "
import json,sys; s=json.load(sys.stdin)[\"snapshots\"]
assert [x[\"name\"] for x in s]==[sys.argv[1]], s
assert s[0][\"files\"]>=4 and s[0][\"campaign_saves\"]==1 and s[0][\"newest\"]>0, s
" "$2"' _ "$STS" "$FIRST"

HUB_BEFORE="$(cat "$CASE/hub/game_1.db")"
printf 'machine-local, changed since\n' > "$CASE/local/data.db"
check "restore NAME"                                     0 "$STS" restore "$FIRST"
check "  this Mac has the old saves back"                0 test "$(cat "$CASE/local/game_1.db")" = "v1-game_1.db"
check "  the hub is untouched"                           0 test "$(cat "$CASE/hub/game_1.db")" = "$HUB_BEFORE"
check "  the copy restored from is still there"          0 test -d "$SNAPS/$FIRST"
check "  what was here is a new safety copy"             0 test "$(ls "$SNAPS" | grep -c .)" -eq 2
SECOND="$(ls "$SNAPS" | LC_ALL=C sort | tail -1)"
check "  holding the saves it replaced"                  0 test "$(cat "$SNAPS/$SECOND/game_1.db")" = "from the other mac"
check "  the live machine-local data.db was kept, not the copy's" 0 test "$(cat "$CASE/local/data.db")" = "machine-local, changed since"
check "  status now sees this Mac changed"               0 test "$(jget decision)" = LOCAL_ONLY
check "undo: restore the copy it made"                   0 "$STS" restore "$SECOND"
check "  back to the saves before the restore"           0 test "$(cat "$CASE/local/game_1.db")" = "from the other mac"

# Never prunes: SNAPSHOT_KEEP is 3 here. Restoring the oldest of three
# would have pruned that very copy if the restore's own snapshot pruned.
check "three safety copies now"                          0 test "$(ls "$SNAPS" | grep -c .)" -eq 3
OLDEST="$(ls "$SNAPS" | LC_ALL=C sort | head -1)"
check "restore the oldest of SNAPSHOT_KEEP"              0 "$STS" restore "$OLDEST"
check "  nothing was pruned"                             0 test "$(ls "$SNAPS" | grep -c .)" -eq 4
check "  the oldest is still there"                      0 test -d "$SNAPS/$OLDEST"

# A snapshot that fails part way never becomes a listed safety copy.
# Injected through a cpio that copies nothing, so it is about the script;
# the Go build copies natively (TestAnIncompleteSnapshotStaysHidden).
if [ -z "${STS_BIN:-}" ]; then
# cpio that copies nothing and exits 0 - what macOS cpio does through a
# symlinked parent - makes the pull's snapshot INCOMPLETE (63).
COUNT_BEFORE="$(ls "$SNAPS" | grep -c .)"
printf 'newer on the hub\n' > "$CASE/hub/game_1.db"
mkdir -p "$CASE/nocpio"; printf '#!/bin/sh\ncat >/dev/null\nexit 0\n' > "$CASE/nocpio/cpio"; chmod +x "$CASE/nocpio/cpio"
check "an incomplete snapshot refuses the pull (63)"    63 env PATH="$CASE/nocpio:$PATH" "$STS" pull --force=hub
check "  and is not listed as a safety copy"             0 test "$(ls "$SNAPS" | grep -c .)" -eq "$COUNT_BEFORE"
check "  restore --json does not offer it either"        0 sh -c '"$1" restore --json 2>/dev/null | python3 -c "import json,sys; assert len(json.load(sys.stdin)[\"snapshots\"])==int(sys.argv[1])" "$2"' _ "$STS" "$COUNT_BEFORE"
check "  the partial copy is kept aside, hidden"         0 sh -c 'ls -d "$1"/.partial-* >/dev/null 2>&1' _ "$SNAPS"
else
    printf '  skip an incomplete snapshot (script-only: injected through cpio)\n'
fi

check "a name that is a path: refused (65)"             65 "$STS" restore "../local"
check "a dotted name: refused (65)"                     65 "$STS" restore ".."
check "no such safety copy: refused (65)"               65 "$STS" restore 2001-01-01T00:00:00Z
mkdir "$SNAPS/2002-02-02T00:00:00Z"
check "an empty safety copy: refused (65)"              65 "$STS" restore 2002-02-02T00:00:00Z
rmdir "$SNAPS/2002-02-02T00:00:00Z"
check "--json with a name: usage error"                  2 "$STS" restore --json "$OLDEST"
check "--force with restore: usage error"                2 "$STS" restore --force=hub "$OLDEST"
check "two names: usage error"                           2 "$STS" restore "$OLDEST" "$SECOND"

# A stand-in game: a real binary, so pgrep -x sees its name (a copied
# system binary is killed on launch, and a script shows up as sh). The
# name stays under the 16 characters macOS keeps for a process name.
LOCAL_BEFORE="$(cat "$CASE/local/game_1.db")"
if printf '#include <unistd.h>\nint main(void){sleep(30);return 0;}\n' \
       | cc -x c - -o "$CASE/ststestgame" 2>/dev/null; then
    sed -i '' 's/^GAME_PROCESS_NAME=.*/GAME_PROCESS_NAME=ststestgame/' "$CASE/cfg/star-traders-sync/config"
    "$CASE/ststestgame" &
    GAME=$!
    sleep 0.5
    check "the game running: refused (40)"              40 "$STS" restore "$SECOND"
    check "  and nothing changed"                        0 test "$(cat "$CASE/local/game_1.db")" = "$LOCAL_BEFORE"
    kill "$GAME" 2>/dev/null; wait "$GAME" 2>/dev/null
else
    printf '  skip the game running (no C compiler here)\n'
fi

# --------------------------------------------------------------------------
section "checks do not depend on the locale"
# A bracket range in a case pattern follows the locale's collation: under
# en_US.UTF-8, the locale of an ordinary Terminal, [A-Z] matched lower case
# and [A-Za-z] matched e-acute. Found by the Go parity check on CI.
newcase locale
U=en_US.UTF-8
check "UTF-8: --expect-decision in lower case is refused"  2 env LC_ALL=$U "$STS" pull --expect-decision=hub_only
check "C: the same"                                        2 env LC_ALL=C "$STS" pull --expect-decision=hub_only
# printf builds the byte pair, so the test does not rest on sed's \x.
P="$CASE/sav$(printf '\303\251')s"
check "  (the test really writes the e-acute bytes)"        0 test "$(printf '%s' "$P" | od -An -tx1 | tr -d ' \n' | grep -c c3a9)" -eq 1
sed -i '' "s|^LOCAL_SAVE_PATH=.*|LOCAL_SAVE_PATH=$P|" "$CASE/cfg/star-traders-sync/config"
check "UTF-8: a non-ASCII letter in a path is refused (11)" 11 env LC_ALL=$U "$STS" status
check "C: the same"                                        11 env LC_ALL=C "$STS" status
# Positive control: the same config with a plain ASCII path gets past
# validation, so it is the e-acute that triggers 11.
sed -i '' "s|^LOCAL_SAVE_PATH=.*|LOCAL_SAVE_PATH=$CASE/saves|" "$CASE/cfg/star-traders-sync/config"
check "UTF-8: the ASCII path passes validation (13, missing)" 13 env LC_ALL=$U "$STS" status
sed -i '' "s|^LOCAL_SAVE_PATH=.*|LOCAL_SAVE_PATH=$CASE/local|; s|^SSH_PORT=.*||" "$CASE/cfg/star-traders-sync/config"
printf 'SSH_PORT=\xc2\xb2\n' >> "$CASE/cfg/star-traders-sync/config"
check "UTF-8: a superscript digit is not a number (11)"    11 env LC_ALL=$U "$STS" status

# --------------------------------------------------------------------------
section "a failed hub snapshot never passes for a good one (#156)"
newcase hubsnap
"$STS" push --force=local >/dev/null 2>&1
HS="$CASE/star-traders-sync-snapshots"
# The hub and the saves are siblings in the sandbox: count only what a push
# adds, before and after.
BEFORE="$(ls "$HS" 2>/dev/null | grep -c .)"
printf 'changed\n' > "$CASE/local/game_1.db"
mkdir -p "$CASE/nocpio"; printf '#!/bin/sh\ncat >/dev/null\nexit 0\n' > "$CASE/nocpio/cpio"; chmod +x "$CASE/nocpio/cpio"
check "a hub snapshot that copied nothing: push refuses (63)" 63 env PATH="$CASE/nocpio:$PATH" "$STS" push
check "  the hub is unchanged"                           0 test "$(cat "$CASE/hub/game_1.db")" = "v1-game_1.db"
check "  the partial snapshot is not listed"             0 test "$(ls "$HS" | grep -c .)" -eq "$BEFORE"
check "  it is kept aside, hidden"                       0 sh -c 'ls -d "$1"/.partial-* >/dev/null 2>&1' _ "$HS"
printf 'changed again\n' > "$CASE/local/game_1.db"
check "the next push snapshots and goes"                 0 "$STS" push
printf 'and again\n' > "$CASE/local/game_1.db"
check "  and says where the snapshot really is"          0 sh -c 'p="$("$1" push 2>&1 | sed -n "s/^snapshot: \(.*\) (on .*)$/\1/p")"; [ -d "$p" ]' _ "$STS"
check "  with two more listed snapshots"                 0 test "$(ls "$HS" | grep -c .)" -eq $((BEFORE + 2))

# --------------------------------------------------------------------------
section "a same-size change in the same second is still sent (#158)"
# rsync's quick check (size and whole-second mtime) took these for
# unchanged and hard-linked the old copy in: the push "completed", the hub
# kept the old save, and the next sync was DIVERGED_STATE.
newcase samesecond
"$STS" push --force=local >/dev/null 2>&1
printf 'v2-game_1.db\n' > "$CASE/local/game_1.db"          # the same size as v1-game_1.db
touch -r "$CASE/hub/game_1.db" "$CASE/local/game_1.db"     # and the same mtime
check "push sends it"                                    0 "$STS" push
check "  the hub has it"                                 0 test "$(cat "$CASE/hub/game_1.db")" = "v2-game_1.db"
check "  in sync afterwards"                             0 test "$(jget decision)" = INSYNC
printf 'v3-game_1.db\n' > "$CASE/hub/game_1.db"            # the other Mac, same size again
touch -r "$CASE/local/game_1.db" "$CASE/hub/game_1.db"
check "pull fetches it"                                  0 "$STS" pull
check "  this Mac has it"                                0 test "$(cat "$CASE/local/game_1.db")" = "v3-game_1.db"

# Whatever a transfer did, both sides must match afterwards, or it did not
# happen: an rsync that "succeeds" but leaves one file different.
mkdir -p "$CASE/badrsync"
cat > "$CASE/badrsync/rsync" <<'STUB'
#!/bin/sh
/usr/bin/rsync "$@" || exit $?
for last; do :; done
f="$(find "${last%/}" -name 'game_1.db' 2>/dev/null | head -1)"
[ -n "$f" ] && printf 'corrupted\n' >> "$f"
exit 0
STUB
chmod +x "$CASE/badrsync/rsync"
printf 'v4-game_1.db\n' > "$CASE/local/game_1.db"
PATH="$CASE/badrsync:$PATH" "$STS" push > "$CASE/bad.out" 2>&1; BADRC=$?
check "a transfer that leaves the sides different: push fails (33)" 0 test "$BADRC" -eq 33
check "  and says it did not really happen"              0 grep -q "did not really happen" "$CASE/bad.out"
check "  nothing syncs on its own: DIVERGED_STATE"       0 test "$(jget decision)" = DIVERGED_STATE
# The documented way out (troubleshooting row 57, as row 46): --force alone
# is refused; move the record aside, then force the side that is right.
check "  --force alone is still refused (60)"            60 "$STS" push --force=local
mv "$(STATEF)" "$(STATEF).aside"
check "  after the record is moved aside, --force=local goes" 0 "$STS" push --force=local
check "  and both sides match"                           0 test "$(jget decision)" = INSYNC
check "  with this Mac's save on the hub"                0 test "$(cat "$CASE/hub/game_1.db")" = "v4-game_1.db"

# The same over ssh, from a client: same size, same second, still sent.
newcase samesecondclient
client_on
"$STS" push --force=local >/dev/null 2>&1
printf 'v2-game_1.db\n' > "$CASE/local/game_1.db"
touch -r "$CASE/hub/game_1.db" "$CASE/local/game_1.db"
check "client: push over ssh sends it"                   0 "$STS" push
check "  the hub has it"                                 0 test "$(cat "$CASE/hub/game_1.db")" = "v2-game_1.db"
printf 'v3-game_1.db\n' > "$CASE/hub/game_1.db"
touch -r "$CASE/local/game_1.db" "$CASE/hub/game_1.db"
check "client: pull over ssh fetches it"                 0 "$STS" pull
check "  this Mac has it"                                0 test "$(cat "$CASE/local/game_1.db")" = "v3-game_1.db"
client_off

# --------------------------------------------------------------------------
section "play never runs on an emptied save folder (#126)"
newcase playemptied
"$STS" push --force=local >/dev/null 2>&1
printf 'GAME_START_TIMEOUT=2\n' >> "$CASE/cfg/star-traders-sync/config"
mkdir -p "$CASE/nosteam"
# A stub 'open' that records it was asked to launch the game.
printf '#!/bin/sh\ntouch "%s/launched"\nexit 0\n' "$CASE" > "$CASE/nosteam/open"
chmod +x "$CASE/nosteam/open"
HUB_BEFORE="$(cat "$CASE/hub/game_1.db")"
rm -f "$CASE/local"/*.db "$CASE/local"/*.json
check "emptied after a sync: decision is LOCAL_EMPTIED"  0 test "$(jget decision)" = LOCAL_EMPTIED
check "play refuses (61), not 'ahead of the hub'"       61 env PATH="$CASE/nosteam:$PATH" "$STS" play
check "  and never launched the game"                    1 test -f "$CASE/launched"
check "  and left the Hub alone"                         0 test "$(cat "$CASE/hub/game_1.db")" = "$HUB_BEFORE"
# Captured to a file, not piped into grep -q: grep stops reading at its
# first match, and play then dies of SIGPIPE before releasing the hub
# lock, which the next case finds still held (CI saw exit 50).
check "  and says how to restore"                        0 sh -c 'PATH="$2:$PATH" "$1" play >"$3" 2>&1; grep -q "pull --force=hub" "$3"' _ "$STS" "$CASE/nosteam" "$CASE/play.out"
check "pull --force=hub restores"                        0 "$STS" pull --force=hub
check "  after which: INSYNC"                            0 test "$(jget decision)" = INSYNC

# --------------------------------------------------------------------------
section "play when only this machine changed (#99)"
newcase playahead
"$STS" push --force=local >/dev/null 2>&1
# No Steam in the sandbox: 'open' does nothing and the game never starts,
# so play ends with 41 once it is past the pull. Before #99 it stopped at
# the pull with 60.
printf 'GAME_START_TIMEOUT=2\n' >> "$CASE/cfg/star-traders-sync/config"
mkdir -p "$CASE/nosteam"
printf '#!/bin/sh\nexit 0\n' > "$CASE/nosteam/open"
chmod +x "$CASE/nosteam/open"
printf 'ahead\n' > "$CASE/local/game_1.db"
HUB_BEFORE="$(cat "$CASE/hub/game_1.db")"
check "decision is LOCAL_ONLY"                           0 test "$(jget decision)" = LOCAL_ONLY
check "play gets past the pull (41: no game here), not 60" 41 env PATH="$CASE/nosteam:$PATH" "$STS" play
check "  and says why it did not fetch"                  0 sh -c 'PATH="$2:$PATH" "$1" play 2>&1 | grep -q "ahead of the hub - nothing to fetch"' _ "$STS" "$CASE/nosteam"
check "  and left this machine's change alone"           0 test "$(cat "$CASE/local/game_1.db")" = ahead
check "  and the hub alone"                              0 test "$(cat "$CASE/hub/game_1.db")" = "$HUB_BEFORE"
check "plain pull still refuses LOCAL_ONLY"             60 "$STS" pull
check "and push still sends it"                          0 "$STS" push
check "  after which: INSYNC"                            0 test "$(jget decision)" = INSYNC

# --------------------------------------------------------------------------
section "backup"
newcase backup
"$STS" push --force=local >/dev/null 2>&1
check "backup refuses a non-mount-point volume"         70 "$STS" backup
# The refusal comes after the hub lock is taken: every way out must release
# it, or the other Mac is locked out until the TTL.
check "  and releases the hub lock it took"              1 test -e "$CASE/.sts-lock"
check "  so a push straight after is not refused"        0 "$STS" push
# Waiting for the disk must not hold the hub: the other Mac would be locked
# out for all of BACKUP_MOUNT_WAIT, every night the disk is unplugged (#169).
printf 'BACKUP_MOUNT_WAIT=5\n' >> "$CASE/cfg/star-traders-sync/config"
"$STS" backup >/dev/null 2>&1 & BPID=$!
sleep 2
check "  waiting for the disk does not hold the hub lock" 1 test -e "$CASE/.sts-lock"
wait "$BPID"; BRC=$?
check "  and still refuses when it never mounts"         0 test "$BRC" = 70
sed -i '' '/^BACKUP_MOUNT_WAIT=/d' "$CASE/cfg/star-traders-sync/config"

# A same-size change in the same second reaches the next backup too (#158):
# backup hard-links unchanged files against the previous one, and rsync's
# quick check used to take this for unchanged. Needs a real mount point, so
# a small disk image; skipped, saying so, where one cannot be attached.
hdiutil create -quiet -size 20m -fs HFS+ -volname STSB "$CASE/v.dmg" 2>/dev/null
ATTACHED=0
for i in 1 2 3; do
    hdiutil attach -quiet -nobrowse -mountpoint "$CASE/vol" "$CASE/v.dmg" 2>/dev/null && { ATTACHED=1; break; }
    sleep 2
done
if [ "$ATTACHED" -eq 1 ]; then
    sed -i '' "s|^HUB_HOST=.*|HUB_HOST=$(hostname -s)|" "$CASE/cfg/star-traders-sync/config"
    check "backup to a mounted volume"                     0 "$STS" backup
    FIRSTB="$(ls "$CASE/vol/b" | grep -v '^\.' | head -1)"
    printf 'v2-game_1.db\n' > "$CASE/hub/game_1.db"          # same size
    touch -r "$CASE/vol/b/$FIRSTB/game_1.db" "$CASE/hub/game_1.db"   # same mtime
    sleep 1                                                 # a second, distinct backup name
    check "  a second backup"                              0 "$STS" backup
    LASTB="$(ls "$CASE/vol/b" | grep -v '^\.' | tail -1)"
    check "  holds the same-size, same-second change"      0 test "$(cat "$CASE/vol/b/$LASTB/game_1.db")" = "v2-game_1.db"
    # A backup that cannot be marked complete never joins the rotation, and
    # nothing would ever remove it: refuse, and remove it now. A directory
    # in the way of the marker is the reproducible way to fail that write.
    BEFORE_N="$(ls "$CASE/vol/b" | grep -vc '^\.')"
    mkdir "$CASE/hub/.sts-complete"
    sleep 1
    check "  an unmarkable backup is refused"              33 "$STS" backup
    check "  and removed, not left unmarked"               0 test "$(ls "$CASE/vol/b" | grep -vc '^\.')" = "$BEFORE_N"
    rmdir "$CASE/hub/.sts-complete"
    hdiutil detach -quiet "$CASE/vol" 2>/dev/null || hdiutil detach -quiet -force "$CASE/vol" 2>/dev/null
else
    printf '  skip backup to a mounted volume (no disk image could be attached here)\n'
fi

# The suite must leave nothing behind outside its sandbox. doctor --fix can
# append to a shell rc, so this is not hypothetical.
if [ -n "$(find "$REAL_HOME" -maxdepth 1 -name '.zshrc.sts-backup' -newer "$SB" 2>/dev/null)" ]; then
    printf '\n  FAIL the suite modified %s/.zshrc\n' "$REAL_HOME"
    FAIL=$((FAIL + 1))
else
    PASS=$((PASS + 1))
    printf '  ok   the suite left the real home untouched\n'
fi

if [ "$SKIPPED" -gt 0 ]; then
    printf '\n%s: %s passed, %s failed, %s skipped (STS_SKIP=%s)\n' "$(basename "$0")" "$PASS" "$FAIL" "$SKIPPED" "$STS_SKIP"
else
    printf '\n%s: %s passed, %s failed\n' "$(basename "$0")" "$PASS" "$FAIL"
fi
[ "$FAIL" -eq 0 ]
