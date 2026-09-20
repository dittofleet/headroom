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

DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
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

# launchd starts it at login and restarts it if it crashes. Quitting from
# the menu is a clean exit, so it stays quit until the next login.
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$APP/Contents/MacOS/Headroom</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
	<key>ProcessType</key>
	<string>Interactive</string>
</dict>
</plist>
PLIST_EOF

launchctl bootstrap "$GUI_DOMAIN" "$PLIST"
echo "Headroom is running in the menu bar and will start at login." >&2
