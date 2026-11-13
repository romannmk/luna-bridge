#!/bin/bash
# <xbar.title>Muse Bridge</xbar.title>
# <xbar.version>v1.1</xbar.version>
# <xbar.author>Roman Naumenko</xbar.author>
# <xbar.author.github>romannmk</xbar.author.github>
# <xbar.desc>Menu bar status for muse-bridge + Tailscale, with one switch that turns both off and on.</xbar.desc>
# <xbar.dependencies>curl, python3, muse-bridge, tailscale</xbar.dependencies>
# <xbar.abouturl>https://github.com/romannmk/muse-bridge</xbar.abouturl>
#
# SwiftBar plugin (same format as BitBar/xbar). Filename encodes the refresh
# interval: muse-bridge.10s.sh polls every 10 seconds.
# Shows: a connected bridge, a broken bridge when Tailscale is down,
# or a crossed-out bridge when stopped. Native templates adapt to the menu bar.
# The dropdown is the switch: one item turns bridge + Tailscale off, one turns
# them back on. Needs the toggle helper next to this file:
#   muse-bridge-toggle.sh <on|off>
# Resolve helper CLIs defensively: SwiftBar runs with a minimal PATH.

HERE="$(cd "$(dirname "$0")" && pwd)"
BRIDGE_URL="http://127.0.0.1:8787/health"
TOKEN_FILE="$HOME/.config/muse-bridge/token"

resolve() { # resolve <name> <fallback...> — first executable found
  local name="$1"; shift
  local p
  p="$(command -v "$name" 2>/dev/null)" && [ -n "$p" ] && { echo "$p"; return 0; }
  for p in "$@"; do
    [ -x "$p" ] && { echo "$p"; return 0; }
  done
  echo ""
}

MUSE_BRIDGE="$(resolve muse-bridge "$HOME/Projects/muse-bridge/scripts/muse-bridge" "$HOME/.local/bin/muse-bridge")"
TAILSCALE="$(resolve tailscale "/usr/local/bin/tailscale" "/opt/homebrew/bin/tailscale")"

# --- bridge state (public /health, no auth) ---
HEALTH="$(curl -s -m 2 "$BRIDGE_URL" 2>/dev/null)"
BRIDGE_OK=0; VERSION="?"; MODE="?"
if [ -n "$HEALTH" ]; then
  VERSION="$(printf '%s' "$HEALTH" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("version","?"))' 2>/dev/null || echo "?")"
  MODE="$(printf '%s' "$HEALTH" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("mode","?"))' 2>/dev/null || echo "?")"
  [ "$VERSION" != "?" ] && BRIDGE_OK=1
fi

# --- running jobs (best effort, needs the bridge token) ---
RUNNING=""
if [ "$BRIDGE_OK" -eq 1 ] && [ -f "$TOKEN_FILE" ]; then
  TOKEN="$(cat "$TOKEN_FILE" 2>/dev/null)"
  if [ -n "$TOKEN" ]; then
    RUNNING="$(curl -s -m 2 -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8787/jobs 2>/dev/null \
      | python3 -c 'import sys,json; d=json.load(sys.stdin); print(sum(1 for j in d.get("jobs",[]) if j.get("status")=="running"))' 2>/dev/null)"
  fi
fi

# --- tailscale state (its own IP answers only when connected) ---
TS_OK=0; TS_IP=""
if [ -n "$TAILSCALE" ]; then
  TS_IP="$("$TAILSCALE" ip -4 2>/dev/null | head -n 1)"
  [ -n "$TS_IP" ] && TS_OK=1
fi

# Vector PDF templates (18 pt, transparent). Regenerate with:
#   python3 scripts/generate-menu-bar-icons.py
# Embedded so installation still only needs the two shell scripts.
# BEGIN GENERATED ICONS
ICON_CONNECTED="JVBERi0xLjQKMSAwIG9iago8PCAvVHlwZSAvQ2F0YWxvZyAvUGFnZXMgMiAwIFIgPj4KZW5kb2JqCjIgMCBvYmoKPDwgL1R5cGUgL1BhZ2VzIC9LaWRzIFszIDAgUl0gL0NvdW50IDEgPj4KZW5kb2JqCjMgMCBvYmoKPDwgL1R5cGUgL1BhZ2UgL1BhcmVudCAyIDAgUiAvTWVkaWFCb3ggWzAgMCAxOCAxOF0gL1Jlc291cmNlcyA8PCA+PiAvQ29udGVudHMgNCAwIFIgPj4KZW5kb2JqCjQgMCBvYmoKPDwgL0xlbmd0aCAxNDIgPj4Kc3RyZWFtCnEKMSAwIDAgLTEgMCAxOCBjbQowIEcKMS41IHcKMSBKCjEgagoxLjUgNS41IG0KMTYuNSA1LjUgbAozLjUgNS41IG0KMy41IDE0LjUgbAoxNC41IDUuNSBtCjE0LjUgMTQuNSBsCjMuNSAxNC41IG0KMy41IDcgMTQuNSA3IDE0LjUgMTQuNSBjClMKUQplbmRzdHJlYW0KZW5kb2JqCnhyZWYKMCA1CjAwMDAwMDAwMDAgNjU1MzUgZiAKMDAwMDAwMDAwOSAwMDAwMCBuIAowMDAwMDAwMDU4IDAwMDAwIG4gCjAwMDAwMDAxMTUgMDAwMDAgbiAKMDAwMDAwMDIxNyAwMDAwMCBuIAp0cmFpbGVyCjw8IC9TaXplIDUgL1Jvb3QgMSAwIFIgPj4Kc3RhcnR4cmVmCjQwOQolJUVPRgo="
ICON_DISCONNECTED="JVBERi0xLjQKMSAwIG9iago8PCAvVHlwZSAvQ2F0YWxvZyAvUGFnZXMgMiAwIFIgPj4KZW5kb2JqCjIgMCBvYmoKPDwgL1R5cGUgL1BhZ2VzIC9LaWRzIFszIDAgUl0gL0NvdW50IDEgPj4KZW5kb2JqCjMgMCBvYmoKPDwgL1R5cGUgL1BhZ2UgL1BhcmVudCAyIDAgUiAvTWVkaWFCb3ggWzAgMCAxOCAxOF0gL1Jlc291cmNlcyA8PCA+PiAvQ29udGVudHMgNCAwIFIgPj4KZW5kb2JqCjQgMCBvYmoKPDwgL0xlbmd0aCAxODMgPj4Kc3RyZWFtCnEKMSAwIDAgLTEgMCAxOCBjbQowIEcKMS41IHcKMSBKCjEgagoxLjUgNS41IG0KNyA1LjUgbAoxMSA1LjUgbQoxNi41IDUuNSBsCjMuNSA1LjUgbQozLjUgMTQuNSBsCjE0LjUgNS41IG0KMTQuNSAxNC41IGwKMy41IDE0LjUgbQozLjUgMTEgNSA5IDcgOSBjCjExIDkgbQoxMyA5IDE0LjUgMTEgMTQuNSAxNC41IGMKUwpRCmVuZHN0cmVhbQplbmRvYmoKeHJlZgowIDUKMDAwMDAwMDAwMCA2NTUzNSBmIAowMDAwMDAwMDA5IDAwMDAwIG4gCjAwMDAwMDAwNTggMDAwMDAgbiAKMDAwMDAwMDExNSAwMDAwMCBuIAowMDAwMDAwMjE3IDAwMDAwIG4gCnRyYWlsZXIKPDwgL1NpemUgNSAvUm9vdCAxIDAgUiA+PgpzdGFydHhyZWYKNDUwCiUlRU9GCg=="
ICON_STOPPED="JVBERi0xLjQKMSAwIG9iago8PCAvVHlwZSAvQ2F0YWxvZyAvUGFnZXMgMiAwIFIgPj4KZW5kb2JqCjIgMCBvYmoKPDwgL1R5cGUgL1BhZ2VzIC9LaWRzIFszIDAgUl0gL0NvdW50IDEgPj4KZW5kb2JqCjMgMCBvYmoKPDwgL1R5cGUgL1BhZ2UgL1BhcmVudCAyIDAgUiAvTWVkaWFCb3ggWzAgMCAxOCAxOF0gL1Jlc291cmNlcyA8PCA+PiAvQ29udGVudHMgNCAwIFIgPj4KZW5kb2JqCjQgMCBvYmoKPDwgL0xlbmd0aCAyMzAgPj4Kc3RyZWFtCnEKMSAwIDAgLTEgMCAxOCBjbQowIEcKMS41IHcKMSBKCjEgagpxCjAgMCAxOCAxOCByZQoxLjcgMy43IG0KNC4zIDEuMyBsCjE2LjMgMTQuMyBsCjEzLjcgMTYuNyBsCmgKVyogbgoxLjUgNS41IG0KMTYuNSA1LjUgbAozLjUgNS41IG0KMy41IDE0LjUgbAoxNC41IDUuNSBtCjE0LjUgMTQuNSBsCjMuNSAxNC41IG0KMy41IDcgMTQuNSA3IDE0LjUgMTQuNSBjClMKUQozIDIuNSBtCjE1IDE1LjUgbApTClEKZW5kc3RyZWFtCmVuZG9iagp4cmVmCjAgNQowMDAwMDAwMDAwIDY1NTM1IGYgCjAwMDAwMDAwMDkgMDAwMDAgbiAKMDAwMDAwMDA1OCAwMDAwMCBuIAowMDAwMDAwMTE1IDAwMDAwIG4gCjAwMDAwMDAyMTcgMDAwMDAgbiAKdHJhaWxlcgo8PCAvU2l6ZSA1IC9Sb290IDEgMCBSID4+CnN0YXJ0eHJlZgo0OTcKJSVFT0YK"
# END GENERATED ICONS

# --- menu bar icon ---
if [ "$BRIDGE_OK" -eq 1 ] && [ "$TS_OK" -eq 1 ]; then
  ICON="$ICON_CONNECTED"
  STATUS="Muse Bridge: connected"
elif [ "$BRIDGE_OK" -eq 1 ]; then
  ICON="$ICON_DISCONNECTED"
  STATUS="Muse Bridge: running, Tailscale disconnected"
else
  ICON="$ICON_STOPPED"
  STATUS="Muse Bridge: stopped"
fi
printf ' | templateImage=%s dropdown=false\n' "$ICON"
echo "---"
echo "$STATUS"
if [ "$BRIDGE_OK" -eq 1 ]; then
  echo "Bridge: running (v$VERSION, $MODE)"
  [ -n "$RUNNING" ] && echo "Running jobs: $RUNNING"
else
  echo "Bridge: stopped"
fi
if [ "$TS_OK" -eq 1 ]; then
  echo "Tailscale: connected ($TS_IP)"
elif [ -n "$TAILSCALE" ]; then
  echo "Tailscale: disconnected"
else
  echo "Tailscale: CLI not found"
fi
echo "---"
TOGGLE="$HERE/muse-bridge-toggle.sh"
if [ "$BRIDGE_OK" -eq 1 ] || [ "$TS_OK" -eq 1 ]; then
  echo "Turn off bridge + Tailscale | bash=$TOGGLE param0=off terminal=false refresh=true"
else
  echo "Turn on bridge + Tailscale | bash=$TOGGLE param0=on terminal=false refresh=true"
fi
if [ -n "$MUSE_BRIDGE" ]; then
  echo "Restart bridge | bash=$MUSE_BRIDGE param0=restart terminal=false refresh=true"
fi
echo "Open bridge logs | bash=/usr/bin/open param0=$HOME/Projects/muse-bridge/logs/bridge.out.log terminal=false"
echo "Refresh | refresh=true"
