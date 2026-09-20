#!/bin/sh
# Installs the latest release into /Applications. Given a path to a
# Headroom.app, installs that instead (how `make install` installs a build
# from source). To uninstall, quit Headroom and move it to the Trash.
set -eu

DEST="${HEADROOM_INSTALL_DIR:-/Applications}"
APP="$DEST/Headroom.app"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "headroom is a macOS menu bar app, got: $(uname -s)" >&2
  exit 1
fi
if [ ! -w "$DEST" ]; then
  echo "Cannot write to $DEST. Set HEADROOM_INSTALL_DIR to a folder you can write to." >&2
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

# Quit a running copy so the new one can take its place.
pkill -x Headroom 2>/dev/null && sleep 1 || true
rm -rf "$APP"
ditto "$TMP/Headroom.app" "$APP"

"$APP/Contents/MacOS/Headroom" --login-item on >/dev/null
open "$APP"
echo "Installed $APP. It is in the menu bar and will start at login." >&2
