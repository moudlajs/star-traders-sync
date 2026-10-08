#!/bin/bash
#
# star-traders-sync, as installed by the app: picks the engine and execs it
# (#175). Every caller - the app, ~/bin/sts, the backup launcher - runs
# this file by its old path, so none of them changes, and exec keeps the
# launcher as the responsible process for its Full Disk Access grant.
#
# The engine: $STS_ENGINE, else the first word of
# ~/.config/star-traders-sync/engine. "go", or no choice at all, runs the Go
# build beside this file (#26); "bash" runs the script; anything else warns
# and runs the script. Go back to the script with:
#     echo bash > ~/.config/star-traders-sync/engine
#
# build-app.sh stamps the version below, which the app reads.
readonly STS_VERSION="@STS_VERSION@"

# This file's real directory: ~/bin/sts is a symlink to it.
self="$0"
while [ -L "$self" ]; do
    target="$(readlink "$self")"
    case "$target" in
        /*) self="$target" ;;
        *)  self="$(dirname "$self")/$target" ;;
    esac
done
dir="$(cd "$(dirname "$self")" && pwd -P)"

engine="${STS_ENGINE:-}"
from="STS_ENGINE"
if [ -z "$engine" ]; then
    from="${XDG_CONFIG_HOME:-$HOME/.config}/star-traders-sync/engine"
    # Braced: a missing file fails the < itself, before a 2> on read applies.
    { read -r engine _ < "$from"; } 2>/dev/null || true
fi

# A failed exec would otherwise end the shell here: with execfail it
# returns, and a Go build that is present but cannot run (truncated by an
# interrupted install, wrong architecture) falls back like a missing one.
shopt -s execfail
case "$engine" in
    ""|go)
        if [ -x "$dir/star-traders-sync-go" ]; then
            exec -a "$0" "$dir/star-traders-sync-go" "$@"
            printf 'warning: the Go build %s could not run - running the script\n' "$dir/star-traders-sync-go" >&2
        else
            printf 'warning: the Go build %s is missing - running the script\n' "$dir/star-traders-sync-go" >&2
        fi ;;
    bash) ;;
    *)
        # Most likely a rollback typed slightly wrong: the script is the
        # safer guess, and the warning says how to make it stick.
        printf 'warning: engine "%s" is not go or bash (from %s) - running the script\n' \
            "$engine" "$from" >&2 ;;
esac
exec -a "$0" /bin/bash "$dir/star-traders-sync.bash" "$@"
