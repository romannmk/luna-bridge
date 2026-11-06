#!/bin/sh
# luna-bridge uninstall script (macOS). Stops the launchd agent and removes
# the plist. Runtime data (data/, logs/) and config.json are left in place.
set -eu

PLIST_DST="$HOME/Library/LaunchAgents/com.luna.bridge.plist"

launchctl unload "$PLIST_DST" 2>/dev/null || true
rm -f "$PLIST_DST"
rm -f "$HOME/.local/bin/luna-bridge"
echo "luna-bridge unloaded (terminal command removed). Config and data were left in place."
