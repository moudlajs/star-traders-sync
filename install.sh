#!/bin/bash
#
# Installs star-traders-sync into ~/bin and writes a working config.
# Safe to re-run: symlinks are refreshed, an existing config is never touched.
#
#   ./install.sh            the Go build behind the engine launcher, as the
#                           app installs it (#183). Re-run after git pull.
#   ./install.sh --script   a plain link to the bash script, as before
#
# The Go build comes from `go build` when Go is installed, otherwise from
# the release matching this checkout, refused unless its checksum matches.

set -euo pipefail

PROG="star-traders-sync"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$REPO_DIR/bin/$PROG"
BIN_DIR="$HOME/bin"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/$PROG"
CONFIG_FILE="$CONFIG_DIR/config"
EXAMPLE="$REPO_DIR/config.example"

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

MODE=go
case "${1:-}" in
    "")       ;;
    --script) MODE=script ;;
    *)        fail "unknown argument '$1' - use --script, or nothing" ;;
esac
# Overridable for the regression suite, which must not write into the repo.
INSTALL_DIR="${STS_INSTALL_DIR:-$REPO_DIR/build/bin}"
RELEASE_URL="${STS_RELEASE_URL:-https://github.com/moudlajs/star-traders-sync/releases/download}"
GO_ASSET="star-traders-sync-go-darwin-universal"

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
done

# The Go build and the launcher, staged beside their final place and moved
# in only once the binary has proved it runs and is this version. Any
# failure stops here, before ~/bin is touched.
install_go() {
    local version go
    version="$(grep -oE '^readonly STS_VERSION="[^"]+"' "$SRC" | cut -d'"' -f2 || true)"
    [ -n "$version" ] || fail "could not read STS_VERSION from $SRC"
    mkdir -p "$INSTALL_DIR"
    # Global: the EXIT trap fires after this function's locals are gone.
    STAGE="$(mktemp -d "$INSTALL_DIR/.stage.XXXXXX")"
    trap 'rm -rf "${STAGE:-}"' EXIT
    go="$STAGE/$PROG-go"

    if [ -z "${STS_INSTALL_DOWNLOAD:-}" ] && command -v go >/dev/null 2>&1; then
        printf '  building the Go engine with %s\n' "$(go version | cut -d' ' -f3)"
        (cd "$REPO_DIR" && CGO_ENABLED=0 go build -trimpath -o "$go" ./cmd/sts) \
            || fail "go build failed - fix it, or run: ./install.sh --script"
    else
        local url="$RELEASE_URL/v$version/$GO_ASSET" want got
        printf '  downloading the Go engine for %s\n' "$version"
        curl -fsSL -o "$go" "$url" && curl -fsSL -o "$STAGE/sha" "$url.sha256" \
            || fail "could not download $url - no Go build for $version yet? Install Go (brew install go), or run: ./install.sh --script"
        want="$(cut -d' ' -f1 < "$STAGE/sha")"
        got="$(shasum -a 256 "$go" | cut -d' ' -f1)"
        [ -n "$want" ] && [ "$want" = "$got" ] \
            || fail "the downloaded Go build does not match its checksum ($got, expected $want) - not installed"
        chmod 755 "$go"
    fi
    [ "$("$go" --version 2>/dev/null)" = "$PROG $version" ] \
        || fail "the Go build does not run, or is not version $version - not installed"

    sed "s/@STS_VERSION@/$version/" "$REPO_DIR/macos/engine-shim.sh" > "$STAGE/$PROG"
    chmod 755 "$STAGE/$PROG"
    # The script itself is linked, not copied: git pull keeps the fallback
    # current. Engines first, the launcher last.
    ln -sfn "$SRC" "$INSTALL_DIR/$PROG.bash"
    mv -f "$go" "$INSTALL_DIR/$PROG-go"
    mv -f "$STAGE/$PROG" "$INSTALL_DIR/$PROG"
    LINK_TO="$INSTALL_DIR/$PROG"
}

STAGE=""
LINK_TO="$SRC"
[ "$MODE" = go ] && install_go
for name in "$PROG" sts; do
    ln -sfn "$LINK_TO" "$BIN_DIR/$name"
done
printf '  linked %s and sts into %s (%s)\n' "$PROG" "$BIN_DIR" \
    "$([ "$MODE" = go ] && echo "the Go engine, the script as fallback" || echo "the script")"

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

HUB_HOST=your-hub-tailnet-name
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
