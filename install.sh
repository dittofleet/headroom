#!/bin/sh
# Installs the latest release. Given a path to a Headroom.app, installs that
# instead (which is how `make install` installs a build from source).
set -eu

LABEL="io.github.dittofleet.headroom"
DEST="${HEADROOM_INSTALL_DIR:-/Applications}"
APP="$DEST/Headroom.app"
GUI_DOMAIN="gui/$(id -u)"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "headroom is a macOS menu bar app, got: $(uname -s)" >&2
  exit 1
fi

mkdir -p "$DEST" 2>/dev/null || true
if [ ! -w "$DEST" ]; then
  echo "Cannot write to $DEST. Without an admin account, install into your home folder:" >&2
  echo "  curl -fsSL https://raw.githubusercontent.com/dittofleet/headroom/HEAD/install.sh | HEADROOM_INSTALL_DIR=~/Applications sh" >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [ $# -gt 0 ]; then
  ditto "$1" "$TMP/Headroom.app"
else
  URL="https://github.com/dittofleet/headroom/releases/latest/download/Headroom.zip"
  echo "Downloading $URL..." >&2
  curl -fsSL "$URL" -o "$TMP/Headroom.zip"
  ditto -x -k "$TMP/Headroom.zip" "$TMP"
fi

launchctl bootout "$GUI_DOMAIN/$LABEL" 2>/dev/null || true
# Early versions installed into ~/Applications; don't leave a second copy.
rm -rf "$APP" "$HOME/Applications/Headroom.app"
ditto "$TMP/Headroom.app" "$APP"
echo "Installed $APP" >&2

# The app writes its own LaunchAgent, the one its "Start at Login" menu item
# manages. launchd starts it now, at each login, and again if it crashes.
"$APP/Contents/MacOS/Headroom" --login-item on >/dev/null
launchctl bootstrap "$GUI_DOMAIN" "$HOME/Library/LaunchAgents/$LABEL.plist"
echo "Headroom is running in the menu bar and will start at login." >&2
