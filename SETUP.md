# luna-bridge setup (Mac)

Step-by-step setup on the Mac. Takes about ten minutes. Everything runs as
your own user — no sudo, no system-wide install.

## 1. Prerequisites

- **A transport — your explicit choice** (see "Choosing a transport"
  below). The bridge itself installs nothing and needs no third-party
  service: with the default settings it runs on localhost. Tailscale is
  one *optional* transport among equals (localhost, Tailscale,
  Cloudflare Tunnel, LAN, SSH port forward) — pick one knowingly and
  set `bind_mode` accordingly in step 3. If you pick Tailscale, check
  with `tailscale ip` in a terminal — it should print a `100.x.x.x`
  address.
- **Node.js** (v18 or newer) or **Bun**. Check with `node --version`.
  If Node is not installed: `brew install node`.
- **Muse Code CLI** (Meta's terminal coding agent) installed and signed
  in (`muse --version` should print a version; `muse exec --help` lists
  the flags). The bridge is purpose-built for Muse Code today: `muse_bin`
  selects the binary, but the subcommands and flags it passes are Muse
  Code's — other agent CLIs are not drop-in compatible yet (see "Which
  agent CLI does it run?" in README.md).
- **tmux** (for shared sessions only — headless jobs do not need it).
  Check with `which tmux`; if missing: `brew install tmux`. Without tmux,
  `POST /sessions` returns `status: "dead"` with an explanatory error while
  everything else keeps working.
- **Remote Login is NOT needed** (unless you pick the SSH port-forward
  transport below). The bridge replaces SSH entirely.

## Choosing a transport

Decide this **at install time** and record it as `bind_mode` in
`config.json` (step 3); `scripts/install.sh` writes the default
(`auto`) when unset, prints the active choice, and never fails just
because Tailscale is missing. At startup the server logs the exact
addresses it listens on and how a client reaches it.

| Option | What to install | What is exposed to whom | Trade-off |
|---|---|---|---|
| Localhost only (`bind_mode: "localhost"`, or `"auto"` with no Tailscale IP) | Nothing | The port exists only on this Mac (`127.0.0.1`); nothing on any network can reach it | Safest and dependency-free, but by itself no remote client can connect |
| Tailscale — private mesh VPN (`bind_mode: "tailscale"`, or `"auto"` with Tailscale present) | Tailscale app + a Tailscale account, on the Mac and on each client | The port on the Mac's `100.x.x.x` tailnet address, only to devices you approved in your tailnet | Private and simple, but depends on a third-party service and account |
| Cloudflare Tunnel — public URL via outbound relay (`bind_mode: "localhost"` + tunnel to `127.0.0.1:8787`) | `cloudflared` on the Mac (+ a Cloudflare account/domain for a named tunnel) | A public HTTPS URL; anyone who knows it can reach the port (the Bearer [REDACTED] still gates the API) | Reachable from anywhere with no open inbound ports, but the endpoint is public and traffic transits Cloudflare — keep the token secret, consider Cloudflare Access |
| LAN (`bind_mode: "lan"`) | Nothing | The port on the Mac's LAN IP, to every device on the same local network | Dependency-free remote access at home, but anyone on that network can reach the port (token still required) |
| Custom address (`bind_mode: "custom"` + `bind_host: "<ip-or-hostname>"`) | Nothing | The port on exactly the `bind_host` address you name, to whatever network that address belongs to | Full manual control (a second interface, a VPN address, …), but you own the exposure decision for that address; the server fails at startup if `bind_host` is missing or invalid |
| SSH port forward (`ssh -L 8787:127.0.0.1:8787 <mac>`, with `bind_mode: "localhost"`) | An SSH server on the Mac (macOS Remote Login) and an SSH client on the client side | Nothing new: the client reaches its own `127.0.0.1:8787`, forwarded over its SSH connection | Reuses existing SSH trust and keys, but the client must hold the `ssh -L` connection open and be able to SSH to the Mac at all |

`bind_mode: "auto"` (default) = the Tailscale IP if one is detected,
plus `127.0.0.1`; otherwise `127.0.0.1` only — a missing `tailscale`
CLI is never an error there. `"tailscale"` / `"lan"` fail loudly at
startup if the address they need does not exist; `"custom"` listens on
`bind_host` (required, must be a valid IP/hostname). The bridge never
binds `0.0.0.0`. You can change your mind later: edit `bind_mode` (and
`bind_host` for `custom`) and re-run `sh scripts/install.sh` — e.g.
start on localhost today, add Tailscale or Cloudflare Tunnel later.

## 2. Clone

```sh
git clone https://github.com/romannmk/luna-bridge.git
cd luna-bridge
```

## 3. Configure

```sh
cp config.example.json config.json
```

Edit `config.json` (it is gitignored — it never leaves your machine):

- `bind_mode` (+ `bind_host` for `custom`): your transport choice from
  "Choosing a transport" above. The shipped default is `"auto"`
  (Tailscale IP if detected + 127.0.0.1, else 127.0.0.1 only) — keep it
  only if that is the exposure you want.
- `default_workdir`: the directory jobs run in when the client does not
  specify one, e.g. `/Users/you/Projects/my-app`.
- `allowed_workdirs`: optional array of absolute paths, e.g.
  `["/Users/you/Projects"]`. When set and non-empty, jobs and sessions
  may only *start* in (or under) one of these dirs — anything else is
  rejected with 403, including a `default_workdir` outside the list.
  Absent/empty = no restriction. This guards the start directory only;
  the agent still runs as your user and can `cd` elsewhere inside a
  session (see "Security model" in README.md). Recommended: your
  projects folder.
- `mode`: `"unrestricted"` is the shipped default. It runs tasks with no
  approval prompts and no sandbox — keep it only if that is what you want
  (see "Security model" in README.md).
- `default_model` / `default_effort`: leave both at `null` (unset) unless
  you want every run to use a specific model or effort tier. Luna can also
  set them per run (`model`, `effort` fields on `POST /jobs` and
  `POST /sessions`); per-request values win. See README for the effort
  enum and example model ids.
- `muse_bin`: `"muse"` is fine if `muse` is on your PATH. If the bridge
  cannot find it, put the full path here.
- `keep_awake`: leave at `false` for the first run. Set it to `true`
  (macOS only) if the Mac must stay online whenever the bridge is up:
  the bridge then holds an idle-sleep assertion with the built-in
  `caffeinate` tool for as long as it runs. Trade-off: the Mac will
  **not** idle-sleep at all while the daemon is up — on a laptop that
  means battery drain and heat when unplugged, so plug in or close the
  bridge (`luna-bridge stop`) when you do not need it. Closing the lid
  or choosing Sleep manually still sleeps the Mac. After changing it,
  restart the bridge (`luna-bridge restart`, step 5).
- Leave everything else at the defaults for the first run.

## 4. First run (foreground)

```sh
node server.js --foreground
```

This runs the bridge attached to this terminal, with the startup log
on stdout in front of you; Ctrl+C stops it. It is the same server and
the same `config.json` as the background launchd run in step 5 —
foreground is how you try it out (and how you re-run it later, via
`luna-bridge foreground`, whenever you want it open only while you
watch); background via launchd is the day-to-day default.

On first run with no token configured, the server generates a strong bearer
token and saves it to `~/.config/luna-bridge/token` (mode 0600). The token
value is never printed or logged, in either mode — under launchd stdout
lands in `logs/bridge.out.log`, so printing it there would leak it into
a log file. Startup
confirms the generation without revealing the value:

```
[auth] Generated a new bearer token and saved it to:
[auth]   /Users/you/.config/luna-bridge/token
```

Luna reads the token from that file when needed — never paste secrets
in chat. Then check the server answers locally:

```sh
curl http://127.0.0.1:8787/health
# {"ok":true,"version":"0.1.0","mode":"unrestricted"}
```

Stop it with Ctrl+C.

## 5. Install as a launchd agent (runs at login, restarts if it exits)

```sh
sh scripts/install.sh
```

This copies the launchd plist to `~/Library/LaunchAgents/com.luna.bridge.plist`
(with the correct paths filled in) and loads it. It also installs the
`luna-bridge` terminal command to `~/.local/bin` (it tells you if that
directory is not on your `PATH` yet and how to add it). Logs go to
`logs/` in the repo directory. Background via launchd is the default
way the bridge runs: it is **online while it is running and offline
when it is stopped** — the same presence semantics as Codex (app open
= online, app closed = offline). You decide when it is open.

Day to day, open and close the bridge with that command — this is the
way to do it:

```sh
luna-bridge start       # open the bridge
luna-bridge stop        # close the bridge
luna-bridge restart     # reload it (e.g. after editing config.json)
luna-bridge status      # agent loaded? bridge pid? health?
luna-bridge foreground  # run it in this terminal instead (stop first if open)
```

It wraps `launchctl load`/`unload` of `com.luna.bridge` plus a health
check (`status` exits non-zero when the bridge is down). Running
`start`/`stop` twice is harmless. If your `bind_mode` does not listen
on 127.0.0.1 (`tailscale`/`lan`/`custom`), point the health check at
the "Listening on" address once per call:
`LUNA_BRIDGE_HEALTH_URL=http://<that-address>:8787/health luna-bridge status`.
`foreground` is the exception to the launchd wrapping: it runs
`node server.js --foreground` right here in your terminal (logs to
stdout, Ctrl+C stops it — the bridge is offline from that moment).
It refuses to start while the background agent is loaded, so
`luna-bridge stop` first if the bridge is open.

To remove the bridge entirely:

```sh
sh scripts/uninstall.sh   # unloads the agent, removes plist + luna-bridge command
```

## 6. Confirm Luna can reach it

Use the address of the transport you chose — the startup log prints it
(`Listening on: ...` plus the "How a client reaches it" line). For the
Tailscale transport, from the VM through the Tailscale tunnel (Luna
does this; shown here so you can check it yourself from any machine on
the tailnet):

```sh
curl --proxy "${HTTPS_PROXY%:*}:3130" http://<mac-tailscale-ip>:8787/health
```

The Mac's Tailscale IP is the `100.x.x.x` address from `tailscale ip`.
For the other transports, the same check is
`curl http://127.0.0.1:8787/health` (localhost / SSH `-L`, from the
forwarding side), `curl http://<mac-lan-ip>:8787/health` (LAN), or your
tunnel's public URL (Cloudflare Tunnel).

## 7. Verify the Muse Code flags once

The bridge was written from Meta's docs (CLI 1.4.13). Run this once on
the Mac and check whether your Muse Code version accepts every flag:

```sh
muse exec --help
```

Flags the bridge relies on: `--yolo`, `--trust-workspace`,
`--max-model-steps`, `--prompt-file`, `--workspace`, `--approval-mode`,
`--approval-judge`, `--disable-write`, `--disable-shell`, plus the per-run
model/effort flags `--model <ID>` and `--reasoning-effort <TIER>`
(effort tiers: `none|minimal|low|medium|high|xhigh|max|ultra`). If any of
them is rejected, set the matching option in `config.json`
(`prompt_via_file: false`, `use_workspace_flag: false`, or adjust
`muse_args`; leave `default_model`/`default_effort` as `null` to skip
those flags entirely) and restart the server.

## Shared sessions: attaching from your terminal

When Luna starts a shared session, she sends you the attach command from
its response:

```sh
tmux attach -t luna-<id>
```

You land inside the agent's terminal and can watch or type. Detach with
`Ctrl-b d` — the session keeps running, and Luna can still read it. List
your live sessions any time with `tmux ls`.

**One-driver rule: only one party types at a time.** If Luna is driving
(she only types when you explicitly ask her to), keep your hands off the
keyboard in the attached terminal, and vice versa — both sides type into
the same prompt, so simultaneous typing garbles the input. When in doubt,
say who drives.

## Troubleshooting

- **Server starts but Luna cannot reach it**: check the startup log — it
  prints the active `bind_mode`, the addresses it listens on, and how a
  client reaches it. If it only lists 127.0.0.1 but you expected remote
  access, your transport is not in place: with `bind_mode: "auto"` that
  means no Tailscale IP was detected (check `tailscale ip`, or choose
  another transport — set `bind_mode` to `"lan"`, or `"custom"` with an
  explicit `bind_host` — and restart). If the server instead exits
  immediately with a `[fatal]` line about `bind_mode`, the chosen mode
  could not be satisfied (e.g. `"tailscale"` with no Tailscale IP);
  the message says how to fix it.
- **401 Unauthorized**: the token is wrong. The token lives in
  `~/.config/luna-bridge/token` (or `LUNA_BRIDGE_TOKEN` / `config.json`).
  Delete the token file and restart to generate a new one — then share the
  new one with Luna.
- **Job fails immediately with "muse binary not found"**: the server's
  launchd environment has a minimal PATH. Set `muse_bin` in `config.json`
  to the full path (find it with `command -v muse` in your terminal).
- **Job stalls on an approval**: the mode is not unrestricted. Check
  `GET /mode`; if it is not `unrestricted`, tell Luna — she switches it
  only on your explicit word.
- **A job runs forever**: Luna can cancel it (`POST /jobs/:id/cancel`).
  `max_model_steps` (default 300) caps how much work a run can do.
- **Port already in use**: the bridge is probably already running —
  in the background (`luna-bridge status`) or in a foreground terminal
  somewhere. Stop the other copy first (`luna-bridge stop`, or Ctrl+C
  in the foreground window); `luna-bridge foreground` refuses on its
  own when the background agent is loaded. If nothing should be
  running, change `port` in `config.json` and reinstall
  (`sh scripts/uninstall.sh && sh scripts/install.sh`).
- **Luna cannot reach the Mac because it was asleep**: set
  `keep_awake: true` in `config.json` and run `luna-bridge restart`.
  The startup log then shows a `keep-awake is on` line, and the Mac
  stops idle-sleeping while the bridge runs (battery/heat trade-off —
  see step 3). If the log instead says keep-awake is macOS-only or
  `caffeinate` failed, the bridge still runs; only the assertion is off.
- **`luna-bridge: command not found`**: `~/.local/bin` is not on your
  `PATH` yet — add it (the installer prints the exact line), or call
  the command by full path: `~/.local/bin/luna-bridge status`.

## Appendix: test coverage in detail

This is the full breakdown behind the summary in README.md ("Testing").
On a machine without Muse Code, the suite uses a fake `muse` executable:

```sh
sh test/run-tests.sh   # 260 checks: health, auth, upload, jobs, model/effort, cancel, mode, sessions, 400s, bind_mode transports, keep_awake, luna-bridge CLI, --foreground, allowed_workdirs
```

What is tested: health (no auth), 401 on missing/wrong token, upload (201,
file on disk, traversal sanitized), job lifecycle (create → done, output
contains the fake run lines and the prompt), failing job (exit 1), cancel of
a slow job (SIGTERM to the process group), mode get/set + bad mode → 400,
bad input → 400 (empty prompt, missing workdir, attachment outside inbox),
unknown job → 404, job list, model/effort controls (per-run passthrough to
the `muse` argv for jobs and sessions, every effort tier accepted, bad
effort/model → 400, `meta.json` records the effective values, config
`default_model`/`default_effort` apply with per-request override), plus
shared sessions (real tmux + fake muse in interactive mode):
auth/validation 401s and 400s, create (201, `luna-<id>` name, attach
command, `alive`, meta.json on disk), pane read with the idle hint, input
typed into the pane and echoed back, kill (dead, pane → 404, tmux session
really gone), and survival across a bridge restart (still listed, still
alive, pane still readable; job/session model/effort survive from disk).
Session tests are skipped with a note on machines without tmux.
The `allowed_workdirs` allowlist is covered twice too: unit checks of
the exported `isWorkdirAllowed`/`normalizeAllowedWorkdirs`/
`resolveWorkdirPath` (unset/empty = no restriction, equal/inside
accepted, outside, sibling-prefix, `..` escapes and symlink escapes
rejected, `~` expansion, malformed config throws) and end-to-end
server spawns (jobs and sessions inside accepted; outside, `..`, and
symlink escapes → 403; a `default_workdir` outside the list → 403;
the unset main server still accepts any workdir).
Transport binding is covered twice: unit checks of the pure
`resolveBindHosts`/`detectLanIp`/`isValidBindHost` functions exported
from `server.js` (every `bind_mode`, with and without a detected
Tailscale/LAN IP, the legacy no-`bind_mode` behaviour, loud failures),
and end-to-end server spawns with a fake `tailscale` CLI on PATH
(`localhost`, `auto` with/without a Tailscale IP, `tailscale` only,
`tailscale`-without-IP and `custom`-without/invalid-`bind_host`
failing at startup, the plain-language startup log, and that the log
never contains the token). The fake CLI reports the machine's LAN IP
as its "Tailscale IP" so the address is really bindable; on a machine
with no LAN IP those two e2e cases are skipped with a note.
Keep-awake is covered twice as well: unit checks of the exported
`startKeepAwake`/`stopKeepAwake` with an injected fake spawn (spawns
`caffeinate -i -w <pid>` only when enabled and only on macOS, never
crashes when spawn fails or the child errors, shutdown kills the
child), and — on macOS — an end-to-end spawn with a fake `caffeinate`
on PATH (spawned with the server's pid when `keep_awake` is true, never
when off, gone after the server is terminated). The `luna-bridge` CLI
is tested against a fake `launchctl`/`curl` on PATH with a temp `HOME`
(the real launchd agent is never touched): start/stop/restart/status
including already-running/stopped idempotence, the status pid + health
report and its non-zero exits, usage errors, and the not-installed
hint. Foreground mode is covered on both surfaces: `parseArgs` unit
checks (no args = background default, `--foreground` on, unknown flag
throws), `node server.js --help`/`--bogus` exit codes, an end-to-end
`node server.js --foreground` run (health answers, the process stays
attached until SIGINT, the startup log — including its "foreground
mode" line — lands on stdout and not stderr), and the CLI's
`foreground` verb against a fake `node` (execs `server.js
--foreground` when the agent is stopped, refuses with a
"stop it first" message while the agent is loaded).

What is NOT tested here (needs a real setup): the real `muse exec`
(its flags are documented in README.md from Meta's docs, not from a live
binary), binding to a real Tailscale address (the suite uses a fake
`tailscale` CLI reporting a bindable local address), and an end-to-end
curl-through-tunnel path from a remote client to the Mac.
