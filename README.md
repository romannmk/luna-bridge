# luna-bridge

A tiny HTTP server that runs on a developer's Mac and lets a remote client
(an AI agent, a script, or a phone app relaying through one) run coding
tasks in **Muse Code CLI** (Meta's terminal coding agent; see "Which
agent CLI does it run?" below) on that Mac. The developer decides whether
the bridge is open or closed at any moment — background or foreground, it
is one terminal command either way (see "Opening and closing the bridge").

Repository: `github.com/romannmk/luna-bridge`.

## Why this exists

The flow it was built for: the developer sends a task from their phone,
a remote agent passes it to the bridge on the Mac, Muse Code does the
work (git branch work, fixes), and the agent reports back with the result
and the "open a draft PR?" question. Screenshots ride along with the task.
The bridge only carries tasks while the developer keeps it open — closing
it is their call, not something that happens behind their back. The
examples below name the original client agent "Luna"; any HTTP client that
can send a Bearer token works the same way.

In the original setup SSH to the Mac turned out to be blocked: the remote
environment's egress proxy only allows curl's CONNECT and only forwards
TLS/HTTPS, so raw SSH never gets through. But HTTPS through a private
tunnel does reach the Mac with curl — so the bridge is an HTTP server on
the Mac, reached over whatever private transport you choose (see
"Choosing a transport"). No SSH is required.

## Which agent CLI does it run?

Today the bridge is purpose-built for **Muse Code**: it spawns the
configured binary (`muse_bin`, default `muse`) as `muse exec …` for
headless jobs and as the interactive `muse` TUI for shared sessions, and
it maps its permission modes, model, and effort controls onto Muse Code
flags (`--yolo`, `--prompt-file`, `--workspace`, `--reasoning-effort`, …).
The binary path and extra arguments are configurable (`muse_bin`,
`muse_args`), so a wrapper script can adapt the invocation — but other
terminal coding agents (Codex, Claude Code, …) use different subcommands
and flags, so pointing `muse_bin` at them directly will not work yet.
Making the flag mapping a per-agent profile is a known follow-up, not a
hidden feature: do not expect drop-in support for other CLIs today.

## How it works

```
Client (e.g. an AI agent) → curl → private transport → luna-bridge (Mac)
                                                        → muse exec (headless)
                                                        → result back to client
```

1. The client uploads a file (e.g. a screenshot): `POST /upload` (raw
   body, `X-Filename` header). The file lands in the bridge's inbox
   directory on the Mac.
2. The client starts a job: `POST /jobs` with
   `{prompt, workdir, attachments}`. The bridge spawns `muse exec`
   (headless) in that working directory. The prompt references the
   uploaded files by their on-disk paths.
3. The client polls `GET /jobs/:id` for status and output, or cancels
   with `POST /jobs/:id/cancel`.
4. When the job is done, the client reports the result. (In the original
   workflow nothing is ever merged automatically — draft PRs only.)

Variant: when the developer wants to watch or co-drive, the client
starts a **shared session** (`POST /sessions`) instead — the interactive
`muse` TUI inside tmux; the developer attaches with
`tmux attach -t luna-<id>` while the client reads the pane. See "Shared
sessions" below.

## Quick start

See [SETUP.md](SETUP.md) for the full Mac setup. Short version:

```sh
git clone https://github.com/romannmk/luna-bridge.git
cd luna-bridge
cp config.example.json config.json
# edit config.json: set default_workdir (e.g. /Users/you/Projects/my-app)
sh scripts/install.sh        # installs the launchd agent + luna-bridge command, starts the server
luna-bridge status           # (installed to ~/.local/bin) loaded? pid? health?
# or: curl http://127.0.0.1:8787/health
# Prefer it attached to this terminal? Skip install.sh and run:
#   node server.js --foreground   (logs to stdout, Ctrl+C stops it —
#   background via launchd is just the default, see "Opening and closing")
```

On first run with no token configured, the server generates a strong bearer
token, saves it to `~/.config/luna-bridge/token`.
Luna reads it from that file when needed — never paste secrets in chat.

## Opening and closing the bridge (terminal commands)

**Background by default.** `scripts/install.sh` installs the bridge as a
launchd agent (`com.luna.bridge`): it starts at login, launchd restarts
it if it exits (`KeepAlive`), and its logs go to `logs/bridge.out.log` /
`logs/bridge.err.log`. There is no cloud component and nothing
always-on: the bridge is **online while it is running and offline when
it is stopped** — the same presence semantics as Codex (app open =
online, app closed = offline). Stop the bridge (or let the Mac sleep or
shut down) and Luna simply cannot reach it until it is open again. The
developer decides when that is.

`scripts/install.sh` also installs a small `luna-bridge` command to
`~/.local/bin` (it says so if that directory is not on your `PATH` yet).
This is how a developer opens or closes the bridge day to day:

```sh
luna-bridge start       # open the bridge (load the launchd agent, then check health)
luna-bridge stop        # close the bridge (unload the launchd agent)
luna-bridge restart     # unload + load (e.g. after editing config.json)
luna-bridge status      # agent loaded? bridge pid? health?
luna-bridge foreground  # run the bridge in this terminal instead (see below)
```

`start`/`stop`/`restart`/`status` are a dependency-free shell wrapper
around `launchctl load`/`unload` of `com.luna.bridge` plus a `curl`
health check. `start`/`stop` are idempotent (running them twice is
fine). `status` exits non-zero when the bridge is not loaded or not
healthy. The health check defaults to
`http://127.0.0.1:8787/health`; if your `bind_mode` does not listen on
127.0.0.1 (`tailscale`/`lan`/`custom`), point it at the "Listening on"
address instead: `LUNA_BRIDGE_HEALTH_URL=http://<that-address>:8787/health luna-bridge status`
(`LUNA_BRIDGE_PORT` overrides just the port). Day-to-day you should not
need raw `launchctl` at all.

**Foreground mode** (`luna-bridge foreground`) runs the same server
attached to your terminal instead of under launchd: logs print to
stdout in that window, and Ctrl+C (or closing the window) stops the
bridge — online while that terminal run lasts, offline the moment it
ends. Nothing else changes: same `config.json`, same transport, same
`keep_awake` behaviour. Use it for a first run, for debugging, or when
you want the bridge open only while you are sitting at the Mac. It
refuses to start while the background agent is loaded (two copies
would fight over the port): `luna-bridge stop` first, then
`luna-bridge foreground`. Under the hood it runs
`node server.js --foreground`; you can also start the server that way
directly from the repo directory (`node server.js --help` lists the
flags).

## Keeping the Mac awake (optional)

Presence (previous section) has a second half: the bridge can only be
online while it runs *and the Mac is awake*. By default the Mac follows
its normal sleep settings — and a sleeping Mac cannot answer Luna.
Set `keep_awake: true` in `config.json` (then `luna-bridge restart`,
or just relaunch a foreground run) to make the bridge hold a macOS
idle-sleep assertion for as long as the bridge process runs:
**online always while the bridge is running**, background or
foreground — and the assertion ends the moment the bridge stops. It uses only the `caffeinate` tool built into
macOS (`caffeinate -i -w <bridge pid>`, spawned at startup, killed on
shutdown; the `-w` also ends it if the bridge dies). No third-party
dependency. Off by default; on non-macOS systems (or if `caffeinate`
cannot start) the server just logs that keep-awake is unavailable and
runs normally.

**Trade-off, stated plainly:** while the bridge is up, the Mac will not
idle-sleep at all. On a laptop that means steady battery drain and heat
if you leave the daemon running unplugged — plug in, or close the
bridge (`luna-bridge stop`) when you do not need it. Keep-awake prevents
*idle* sleep only: closing a laptop lid or choosing Sleep from the
Apple menu still sleeps the Mac.

## Choosing a transport

The bridge itself has **zero third-party dependencies** (Node.js stdlib
only, no `npm install`). How a client *reaches* it is a separate,
explicit choice — **make it at install time**: set `bind_mode` (and
`bind_host` for `custom`) in `config.json` before running
`scripts/install.sh`. The installer writes the default (`auto`) into
`config.json` when unset and prints the active choice; at startup the
server logs the exact addresses it listens on and how a client reaches
it. Tailscale is **one option among equals, not a requirement** — with
no Tailscale installed at all, the bridge runs on localhost.

| Option | What to install | What is exposed to whom | Trade-off |
|---|---|---|---|
| Localhost only (`bind_mode: "localhost"`, or `"auto"` with no Tailscale IP) | Nothing | The port exists only on this Mac (`127.0.0.1`); nothing on any network can reach it | Safest and dependency-free, but by itself no remote client can connect |
| Tailscale — private mesh VPN (`bind_mode: "tailscale"`, or `"auto"` with Tailscale present) | Tailscale app + a Tailscale account, on the Mac and on each client | The port on the Mac's `100.x.x.x` tailnet address, only to devices you approved in your tailnet | Private and simple, but depends on a third-party service and account |
| Cloudflare Tunnel — public URL via outbound relay (`bind_mode: "localhost"` + tunnel to `127.0.0.1:8787`) | `cloudflared` on the Mac (+ a Cloudflare account/domain for a named tunnel) | A public HTTPS URL; anyone who knows it can reach the port (the Bearer [REDACTED] still gates the API) | Reachable from anywhere with no open inbound ports, but the endpoint is public and traffic transits Cloudflare — keep the token secret, consider Cloudflare Access |
| LAN (`bind_mode: "lan"`) | Nothing | The port on the Mac's LAN IP, to every device on the same local network | Dependency-free remote access at home, but anyone on that network can reach the port (token still required) |
| Custom address (`bind_mode: "custom"` + `bind_host: "<ip-or-hostname>"`) | Nothing | The port on exactly the `bind_host` address you name, to whatever network that address belongs to | Full manual control (a second interface, a VPN address, …), but you own the exposure decision for that address; the server fails at startup if `bind_host` is missing or invalid |
| SSH port forward (`ssh -L 8787:127.0.0.1:8787 <mac>`, with `bind_mode: "localhost"`) | An SSH server on the Mac (macOS Remote Login) and an SSH client on the client side | Nothing new: the client reaches its own `127.0.0.1:8787`, forwarded over its SSH connection | Reuses existing SSH trust and keys, but the client must hold the `ssh -L` connection open and be able to SSH to the Mac at all |

Notes:

- `bind_mode: "auto"` (default) = the Tailscale IP if one is detected,
  plus `127.0.0.1`; otherwise `127.0.0.1` only. A missing `tailscale`
  CLI is never an error in this mode.
- `"tailscale"` and `"lan"` fail loudly at startup when the address
  they need does not exist, instead of silently binding something
  else. `"custom"` listens on `bind_host` (required, must be a valid
  IP/hostname). The bridge never binds `0.0.0.0`.
- Configs written before `bind_mode` existed keep working as before:
  with no `bind_mode` key, a detected Tailscale IP (else an explicitly
  set `bind_host`) is bound, plus `127.0.0.1`.
- The transport is independent of how the bridge runs: background
  (launchd) and foreground (`luna-bridge foreground`) bind exactly the
  addresses the same `bind_mode` selects.

## API

Base URL: `http://<mac-address-for-your-transport>:8787` (default port
8787; e.g. the Mac's Tailscale IP, LAN IP, or 127.0.0.1 — see "Choosing
a transport"; the startup log prints the exact addresses).
Every endpoint except `GET /health` requires
`Authorization: Bearer <token>`. All responses are JSON.

| Method | Path | Description |
|---|---|---|
| GET | `/health` | `{ok, version, mode}` — no auth, for liveness checks |
| POST | `/upload` | Raw request body → file in the inbox dir. Filename from `X-Filename` header or `?name=` query (sanitized: basename only). Returns `{path, name, size}` (201) |
| POST | `/jobs` | `{prompt, workdir?, attachments?, mode?, model?, effort?}` → `{job_id}` (202). `workdir` must exist; `attachments` must be paths under the inbox dir. `model` is a free-form model id (e.g. `muse-spark-1.3`); `effort` is one of `none\|minimal\|low\|medium\|high\|xhigh\|max\|ultra`. `null`/absent falls back to `default_model`/`default_effort` |
| GET | `/jobs/:id` | `{status, exit_code, output, approval_blocked, started_at, finished_at, workdir, ...}`. `status`: `queued \| running \| done \| failed \| cancelled` |
| GET | `/jobs` | Recent jobs (id, status, started_at, prompt preview), newest first |
| POST | `/jobs/:id/cancel` | Kill the job's process group. Returns `{id, status}` |
| POST | `/sessions` | `{prompt, workdir?, mode?, model?, effort?}` → `{session_id, tmux_session, attach_command, workdir, mode, model, effort, status}` (201). Starts interactive `muse` with the prompt inside a detached tmux session. `model`/`effort` behave as for `POST /jobs` |
| GET | `/sessions` | Live sessions (id, tmux name, `alive`/`dead`, attach command), newest first. Status is reconciled with `tmux has-session` on every read, so sessions survive a bridge restart |
| GET | `/sessions/:id` | One session's meta + live status |
| GET | `/sessions/:id/pane` | `{id, status, pane, idle}` — `tmux capture-pane` text plus a best-effort `idle` hint (true when the pane looks like the agent waiting at its prompt) |
| POST | `/sessions/:id/input` | `{text}` — type text + Enter into the session via `tmux send-keys`. Luna calls this only when the owner explicitly asks (one-driver rule) |
| POST | `/sessions/:id/kill` | Kill the tmux session. Returns `{id, status: "dead"}` |
| GET | `/mode` | `{mode, muse_settings_profile, muse_args_for_mode}` |
| POST | `/mode` | `{mode}` — set the mode for subsequently started jobs (persisted) |

Example (from a remote client, through a Tailscale tunnel proxy):

```sh
tunnel_proxy="${HTTPS_PROXY%:*}:3130"
TAIL=100.64.0.10   # the Mac's Tailscale IP (find it with `tailscale ip`)
TOKEN="<bearer token>"

# upload a screenshot
curl --proxy "$tunnel_proxy" -X POST -H "Authorization: Bearer $TOKEN" \
  -H 'X-Filename: failure.png' --data-binary @failure.png \
  "http://$TAIL:8787/upload"

# start a job (attachments are the paths returned by /upload)
curl --proxy "$tunnel_proxy" -X POST -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"Fix the failing test shown in the screenshot at <path>. Switch to main, pull, create a new branch fix/..., do the fix.","workdir":"/Users/you/Projects/my-app","attachments":["<path>"]}' \
  "http://$TAIL:8787/jobs"

# poll status
curl --proxy "$tunnel_proxy" -H "Authorization: Bearer $TOKEN" \
  "http://$TAIL:8787/jobs/<job_id>"

# cancel
curl --proxy "$tunnel_proxy" -X POST -H "Authorization: Bearer $TOKEN" \
  "http://$TAIL:8787/jobs/<job_id>/cancel"
```

Job output (`output`) is the combined stdout+stderr tail (up to 200 KB, see
`max_output_tail_bytes`); the full log is kept in the job directory on disk
(`data/jobs/<id>/log.txt`), along with `prompt.txt` and `meta.json`.
`approval_blocked: true` in job status means the output looks like the run
stalled on an approval request (heuristic marker scan).

## Shared sessions (owner + Luna in one terminal)

Jobs are headless: nobody can watch them work. When the owner wants to sit
with the agent — see what it does, take over typing, hand control back —
Luna starts a **shared session** instead:

```sh
# Luna starts one (through the tunnel, Bearer [REDACTED] as usual):
curl --proxy "$tunnel_proxy" -X POST -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"Continue the checkout work; I am watching.","workdir":"/Users/you/Projects/my-app"}' \
  "http://$TAIL:8787/sessions"
# -> {"session_id":"…","tmux_session":"luna-…",
#     "attach_command":"tmux attach -t luna-…", …}
```

What happens: the bridge runs
`tmux new-session -d -s luna-<id> -c <workdir> muse <mode flags> "<prompt>"`
— the interactive `muse` TUI (bare `muse` with the initial prompt as a
positional argument; verified with `muse --help` on the installed CLI),
with the same mode flags as jobs (`unrestricted` → `--yolo`, always plus
`--trust-workspace` so the trust prompt never blocks a shared session).

- **Owner attaches** from any terminal on the Mac with the returned
  `attach_command` (`tmux attach -t luna-<id>`). Detach with `Ctrl-b d`;
  the session keeps running.
- **Luna reads** with `GET /sessions/:id/pane` (the pane text plus an
  `idle` hint). She polls this the same way she polls jobs.
- **Luna types** with `POST /sessions/:id/input` (`{text}` sends the text
  plus Enter via `tmux send-keys`) — **only when the owner explicitly
  asks**. Otherwise she only reads.
- **Either side ends it** with `POST /sessions/:id/kill`.

**One-driver rule: only one party types at a time.** If the owner is
typing in the attached terminal, Luna stays hands-off (pane reads only),
and vice versa. The bridge cannot enforce this — typed input goes to the
same prompt either way — so it is a standing agreement, not a lock.

Sessions survive a bridge restart: the tmux server is independent of the
bridge process, and every session read reconciles the recorded status
with live `tmux has-session` state (`alive`/`dead`). Session meta lives
under `data/sessions/<id>/` (`meta.json`, `prompt.txt`), next to jobs.

## Configuration

`config.json` (copy from `config.example.json`; never commit a real one —
it is gitignored). All keys are optional; defaults are shown in the example.

| Key | Default | Meaning |
|---|---|---|
| `port` | `8787` | HTTP port |
| `bind_mode` | `"auto"` | Transport choice (see "Choosing a transport"): `auto` (Tailscale IP if detected + 127.0.0.1, else 127.0.0.1 only; missing Tailscale CLI is never an error), `localhost` (127.0.0.1 only), `tailscale` (Tailscale IP only — fails at startup if none found), `lan` (this machine's LAN IP — fails at startup if none found), `custom` (the `bind_host` address) |
| `bind_host` | `null` | IP/hostname to listen on. Used (and required) by `bind_mode: "custom"`. Legacy configs with no `bind_mode` key keep the old behaviour: Tailscale IP if detected, else `bind_host`, plus 127.0.0.1 |
| `data_dir` | `<server-dir>/data` | Runtime data: `inbox/` (uploads), `jobs/` (per-job dirs), `sessions/` (per-session meta) |
| `default_workdir` | `null` | Working directory for jobs that omit `workdir`. Set it (e.g. your main project dir) |
| `token` | `null` | Bearer token. `null` = env `LUNA_BRIDGE_TOKEN`, else the token file, else generate one on first run |
| `token_file` | `~/.config/luna-bridge/token` | Where a generated token is stored (0600) |
| `muse_bin` | `"muse"` | Agent CLI binary (Muse Code today; see "Which agent CLI does it run?"). Resolved via `which` at startup, logged. A full path or a wrapper script also works |
| `tmux_bin` | `"tmux"` | tmux binary for shared sessions (resolved via `which` at startup, logged). Headless jobs never touch tmux |
| `muse_args` | `[]` | Extra args appended to every `muse exec` call (after the mode flags). Example: `["--model", "muse-spark-1.3"]` |
| `mode` | `"unrestricted"` | Permission mode for new jobs (see below) |
| `default_model` | `null` | Default model id for runs (e.g. `"muse-spark-1.3"`). `null` = leave unset, let Muse Code decide. Per-request `model` overrides it |
| `default_effort` | `null` | Default reasoning-effort tier (`none\|minimal\|low\|medium\|high\|xhigh\|max\|ultra`). `null` = leave unset (Muse Code default `high` applies). Per-request `effort` overrides it |
| `sync_muse_settings` | `false` | If `true`, `POST /mode` also writes `permissions.default_profile` into `~/.config/muse/settings.json`. Off by default — changing interactive Muse Code settings is opt-in |
| `keep_awake` | `false` | Opt-in, macOS only. `true` = hold an idle-sleep assertion (built-in `caffeinate -i -w <pid>`) while the bridge runs, so the Mac stays online. The Mac will not idle-sleep while the daemon is up — mind battery/heat on a laptop. See "Keeping the Mac awake". On other platforms it logs macOS-only and the bridge runs normally |
| `max_model_steps` | `300` | Cap on model steps per job (`0` = no cap). Prevents runaway quota burn |
| `prompt_via_file` | `true` | Pass the prompt via `--prompt-file` (prompt is also saved as `prompt.txt` in the job dir for audit). Set `false` to pass it as a positional argument |
| `use_workspace_flag` | `true` | Pass `--workspace <workdir>` to `muse exec`. Reported in community docs; verify with `muse exec --help` — set `false` if your version rejects it |
| `max_upload_bytes` | `26214400` (25 MB) | Upload size limit |
| `max_prompt_bytes` | `204800` (200 KB) | Prompt size limit |
| `max_json_bytes` | `524288` (512 KB) | JSON body limit |
| `max_output_tail_bytes` | `204800` (200 KB) | In-memory/returned output tail per job |
| `cancel_grace_ms` | `3000` | SIGTERM → SIGKILL delay on cancel |

Environment overrides: `LUNA_BRIDGE_CONFIG` (config file path),
`LUNA_BRIDGE_TOKEN` (bearer token).

## Permission modes

The bridge maps its `mode` to `muse exec` flags. Verified against Meta's
official docs (`dev.meta.ai/docs/muse-code/permissions`, crawled 2026-11-05)
and the Muse Code CLI cheat sheet (musecodes.io, CLI 1.4.13). Confirm with
`muse exec --help` on your machine if a flag is ever rejected.

| Bridge mode | Flags | Meaning |
|---|---|---|
| `unrestricted` | `--yolo` | No approval, no sandbox, workspace trusted (= Unrestricted profile). This is the shipped default — read "Security model" before keeping it |
| `auto-review` | (none) | Default posture; an automated judge clears routine approvals |
| `ask-me` | `--approval-mode on-request --approval-judge off` | Every eligible approval goes to the user — in a headless run there is no user to answer, so the job stalls; the bridge reports `approval_blocked: true` |
| `read-only` | `--disable-write --disable-shell` | Read-only (reported in community docs; verify with `muse exec --help`) |

Every run also gets `--trust-workspace` (avoids the first-run trust prompt)
and `--max-model-steps <cap>` when the cap is > 0. When a model and/or
effort is set (per request or via `default_model`/`default_effort`), the
run also gets `--model <ID>` and/or `--reasoning-effort <TIER>` (verified
with `muse --help` and `muse exec --help`: both the interactive TUI and
`muse exec` accept `--model` and `--reasoning-effort`, alias `--effort`).
Other verified
`muse exec` flags: `--json` (JSONL events), `--prompt-file <path>`,
`--session-id <uuid>`, `--no-session-log`. Exit codes: `0` done,
`1` failed or cancelled (incl. step limit), `2` usage error, `130`/`143`
interrupted. A `0` does not mean the code is right — run the tests.

The bridge reads the Muse Code default profile from
`~/.config/muse/settings.json` (`permissions.default_profile`) for
`GET /mode` (best effort; `null` if the file is missing). `POST /mode`
changes the bridge's mode for subsequently started jobs. Luna only switches
the mode after the user explicitly allows it — never silently.

## Model and effort controls

Both `POST /jobs` and `POST /sessions` accept optional `model` and
`effort` fields to pick the model and reasoning effort per run:

```sh
curl --proxy "$tunnel_proxy" -X POST -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"Summarize the checkout flow briefly.","workdir":"/Users/you/Projects/my-app","model":"muse-spark-1.3","effort":"low"}' \
  "http://$TAIL:8787/jobs"
```

- `model`: free-form model id string, e.g. `muse-spark-1.3`,
  `muse-wonder-1.0`, `muse-wonder-full-1.0`. Must be a non-empty string
  (anything else → 400). Passed as `--model <ID>`.
- `effort`: one of `none`, `minimal`, `low`, `medium`, `high`, `xhigh`,
  `max`, `ultra` (anything else → 400). Passed as
  `--reasoning-effort <TIER>`.
- Omit a field (or send `null`) to fall back to the config defaults
  `default_model` / `default_effort`. Both default to `null` (unset):
  no flag is passed and Muse Code decides (`high` effort by default).
  Per-request values override the defaults.
- The effective `model`/`effort` are recorded in the job/session
  `meta.json` and returned by `GET /jobs/:id`, `GET /sessions/:id`,
  and the session-creation response.

## Security model

- **Network**: binds only to the addresses chosen by `bind_mode`
  (default `auto`: Tailscale IP if detected + 127.0.0.1, else 127.0.0.1
  only — see "Choosing a transport"). Never `0.0.0.0`. With the private
  transports (localhost, Tailscale), only this Mac or devices the user
  approved can reach the port at all; LAN/custom/public-tunnel choices
  widen that reach exactly as the transport table says, which is why
  the choice is explicit.
- **Auth**: Bearer token on every endpoint except `GET /health`.
  Compared in constant time. A generated token is saved to `~/.config/luna-bridge/token`; Luna reads it from that file when needed.
- **Execution allowlist**: the server only ever spawns the `muse` binary.
  It never runs arbitrary shell commands from requests — no shell is involved
  (direct `spawn` with an argv array). Jobs run as the Mac user that runs the
  server, with that user's environment.
- **Input validation**: job ids, paths, modes, and sizes are validated;
  attachments must live under the inbox dir; uploads are sanitized to a
  basename (no path traversal); anything unexpected is rejected with 400.
- **Logging**: requests are logged (method, path, job id) to stdout —
  launchd redirects that to `logs/bridge.out.log`, a foreground run
  shows it in the terminal. Prompts are never logged in full (only a
  short preview in the job-start line at most), and the token is never
  logged, in either mode.
- **Revocation**: close the bridge (`luna-bridge stop`; or remove it
  with `sh scripts/uninstall.sh`), change the token, or remove the
  device from the Tailscale admin console.

## Files

```
server.js                  the server (Node stdlib only, zero dependencies)
config.example.json        example config (copy to config.json, never commit a real one)
.gitignore                 config.json, token, .env, data/, logs/
launchd/com.luna.bridge.plist   launchd agent sample
scripts/install.sh         install + load the launchd agent, install the luna-bridge command
scripts/luna-bridge        terminal command: start | stop | restart | status | foreground (open/close the bridge)
scripts/uninstall.sh       unload the launchd agent, remove the luna-bridge command
test/fake-muse.sh          TEST FIXTURE: pretends to be the muse CLI
test/run-tests.sh          end-to-end tests (fake muse + curl), run: sh test/run-tests.sh
docs/setup-guide.md        full guide: install, day-to-day use, transports
docs/setup-guide-ru.md     the same guide in Russian
README.md                  this file
SETUP.md                   step-by-step Mac setup
SECURITY.md                how to report a vulnerability + security model
LICENSE                    MIT license
```

## Testing

On a machine without Muse Code, the tests use a fake `muse` executable:

```sh
sh test/run-tests.sh   # 217 checks: health, auth, upload, jobs, model/effort, cancel, mode, sessions, 400s, bind_mode transports, keep_awake, luna-bridge CLI, --foreground
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
(its flags are documented above from Meta's docs, not from a live binary),
binding to a real Tailscale address (the suite uses a fake `tailscale`
CLI reporting a bindable local address), and an end-to-end
curl-through-tunnel path from a remote client to the Mac.

## Open questions

- `muse exec --help` on the Mac should be run once to confirm the flags
  (`--prompt-file`, `--workspace`, `--max-model-steps`, `--yolo`) against
  your installed Muse Code version.
- Whether completion should be pushed anywhere else, or polling by Luna
  (every couple of minutes while a job runs) is enough.

Answered: watching the work happen no longer needs AppleScript into a
visible terminal — shared sessions (tmux) cover it: the owner attaches
with `tmux attach -t luna-<id>` while Luna reads the pane.
