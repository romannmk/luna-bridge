#!/bin/sh
# muse-bridge install script (macOS).
# - Creates runtime dirs, installs the launchd agent, loads it.
# - Installs the `muse-bridge` terminal command to ~/.local/bin (start/stop/
#   restart/status/foreground for opening and closing the bridge day to day).
# - Does NOT start the server in the foreground; launchd keeps it running.
# Run from the repo root:  sh scripts/install.sh
set -eu

BRIDGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLIST_SRC="$BRIDGE_DIR/launchd/com.muse.bridge.plist"
PLIST_DST="$HOME/Library/LaunchAgents/com.muse.bridge.plist"
NODE_BIN="$(command -v node || echo /usr/bin/node)"

mkdir -p "$BRIDGE_DIR/data/inbox" "$BRIDGE_DIR/data/jobs" "$BRIDGE_DIR/logs"
mkdir -p "$HOME/Library/LaunchAgents"

if [ ! -f "$BRIDGE_DIR/config.json" ]; then
  cp "$BRIDGE_DIR/config.example.json" "$BRIDGE_DIR/config.json"
  echo "Created config.json from config.example.json — edit it before first run."
fi

# Make the transport choice explicit in config.json: write the default
# bind_mode ("auto") when the config predates bind_mode or leaves it unset.
# Node (already required to run the bridge) edits the JSON; no other tool
# is needed, and a failure here must not fail the install.
BIND_MODE="$("$NODE_BIN" -e '
  const fs = require("fs");
  const p = process.argv[1];
  const cfg = JSON.parse(fs.readFileSync(p, "utf8"));
  if (cfg.bind_mode === undefined || cfg.bind_mode === null || cfg.bind_mode === "") {
    cfg.bind_mode = "auto";
    fs.writeFileSync(p, JSON.stringify(cfg, null, 2) + "\n");
  }
  console.log(cfg.bind_mode);
' "$BRIDGE_DIR/config.json" 2>/dev/null || echo auto)"
echo "Transport choice (bind_mode in config.json): $BIND_MODE"
echo "  auto       Tailscale IP if detected, plus 127.0.0.1; otherwise 127.0.0.1 only"
echo "  localhost  127.0.0.1 only (reach it via SSH -L or a tunnel such as Cloudflare Tunnel)"
echo "  tailscale  Tailscale IP only (fails at startup if no Tailscale IP is found)"
echo "  lan        this Mac'\''s LAN IP only"
echo "  custom     the bind_host address from config.json"
echo "  Change bind_mode (and bind_host for custom) in config.json, then re-run this script."

# Tailscale is optional — one transport among equals, never a requirement.
# Note its presence or absence; never fail the install because it is missing.
if command -v tailscale >/dev/null 2>&1; then
  TS_IP="$(tailscale ip --v4 2>/dev/null | head -n 1 || true)"
  if [ -n "$TS_IP" ]; then
    echo "Tailscale: found (this Mac: $TS_IP). With bind_mode auto/tailscale the bridge listens there."
  else
    echo "Tailscale: CLI found, but no Tailscale IP detected (not signed in?). The bridge will run on localhost with bind_mode auto."
  fi
else
  echo "Tailscale: not installed — that is fine, it is optional. The bridge will run on localhost (127.0.0.1); you can add Tailscale or Cloudflare Tunnel later for remote access (see \"Choosing a transport\" in README.md)."
fi

# Substitute placeholders in the plist.
sed -e "s|__BRIDGE_DIR__|$BRIDGE_DIR|g" -e "s|__NODE__|$NODE_BIN|g" \
  "$PLIST_SRC" > "$PLIST_DST"

# Reload (unload first if an old copy is loaded; ignore errors).
launchctl unload "$PLIST_DST" 2>/dev/null || true
launchctl load "$PLIST_DST"

# Install the `muse-bridge` terminal command (open/close the bridge day to
# day) to a per-user PATH location — no sudo, matching the launchd agent.
CLI_DST="$HOME/.local/bin/muse-bridge"
mkdir -p "$HOME/.local/bin"
cp "$BRIDGE_DIR/scripts/muse-bridge" "$CLI_DST"
chmod +x "$CLI_DST"
echo "Installed terminal command: $CLI_DST"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) : ;;
  *)
    echo "  Note: $HOME/.local/bin is not on your PATH yet."
    echo "  Add it once (zsh): echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc"
    echo "  Until then, call it by full path: $CLI_DST status" ;;
esac

echo "muse-bridge installed and loaded."
echo "Open/close the bridge from the terminal:"
echo "  muse-bridge start     open the bridge"
echo "  muse-bridge stop      close the bridge"
echo "  muse-bridge restart   reload it (e.g. after editing config.json)"
echo "  muse-bridge status    show loaded/pid/health"
echo "  muse-bridge foreground  run it in this terminal instead (logs to stdout, Ctrl+C stops; stop the background bridge first)"
echo "Check it: muse-bridge status (or curl http://127.0.0.1:8787/health; for tailscale/lan/custom use the address printed as \"Listening on\" in logs/bridge.out.log)"
echo "First-run token is saved to ~/.config/muse-bridge/token; Muse reads it from that file when needed."
