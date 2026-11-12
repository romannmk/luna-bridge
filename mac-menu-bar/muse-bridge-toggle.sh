#!/bin/sh
# muse-bridge-toggle — one switch for the bridge + Tailscale (macOS).
#   muse-bridge-toggle.sh off   stop the bridge, then disconnect Tailscale
#   muse-bridge-toggle.sh on    reconnect Tailscale, then start the bridge
# Called from the SwiftBar menu; run as the user, no sudo needed.
# Note: with Tailscale off, nothing outside the Mac can reach the bridge
# (including Luna) until it is turned back on.
set -u
MUSE_BRIDGE="$(command -v muse-bridge 2>/dev/null || echo "$HOME/Projects/muse-bridge/scripts/muse-bridge")"
TAILSCALE="$(command -v tailscale 2>/dev/null || echo /usr/local/bin/tailscale)"
case "${1:-}" in
  off)
    [ -x "$MUSE_BRIDGE" ] && "$MUSE_BRIDGE" stop
    [ -x "$TAILSCALE" ] && "$TAILSCALE" down
    ;;
  on)
    [ -x "$TAILSCALE" ] && "$TAILSCALE" up
    [ -x "$MUSE_BRIDGE" ] && "$MUSE_BRIDGE" start
    ;;
  *)
    echo "usage: $0 <on|off>" >&2; exit 1 ;;
esac
