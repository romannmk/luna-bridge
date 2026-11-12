# Menu bar status + switch for muse-bridge

A SwiftBar plugin that shows the bridge in the macOS menu bar — and a single
switch that turns the bridge **and** Tailscale off and on.

## What you see

- 🟢 bridge — bridge is up and Tailscale is connected
- 🟡 bridge — bridge is up, but Tailscale is down (bridge runs, unreachable
  from outside the Mac)
- 🔴 bridge — bridge is stopped

Clicking the dot shows the bridge version and mode, the number of running
jobs, the Tailscale address, and the switch:

- **Turn off bridge + Tailscale** — `muse-bridge stop`, then `tailscale down`
- **Turn on bridge + Tailscale** — `tailscale up`, then `muse-bridge start`

Plus **Restart bridge** and **Open bridge logs**.

With Tailscale off, nothing outside the Mac can reach the bridge (including
Luna) until it is turned back on. That is the point of the switch.

## Install

Requires [SwiftBar](https://swiftbar.app) (free, open source, actively
maintained; the xbar predecessor is abandoned).

```sh
brew install --cask swiftbar
mkdir -p ~/.swiftbar
cp mac-menu-bar/muse-bridge.10s.sh mac-menu-bar/muse-bridge-toggle.sh ~/.swiftbar/
chmod +x ~/.swiftbar/muse-bridge.10s.sh ~/.swiftbar/muse-bridge-toggle.sh
killall SwiftBar 2>/dev/null || true
defaults write com.ameba.SwiftBar PluginDirectory -string "$HOME/.swiftbar"
open -a SwiftBar
```

The `defaults write` only sticks while SwiftBar is not running, hence the
`killall` first. `~/.swiftbar` needs SwiftBar 2.1.1 or newer (Homebrew installs
the latest). Do not point the plugin folder at
`~/Library/Application Support/SwiftBar/Plugins` — that is SwiftBar's own data
directory.

## Files

- `muse-bridge.10s.sh` — the plugin (polls every 10 s). Reads the public
  `/health` endpoint for bridge state; reads `~/.config/muse-bridge/token`
  only to count running jobs.
- `muse-bridge-toggle.sh` — the on/off helper the menu calls.
