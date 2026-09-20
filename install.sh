#!/bin/sh
set -eu

REPO="dittofleet/headroom"
LABEL="io.github.dittofleet.headroom"
DEST="${HEADROOM_INSTALL_DIR:-$HOME/Applications}"
APP="$DEST/Headroom.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
GUI_DOMAIN="gui/$(id -u)"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "headroom is a macOS menu bar app, got: $(uname -s)" >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Piped from curl, $0 is the shell and says nothing about where we are, so
# only a real install.sh file next to a Package.swift counts as a checkout.
DIR=""
case "$0" in
  *install.sh) [ -f "$0" ] && DIR="$(cd "$(dirname "$0")" && pwd)" ;;
esac
if [ -n "$DIR" ] && [ -f "$DIR/Package.swift" ]; then
  # Run from a checkout: build what is here.
  echo "Building Headroom from $DIR..." >&2
  make -s -C "$DIR" app
  ditto "$DIR/dist/Headroom.app" "$TMP/Headroom.app"
else
  URL="https://github.com/${REPO}/releases/latest/download/Headroom.zip"
  echo "Downloading $URL..." >&2
  curl -fsSL "$URL" -o "$TMP/Headroom.zip"
  ditto -x -k "$TMP/Headroom.zip" "$TMP"
fi

launchctl bootout "$GUI_DOMAIN/$LABEL" 2>/dev/null || true
mkdir -p "$DEST" "$HOME/Library/LaunchAgents"
rm -rf "$APP"
ditto "$TMP/Headroom.app" "$APP"
echo "Installed $APP" >&2

# The app writes its own LaunchAgent (the same one its "Start at Login"
# menu item manages): launchd starts it at login and restarts it if it
# crashes. Quitting from the menu is a clean exit, so it stays quit until
# the next login.
"$APP/Contents/MacOS/Headroom" --login-item on >/dev/null
launchctl bootstrap "$GUI_DOMAIN" "$PLIST"
echo "Headroom is running in the menu bar and will start at login." >&2
