#!/bin/bash
#
# Installs star-traders-sync into ~/bin and creates the config directory.
# Safe to re-run: symlinks are refreshed, an existing config is never
# touched. Run it from anywhere; it locates the repo from its own path.

set -euo pipefail

PROG="star-traders-sync"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$REPO_DIR/bin/$PROG"
BIN_DIR="$HOME/bin"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/$PROG"
CONFIG_FILE="$CONFIG_DIR/config"
EXAMPLE="$REPO_DIR/config.example"

fail() { printf 'install: error: %s\n' "$*" >&2; exit 1; }
note() { printf 'install: %s\n' "$*"; }

[ "$(id -u)" -ne 0 ] || fail "do not run this as root - it installs into your own home"
[ -f "$SRC" ] || fail "$SRC not found - is the repo intact?"
[ -f "$EXAMPLE" ] || fail "$EXAMPLE not found - is the repo intact?"

chmod +x "$SRC"

mkdir -p "$BIN_DIR"

# Refresh both the full name and the short alias. ln -sfn so re-running is
# idempotent and so an existing symlink is replaced rather than nested.
for name in "$PROG" sts; do
    target="$BIN_DIR/$name"
    if [ -e "$target" ] && [ ! -L "$target" ]; then
        fail "$target exists and is not a symlink - refusing to replace a real file"
    fi
    ln -sfn "$SRC" "$target"
    note "linked $target -> $SRC"
done

mkdir -p "$CONFIG_DIR"
note "config directory $CONFIG_DIR"

if [ -e "$CONFIG_FILE" ]; then
    note "config already exists at $CONFIG_FILE - left untouched"
    note "compare it against $EXAMPLE if you want new keys"
else
    cp "$EXAMPLE" "$CONFIG_FILE"
    note "config created at $CONFIG_FILE from config.example"
    note "EDIT IT before running $PROG - at minimum HUB_HOST, HUB_USER, HUB_PATH,"
    note "LOCAL_SAVE_PATH, BACKUP_VOLUME and BACKUP_DEST"
fi

# ~/bin on PATH is a warning, never a failure.
case ":$PATH:" in
    *":$BIN_DIR:"*)
        note "$BIN_DIR is on your PATH" ;;
    *)
        printf '\n'
        printf 'install: WARNING: %s is not on your PATH.\n' "$BIN_DIR" >&2
        printf 'install: The tool is installed but "sts" will not resolve.\n' >&2
        printf 'install: Add this to your shell rc (~/.zshrc for zsh):\n' >&2
        printf '\n    export PATH="$HOME/bin:$PATH"\n\n' >&2
        printf 'install: then open a new shell, or run: export PATH="$HOME/bin:$PATH"\n' >&2
        ;;
esac

printf '\n'
note "installed. Next:"
note "  1. edit $CONFIG_FILE"
note "  2. sts status        (read-only, changes nothing)"
note "  3. sts --help        (every exit code is listed)"
