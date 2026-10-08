#!/bin/bash
#
# star-traders-sync, as installed by the app: picks the engine and execs it
# (#175). Every caller - the app, ~/bin/sts, the backup launcher - runs
# this file by its old path, so none of them changes, and exec keeps the
# launcher as the responsible process for its Full Disk Access grant.
#
# The engine: $STS_ENGINE, else the first word of
# ~/.config/star-traders-sync/engine. "bash" (exactly) runs the script; anything else,
# including no choice at all, runs the Go build beside this file (#26). Go
# back to the script with:
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
if [ -z "$engine" ]; then
    # Braced: a missing file fails the < itself, before a 2> on read applies.
    { read -r engine _ < "${XDG_CONFIG_HOME:-$HOME/.config}/star-traders-sync/engine"; } 2>/dev/null || true
fi

if [ "$engine" != "bash" ]; then
    if [ -x "$dir/star-traders-sync-go" ]; then
        exec -a "$0" "$dir/star-traders-sync-go" "$@"
    fi
    printf 'warning: the Go build %s is missing - running the script\n' "$dir/star-traders-sync-go" >&2
fi
exec -a "$0" /bin/bash "$dir/star-traders-sync.bash" "$@"
