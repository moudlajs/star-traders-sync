#!/bin/bash
#
# Installs star-traders-sync into ~/bin and writes a working config.
# Safe to re-run: symlinks are refreshed, an existing config is never touched.

set -euo pipefail

PROG="star-traders-sync"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$REPO_DIR/bin/$PROG"
BIN_DIR="$HOME/bin"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/$PROG"
CONFIG_FILE="$CONFIG_DIR/config"
EXAMPLE="$REPO_DIR/config.example"

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || fail "do not run this as root - it installs into your own home"
[ -f "$SRC" ]     || fail "$SRC not found - is the repo intact?"
[ -f "$EXAMPLE" ] || fail "$EXAMPLE not found - is the repo intact?"

chmod +x "$SRC"
mkdir -p "$BIN_DIR" "$CONFIG_DIR"

for name in "$PROG" sts; do
    target="$BIN_DIR/$name"
    if [ -e "$target" ] && [ ! -L "$target" ]; then
        fail "$target exists and is not a symlink - refusing to replace a real file"
    fi
    ln -sfn "$SRC" "$target"
done
printf '  linked %s and sts into %s\n' "$PROG" "$BIN_DIR"

CONFIG_CREATED=0
if [ -e "$CONFIG_FILE" ]; then
    printf '  config already present, left untouched\n'
else
    # A short starting config, not the 100-line annotated reference.
    # Only the four HUB_/BACKUP_ values need changing; LOCAL_SAVE_PATH uses
    # ~/ so it expands per-user, and the game values are already correct.
    # config.example documents every tunable and its default.
    cat > "$CONFIG_FILE" <<CFGEOF
# star-traders-sync config.
# Every option, explained, with defaults:
#   $EXAMPLE

HUB_HOST=hub-tailnet-name
HUB_USER=youruser
HUB_PATH=/Users/youruser/star-traders-sync-hub

LOCAL_SAVE_PATH=~/Library/StarTradersFrontiers
SYNC_EXCLUDE=data.db steam_autocloud.vdf

STEAM_APPID=335620
GAME_PROCESS_NAME=StarTradersFrontiers

BACKUP_VOLUME=/Volumes/YourDisk
BACKUP_DEST=/Volumes/YourDisk/Backups/star-traders-sync
CFGEOF
    CONFIG_CREATED=1
    printf '  config written to %s\n' "$CONFIG_FILE"
fi

print_next_steps() {
    if [ "$CONFIG_CREATED" -eq 1 ]; then
        printf 'Edit %s - five values:\n\n' "$CONFIG_FILE"
        printf '    HUB_HOST       tailscale node name of the machine hosting the hub\n'
        printf '                   (see: tailscale status)\n'
        printf '    HUB_USER       your account name ON THAT machine\n'
        printf '    HUB_PATH       absolute path for the hub dir on that machine\n'
        printf '    BACKUP_VOLUME  mount point of your external backup disk\n'
        printf '    BACKUP_DEST    where backups go, under BACKUP_VOLUME\n\n'
        printf 'The rest is already correct. Then:\n\n'
    else
        printf 'Next:\n\n'
    fi
    printf '    sts status        read-only, changes nothing\n'
    printf '    sts --help        every exit code explained\n'
}

printf '\n'
case ":$PATH:" in
    *":$BIN_DIR:"*)
        print_next_steps
        ;;
    *)
        printf '%s is not on your PATH yet. Run this first:\n\n' "$BIN_DIR"
        printf '    echo '\''export PATH="$HOME/bin:$PATH"'\'' >> ~/.zshrc && exec zsh\n\n'
        print_next_steps
        ;;
esac
