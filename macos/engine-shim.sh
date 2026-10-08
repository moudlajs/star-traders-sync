#!/bin/bash
# star-traders-sync engine shim: runs the Go build ($STS_ENGINE or the engine file: go/unset) or the bash script.
# Go back to the script with:  echo bash > ~/.config/star-traders-sync/engine
# exec keeps the backup launcher the responsible process for its Full Disk Access grant.
readonly STS_VERSION="@STS_VERSION@"

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

# execfail: a Go build that cannot run returns here and falls back, instead of ending the shell.
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
        # Likely a mistyped rollback: the script is the safer guess.
        printf 'warning: engine "%s" is not go or bash (from %s) - running the script\n' \
            "$engine" "$from" >&2
        printf '         to keep the script: echo bash > %s\n' \
            "${XDG_CONFIG_HOME:-$HOME/.config}/star-traders-sync/engine" >&2 ;;
esac
exec -a "$0" /bin/bash "$dir/star-traders-sync.bash" "$@"
