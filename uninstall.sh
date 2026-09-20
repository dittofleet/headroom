#!/bin/sh
set -eu

LABEL="io.github.dittofleet.headroom"
DEST="${HEADROOM_INSTALL_DIR:-/Applications}"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$DEST/Headroom.app" "$HOME/Applications/Headroom.app" "$HOME/Library/Caches/headroom"
defaults delete "$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/Preferences/$LABEL.plist"
echo "Removed Headroom." >&2
