#!/bin/sh
# muse-bridge uninstall script (macOS). Stops the launchd agent and removes
# the plist. Runtime data (data/, logs/) and config.json are left in place.
set -eu

PLIST_DST="$HOME/Library/LaunchAgents/com.muse.bridge.plist"

launchctl unload "$PLIST_DST" 2>/dev/null || true
rm -f "$PLIST_DST"
rm -f "$HOME/.local/bin/muse-bridge"
echo "muse-bridge unloaded (terminal command removed). Config and data were left in place."
