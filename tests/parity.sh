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

# accepted NAME - a config both accept: neither gives a config code
# (10-12), and both stop at the same next check with the same words.
accepted() {
    local name="$1"
    compare "$name" status
    case "$(tail -1 "$SB/b.err" 2>/dev/null)" in
        *"exit code 1"[012]" "*) FAIL=$((FAIL + 1)); printf '  FAIL %s: refused as a config error\n' "$name" ;;
    esac
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

# --------------------------------------------------------------------------
# status: both read the same sandbox through a tailscale stub, and must
# print the same text and the same JSON.
echo "status"
ME="$(hostname -s | tr '[:upper:]' '[:lower:]')"
mkdir -p "$SB/stub"
# TS_MODE picks what the stub says: hub (this Mac is the hub), down,
# notjson, missing (hub not in the tailnet), offline, pingfail.
cat > "$SB/stub/tailscale" <<STUB
#!/bin/bash
mode="\$(cat "$SB/stub/mode" 2>/dev/null || echo hub)"
case "\$*" in
    *"status --json"*)
        case "\$mode" in
            down)    echo "failed to connect to local backend" >&2; exit 1 ;;
            notjson) echo "Tailscale is stopped." ; exit 0 ;;
            missing) printf '{"BackendState":"Running","Self":{"HostName":"elsewhere","DNSName":"elsewhere.t.ts.net.","TailscaleIPs":["100.64.0.9"],"Online":true},"Peer":{}}\n' ;;
            offline|pingfail) printf '{"BackendState":"Running","Self":{"HostName":"elsewhere","DNSName":"elsewhere.t.ts.net.","TailscaleIPs":["100.64.0.9"],"Online":true},"Peer":{"p":{"HostName":"$ME","DNSName":"$ME.t.ts.net.","TailscaleIPs":["100.64.0.1"],"Online":\$([ "\$mode" = offline ] && echo false || echo true)}}}\n' ;;
            *)       printf '{"BackendState":"Running","Self":{"HostName":"$ME","DNSName":"$ME.t.ts.net.","TailscaleIPs":["100.64.0.1"],"Online":true},"Peer":{}}\n' ;;
        esac ;;
    *ping*) [ "\$mode" = pingfail ] && { echo "no reply"; exit 1; }; echo pong ;;
esac
exit 0
STUB
printf '#!/bin/sh\nexit 1\n' > "$SB/stub/ping"   # MagicDNS never resolves here: the IP path
chmod +x "$SB/stub/tailscale" "$SB/stub/ping"
export PATH="$SB/stub:$PATH" STS_TS_APP_PATH=/nonexistent/Tailscale
tsmode() { echo "$1" > "$SB/stub/mode"; }

S="$SB/s"
fresh() {   # a sandbox Mac that is its own hub, with four saves
    rm -rf "$S" "$XDG_STATE_HOME"; mkdir -p "$S/local" "$S/hub" "$S/vol/b"
    config "HUB_HOST=$ME\nHUB_USER=$(whoami)\nHUB_PATH=$S/hub\nLOCAL_SAVE_PATH=$S/local\nSTEAM_APPID=335620\nGAME_PROCESS_NAME=ststestgame\nSYNC_EXCLUDE=data.db steam_autocloud.vdf\nBACKUP_VOLUME=$S/vol\nBACKUP_DEST=$S/vol/b\n"
    for f in core.db game_1.db map_1.db template_1.json; do printf 'v1-%s\n' "$f" > "$S/local/$f"; done
    printf 'static\n' > "$S/local/data.db"
    tsmode hub
}
both() {   # compare status and status --json in this state
    compare "$1" status
    compare "$1, --json" status --json
}
fresh;                                                   both "first run, hub empty"
"$BASH_STS" push --force=local >/dev/null 2>&1;          both "in sync"
printf 'other mac\n' > "$S/hub/game_1.db";               both "only the hub changed"
"$BASH_STS" pull >/dev/null 2>&1; printf 'here\n' > "$S/local/game_1.db"; both "only this Mac changed"
printf 'there\n' > "$S/hub/game_1.db";                   both "both changed"
rm -f "$S/local"/*.db "$S/local"/*.json;                 both "this Mac emptied after a sync"
fresh; "$BASH_STS" push --force=local >/dev/null 2>&1; rm -f "$XDG_STATE_HOME/star-traders-sync/last-sync.json"
printf 'mine\n' > "$S/local/game_1.db";                  both "first run, both have saves"
fresh; "$BASH_STS" push --force=local >/dev/null 2>&1; rm -f "$S/hub"/*;   both "the hub emptied after a sync"
fresh; mkdir "$S/.sts-lock"; printf 'otherhost\n1234\n2026-10-06T12:00:00Z\n' > "$S/.sts-lock/owner"
"$BASH_STS" push --force=local >/dev/null 2>&1;          compare "hub lock held (shown)" status
rm -rf "$S/.sts-lock"

echo "status refusals"
fresh; rm -rf "$S/hub";                                  compare "hub path missing (14)" status
mkdir "$S/hub.sts-old-123";                              compare "hub swap interrupted (14)" status
rm -rf "$S/hub.sts-old-123"; : > "$S/hub";               compare "hub path not a directory (14)" status
fresh; rm -rf "$S/local";                                compare "save folder missing (13)" status
mkdir "$S/local.sts-old-9";                              compare "save folder swap interrupted (13)" status
fresh; chmod 000 "$S/local/map_1.db";                    compare "an unreadable save (13)" status
chmod 644 "$S/local/map_1.db"
fresh; mv "$S/local" "$S/real"; ln -s "$S/real" "$S/local"; compare "a symlinked save folder" status --json
fresh; mkdir -p "$XDG_STATE_HOME/star-traders-sync/local.lock.d"; echo $$ > "$XDG_STATE_HOME/star-traders-sync/local.lock"
                                                         compare "another run holds the local lock (52)" status
fresh; tsmode down;                                      compare "tailscaled down (21)" status
tsmode notjson;                                          compare "tailscale not connected (22)" status
tsmode missing;                                          compare "the hub not in the tailnet (24)" status
tsmode offline;                                          compare "the hub offline (25)" status
compare "the hub offline, --offline-ok is play only" status --offline-ok
tsmode pingfail;                                         compare "tailscale ping fails (26)" status
tsmode hub
unset STS_TS_APP_PATH

echo
echo "parity.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
