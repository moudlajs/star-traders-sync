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
sed -n '/^stable_host_id() {/,/^}/p' "$STS" > "$RACE"
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
sed -n '/^shq() {/,/^}/p; /^hub_exec_args() {/,/^}/p' "$STS" > "$INJ"
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

printf '99999\n' > "$CASE/state/star-traders-sync/local.lock"
check "a dead owner's lock is reported stale"            0 sh -c '"$1" doctor 2>&1 | grep -q "owner 99999 is gone"' _ "$STS"
check "  but not cleared without --fix"                  0 test -d "$CASE/state/star-traders-sync/local.lock.d"
"$STS" doctor --fix >/dev/null 2>&1 || true
check "  and cleared with --fix"                         1 test -d "$CASE/state/star-traders-sync/local.lock.d"

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

# Our own lock, fresh (well under the TTL), whose run has exited. It used to
# block this machine for the whole TTL.
mkdir -p "$CASE/.sts-lock"
printf '%s\n%s\n2026-01-01T00:00:00Z\n%s\nnonce\n%s\n' \
    "$(hostname -s)" "$DEAD" "$NOW" "$MYID" > "$CASE/.sts-lock/owner"
check "own fresh lock, owner pid dead: cleared"          0 "$STS" pull
check "  lock released"                                  1 test -d "$CASE/.sts-lock"

# Same, but the owner is alive: that run may be mid-transfer. Never cleared.
mkdir -p "$CASE/.sts-lock"
printf '%s\n%s\n2026-01-01T00:00:00Z\n%s\nnonce\n%s\n' \
    "$(hostname -s)" "$$" "$NOW" "$MYID" > "$CASE/.sts-lock/owner"
check "own fresh lock, owner pid alive: refused"        50 "$STS" pull
check "  and not cleared"                                0 test -d "$CASE/.sts-lock"

# Our id but another hostname (a cloned disk): its pid means nothing in this
# machine's process table, so only the TTL may clear it.
printf 'some-old-hostname\n%s\n2026-01-01T00:00:00Z\n%s\nnonce\n%s\n' \
    "$DEAD" "$NOW" "$MYID" > "$CASE/.sts-lock/owner"
check "own id, other hostname, dead pid: refused"       50 "$STS" pull
check "  and not cleared"                                0 test -d "$CASE/.sts-lock"
rm -rf "$CASE/.sts-lock"

# A reader that goes away mid-run (`sts play | head -1`). The lock must be
# gone the moment sts exits, not merely cleared by the next run.
printf 'GAME_START_TIMEOUT=2\n' >> "$CASE/cfg/star-traders-sync/config"
mkdir -p "$CASE/nosteam"
printf '#!/bin/sh\nexit 0\n' > "$CASE/nosteam/open"
chmod +x "$CASE/nosteam/open"
printf 'ahead\n' > "$CASE/local/game_1.db"
sh -c 'PATH="$2:$PATH" "$1" play 2>&1 | head -c 1 >/dev/null' _ "$STS" "$CASE/nosteam"
check "play into a closed pipe: no hub lock left"        1 test -d "$CASE/.sts-lock"
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

# The suite must leave nothing behind outside its sandbox. doctor --fix can
# append to a shell rc, so this is not hypothetical.
if [ -n "$(find "$REAL_HOME" -maxdepth 1 -name '.zshrc.sts-backup' -newer "$SB" 2>/dev/null)" ]; then
    printf '\n  FAIL the suite modified %s/.zshrc\n' "$REAL_HOME"
    FAIL=$((FAIL + 1))
else
    PASS=$((PASS + 1))
    printf '  ok   the suite left the real home untouched\n'
fi

printf '\n%s: %s passed, %s failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
