#!/bin/sh
# luna-bridge-toggle — one switch for the bridge + Tailscale (macOS).
#   luna-bridge-toggle.sh off   stop the bridge, then disconnect Tailscale
#   luna-bridge-toggle.sh on    reconnect Tailscale, then start the bridge
# Called from the SwiftBar menu; run as the user, no sudo needed.
# Note: with Tailscale off, nothing outside the Mac can reach the bridge
# (including Luna) until it is turned back on.
set -u
LUNA_BRIDGE="$(command -v luna-bridge 2>/dev/null || echo "$HOME/Projects/luna-bridge/scripts/luna-bridge")"
TAILSCALE="$(command -v tailscale 2>/dev/null || echo /usr/local/bin/tailscale)"
case "${1:-}" in
  off)
    [ -x "$LUNA_BRIDGE" ] && "$LUNA_BRIDGE" stop
    [ -x "$TAILSCALE" ] && "$TAILSCALE" down
    ;;
  on)
    [ -x "$TAILSCALE" ] && "$TAILSCALE" up
    [ -x "$LUNA_BRIDGE" ] && "$LUNA_BRIDGE" start
    ;;
  *)
    echo "usage: $0 <on|off>" >&2; exit 1 ;;
esac
