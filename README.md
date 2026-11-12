<div align="center">

<p align="center"><img src="assets/logo.png" width="160" alt="muse-bridge logo"></p>

<h1>muse-bridge</h1>

<p><strong>Send a coding task from anywhere. Your Mac does the work.</strong><br>
A tiny, token-gated HTTP bridge that runs your terminal coding agent on your own Mac — you decide when it is open.</p>

<p>
<a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License: MIT"></a>
<a href="SETUP.md"><img src="https://img.shields.io/badge/platform-macOS-000000.svg?logo=apple&logoColor=white" alt="Platform: macOS"></a>
<a href="SETUP.md"><img src="https://img.shields.io/badge/node-%E2%89%A518-339933.svg?logo=node.js&logoColor=white" alt="Node ≥ 18"></a>
<a href="#testing"><img src="https://img.shields.io/badge/tests-260%20checks%20passing-brightgreen.svg" alt="Tests: 260 checks passing"></a>
</p>

<p>
<a href="#quick-start"><strong>Quick start</strong></a> ·
<a href="#choose-your-path">Choose your path</a> ·
<a href="#api">API</a> ·
<a href="#configuration">Configuration</a> ·
<a href="SETUP.md">Full setup guide</a> ·
<a href="SECURITY.md">Security</a>
</p>

</div>

---

## What it is

muse-bridge is a small HTTP server (Node.js stdlib only, **zero
dependencies**, no `npm install`) that runs on a developer's Mac and lets a
remote client — an AI agent, a script, or a phone app relaying through one
— run coding tasks with the terminal coding agent installed on that Mac.
The developer decides whether the bridge is open or closed at any moment:
online while it runs, offline the moment it stops, one terminal command
either way.

```
Client (e.g. an AI agent) → curl → private transport → muse-bridge (Mac)
                                                        → muse exec (headless)
                                                        → result back to client
```

The flow it was built for: the developer sends a task from their phone, a
remote agent passes it (screenshots included) to the bridge, the coding
agent does the work on the Mac, and the agent reports back with the result
and the "open a draft PR?" question — nothing is ever merged
automatically. The examples name the original client agent "Muse"; any
HTTP client that can send a Bearer [REDACTED] works the same way. Why HTTP and
not SSH? In the original setup SSH to the Mac was blocked by an egress
proxy that only forwards TLS/HTTPS, while HTTPS through a private tunnel
reaches the Mac with curl — so the bridge is HTTP over a private transport
you choose (see [Choosing a transport](#choosing-a-transport)). No SSH is
required.

## Quick start

Prerequisites: macOS, Node.js ≥ 18, and the Muse Code CLI installed and
signed in (plus tmux if you want shared sessions). Full step-by-step:
[SETUP.md](SETUP.md).

1. **Clone and configure**

   ```sh
   git clone https://github.com/romannmk/muse-bridge.git
   cd muse-bridge
   cp config.example.json config.json
   ```

   Edit `config.json` (gitignored, never commit a real one): set
   `default_workdir` (e.g. `/Users/you/Projects/my-app`) and `bind_mode`
   — your transport choice (see
   [Choosing a transport](#choosing-a-transport)).

2. **Install and start** (launchd agent + `muse-bridge` command)

   ```sh
   sh scripts/install.sh
   muse-bridge status
   curl http://127.0.0.1:8787/health
   # {"ok":true,"version":"0.1.0","mode":"auto-review"}
   ```

   Prefer it attached to a terminal for a first run? Skip `install.sh`
   and run `node server.js --foreground` (logs to stdout, Ctrl+C stops
   it). Same server, same `config.json` — background via launchd is just
   the default.

3. **Send your first job.** On first run with no token configured, the
   server generates a strong Bearer [REDACTED] and saves it to
   `~/.config/muse-bridge/token`. It is never printed or logged — clients
   read it from that file; never paste secrets in chat.

   ```sh
   TOKEN="$(cat ~/.config/muse-bridge/token)"
   curl -X POST -H "Authorization: Bearer $TOKEN" \
     -H 'Content-Type: application/json' \
     -d '{"prompt":"Run the test suite and summarize any failures.","workdir":"/Users/you/Projects/my-app"}' \
     http://127.0.0.1:8787/jobs
   # -> {"job_id":"…"}  then poll:  curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8787/jobs/<job_id>
   ```

   From a remote client, use the address of your transport instead of
   `127.0.0.1` (the startup log prints the exact "Listening on"
   addresses).

## Choose your path

<table width="100%">
<tr>
<td valign="top" width="50%">

**[Jobs — headless tasks](#jobs-headless-tasks)**

Fire-and-forget: POST a prompt (plus optional screenshots), poll for the
result, cancel if needed. Nobody watches; the agent works and reports
back.

</td>
<td valign="top" width="50%">

**[Shared sessions — watch & co-drive](#shared-sessions-owner--muse-in-one-terminal)**

The interactive agent TUI inside tmux: you attach from your terminal, the
client reads the pane and types only when you ask. One driver at a time.

</td>
</tr>
<tr>
<td valign="top" width="50%">

**[Permission modes](#permission-modes)**

How much freedom a run gets — from `read-only` to `unrestricted`
(`--yolo`) — plus per-run model and reasoning-effort controls.

</td>
<td valign="top" width="50%">

**[Choosing a transport](#choosing-a-transport)**

How a client reaches your Mac: localhost, Tailscale, Cloudflare Tunnel,
LAN, a custom address, or an SSH forward. An explicit choice, never
`0.0.0.0`.

</td>
</tr>
</table>

### Jobs (headless tasks)

1. The client uploads a file (e.g. a screenshot): `POST /upload` (raw
   body, `X-Filename` header). The file lands in the bridge's inbox
   directory on the Mac.
2. The client starts a job: `POST /jobs` with
   `{prompt, workdir, attachments}`. The bridge spawns `muse exec`
   (headless) in that working directory; the prompt references the
   uploaded files by their on-disk paths.
3. The client polls `GET /jobs/:id` for status and output, or cancels
   with `POST /jobs/:id/cancel`.
4. When the job is done, the client reports the result.

Job output is the combined stdout+stderr tail (up to 200 KB, see
`max_output_tail_bytes`); the full log is kept in the job directory on
disk (`data/jobs/<id>/log.txt`), along with `prompt.txt` and `meta.json`.
`approval_blocked: true` in job status means the output looks like the
run stalled on an approval request (heuristic marker scan — a job that
hangs with no output at all is invisible to it; see
[Permission modes](#permission-modes)).

### Shared sessions (owner + Muse in one terminal)

When the owner wants to sit with the agent — see what it does, take over
typing, hand control back — the client starts a shared session instead of
a job:

```sh
curl -X POST -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"Continue the checkout work; I am watching.","workdir":"/Users/you/Projects/my-app"}' \
  "http://<mac-address>:8787/sessions"
# -> {"session_id":"…","tmux_session":"muse-…",
#     "attach_command":"tmux attach -t muse-…", …}
```

The bridge runs `tmux new-session -d -s muse-<id> -c <workdir> muse <mode
flags> "<prompt>"` — the interactive `muse` TUI with the same mode flags
as jobs (`unrestricted` → `--yolo`, always plus `--trust-workspace` so
the trust prompt never blocks a shared session).

- **Owner attaches** from any terminal on the Mac with the returned
  `attach_command` (`tmux attach -t muse-<id>`). Detach with `Ctrl-b d`;
  the session keeps running.
- **Muse reads** with `GET /sessions/:id/pane` (pane text plus an `idle`
  hint) and polls it the same way she polls jobs.
- **Muse types** with `POST /sessions/:id/input` (`{text}` sends the text
  plus Enter via `tmux send-keys`) — **only when the owner explicitly
  asks**. Otherwise she only reads.
- **Either side ends it** with `POST /sessions/:id/kill`.

**One-driver rule: only one party types at a time.** Typed input goes to
the same prompt either way, so simultaneous typing garbles it — this is a
standing agreement, not a lock the bridge can enforce. Sessions survive a
bridge restart (the tmux server is independent; every read reconciles
status with live `tmux has-session` state, `alive`/`dead`). Session meta
lives under `data/sessions/<id>/` (`meta.json`, `prompt.txt`).

### Permission modes

The bridge maps its `mode` to `muse exec` flags (verified against Meta's
official docs — `dev.meta.ai/docs/muse-code/permissions`, crawled
2026-11-05 — and the Muse Code CLI cheat sheet, musecodes.io, CLI 1.4.13;
confirm with `muse exec --help` on your machine if a flag is ever
rejected):

| Bridge mode | Flags | Meaning |
|---|---|---|
| `unrestricted` | `--yolo` | No approval, no sandbox, workspace trusted — switch to it only deliberately; read [Security model](#security-model) first |
| `auto-review` | (none) | No mode flags at all — the Muse Code settings profile governs (see below); with the Auto-review profile, an automated judge clears routine approvals. Shipped default |
| `ask-me` | `--approval-mode on-request --approval-judge off` | Every eligible approval goes to the user — headless runs stall (bridge reports `approval_blocked: true` when it can tell) |
| `read-only` | `--disable-write --disable-shell` | Read-only (reported in community docs; verify with `muse exec --help`) |

Every run also gets `--trust-workspace` and `--max-model-steps <cap>`
when the cap is > 0. `GET /mode` reports the current mode (plus the Muse
Code default profile from `~/.config/muse/settings.json`, best effort);
`POST /mode` changes it for subsequently started jobs (persisted). Muse
only switches the mode after the user explicitly allows it — never
silently.

**Two layers must agree.** The bridge mode is only the first layer: it
decides which flags the bridge passes. The second layer is Muse Code's
own default permission profile, `permissions.default_profile` in
`~/.config/muse/settings.json` (values Muse Code itself writes look
like `:auto-review`, `:unrestricted`). The layers interact per mode:

- `unrestricted`, `ask-me`, and `read-only` pass explicit flags, so the
  bridge mode is what the run gets.
- `auto-review` passes **no flags**, so the settings profile governs the
  run. If that profile is `:unrestricted`, an `auto-review` bridge run
  behaves Unrestricted — no approvals, no sandbox — despite the bridge
  mode name. The bridge mode alone does not tell you the posture.

**Recommended setup: set both layers to auto-review** — bridge `mode`:
`auto-review` and settings `default_profile`: `:auto-review`. Check both
at any time with `GET /mode`: it returns `mode`,
`muse_settings_profile`, and `muse_args_for_mode` (the exact flags the
current mode passes; empty for `auto-review`).

**`sync_muse_settings` caveat.** With `sync_muse_settings: true`,
`POST /mode` also writes the mode into `permissions.default_profile`
(default `false` — changing your interactive Muse Code settings is
opt-in). Know what it writes: the bridge stores the colon-prefixed
profile id (`:auto-review`), the same form Muse Code itself uses for
its built-in profiles.

**Headless jobs vs live sessions: who answers an approval?** A headless
job (`muse exec` with piped output) has no input channel — the bridge
can read its output and cancel it, nothing more. So:

- In `ask-me`, a headless job stalls on the first approval: the prompt
  waits for a person, and there is nobody who can answer it. The only
  remedies are cancel (`POST /jobs/:id/cancel`) and restarting in a mode
  that does not ask.
- In `auto-review` (with the Auto-review settings profile), Muse Code's
  automated judge clears routine approvals, so headless jobs can run
  unattended without dropping to `unrestricted`.
- Approving from your phone works **only through a live shared tmux
  session**: the approval prompt is visible in the pane
  (`GET /sessions/:id/pane`), and it can be answered there — by you
  attached from a terminal, or by Muse typing the answer via
  `POST /sessions/:id/input` on your explicit word (one-driver rule
  applies). There is no equivalent for a headless job.

**The `approval_blocked` detector — and its blind spot.** The bridge
scans each chunk of job output against a marker regex (`approval
required`, `waiting for approval`, `needs approval`, `approval
request`, `permission denied`, `permission required`) and sets
`approval_blocked: true` in the job status on a match. It is a
heuristic over output text only: **a job that hangs silently, producing
no output at all, keeps `approval_blocked: false`** — there is no text
to match (this is exactly how a stalled-at-startup run looks). So
`false` does not mean healthy: a job that stays `running` with an empty
or frozen output tail deserves suspicion, and cancelling it is the
remedy. The full log stays on disk at `data/jobs/<id>/log.txt` either
way.

**Model and effort, per run.** Both `POST /jobs` and `POST /sessions`
accept optional `model` and `effort`:

- `model`: free-form model id (e.g. `muse-spark-1.3`, `muse-wonder-1.0`,
  `muse-wonder-full-1.0`); must be a non-empty string, else 400. Passed
  as `--model <ID>`.
- `effort`: one of `none|minimal|low|medium|high|xhigh|max|ultra`, else
  400. Passed as `--reasoning-effort <TIER>` (both `muse --help` and
  `muse exec --help` accept `--model` and `--reasoning-effort`, alias
  `--effort`).
- Omitted or `null` falls back to `default_model` / `default_effort`
  (both default to `null` = Muse Code decides; its effort default is
  `high`). Per-request values win. The effective values are recorded in
  the job/session `meta.json` and returned by the GET endpoints.

Other verified `muse exec` flags: `--json`, `--prompt-file <path>`,
`--session-id <uuid>`, `--no-session-log`. Exit codes: `0` done, `1`
failed or cancelled (incl. step limit), `2` usage error, `130`/`143`
interrupted. A `0` does not mean the code is right — run the tests.

### Choosing a transport

How a client *reaches* the bridge is a separate, explicit choice — **make
it at install time**: set `bind_mode` (and `bind_host` for `custom`) in
`config.json` before running `scripts/install.sh`. The installer writes
the default (`auto`) when unset and prints the active choice; at startup
the server logs the exact addresses it listens on. Tailscale is **one
option among equals, not a requirement** — with no Tailscale installed,
the bridge runs on localhost.

| Option | What to install | What is exposed to whom | Trade-off |
|---|---|---|---|
| Localhost only (`bind_mode: "localhost"`, or `"auto"` with no Tailscale IP) | Nothing | The port exists only on this Mac (`127.0.0.1`); nothing on any network can reach it | Safest and dependency-free, but by itself no remote client can connect |
| Tailscale — private mesh VPN (`bind_mode: "tailscale"`, or `"auto"` with Tailscale present) | Tailscale app + account, on the Mac and each client | The port on the Mac's `100.x.x.x` tailnet address, only to devices you approved | Private and simple, but depends on a third-party service and account |
| Cloudflare Tunnel — public URL via outbound relay (`bind_mode: "localhost"` + tunnel to `127.0.0.1:8787`) | `cloudflared` on the Mac (+ Cloudflare account/domain for a named tunnel) | A public HTTPS URL; anyone who knows it can reach the port (Bearer [REDACTED] still gates the API) | Reachable anywhere with no open inbound ports, but public and traffic transits Cloudflare — keep the token secret, consider Cloudflare Access |
| LAN (`bind_mode: "lan"`) | Nothing | The port on the Mac's LAN IP, to every device on the same local network | Dependency-free remote access at home, but anyone on that network can reach the port (token still required) |
| Custom address (`bind_mode: "custom"` + `bind_host: "<ip-or-hostname>"`) | Nothing | The port on exactly the `bind_host` address, to whatever network it belongs to | Full manual control, but you own the exposure decision; startup fails if `bind_host` is missing or invalid |
| SSH port forward (`ssh -L 8787:127.0.0.1:8787 <mac>`, with `bind_mode: "localhost"`) | SSH server on the Mac (macOS Remote Login) + SSH client | Nothing new: client reaches its own `127.0.0.1:8787`, forwarded over SSH | Reuses existing SSH trust and keys, but the client must hold the `ssh -L` connection open and be able to SSH at all |

Notes: `"auto"` (default) = Tailscale IP if detected plus `127.0.0.1`,
else `127.0.0.1` only (missing `tailscale` CLI is never an error).
`"tailscale"` and `"lan"` fail loudly at startup when their address does
not exist. The bridge never binds `0.0.0.0`. Configs written before
`bind_mode` existed keep working as before. The transport is independent
of how the bridge runs (background or foreground bind the same
addresses).

## Opening and closing the bridge

**Background by default.** `scripts/install.sh` installs the bridge as a
launchd agent (`com.muse.bridge`): it starts at login, launchd restarts
it if it exits (`KeepAlive`), logs go to `logs/bridge.out.log` /
`logs/bridge.err.log`. There is no cloud component and nothing always-on:
**online while it is running, offline when it is stopped** — the same
presence semantics as Codex (app open = online, app closed = offline).
The installer also puts a small `muse-bridge` command in `~/.local/bin`
(it says so if that directory is not on your `PATH` yet). Day to day:

```sh
muse-bridge start       # open the bridge (load the launchd agent, then check health)
muse-bridge stop        # close the bridge (unload the launchd agent)
muse-bridge restart     # unload + load (e.g. after editing config.json)
muse-bridge status      # agent loaded? bridge pid? health?
muse-bridge foreground  # run the bridge in this terminal instead (see below)
```

`start`/`stop`/`restart`/`status` wrap `launchctl load`/`unload` plus a
`curl` health check; `start`/`stop` are idempotent, `status` exits
non-zero when the bridge is not loaded or not healthy. The health check
defaults to `http://127.0.0.1:8787/health`; if your `bind_mode` does not
listen on 127.0.0.1 (`tailscale`/`lan`/`custom`), point it at the
"Listening on" address: `MUSE_BRIDGE_HEALTH_URL=http://<that-address>:8787/health muse-bridge status`
(`MUSE_BRIDGE_PORT` overrides just the port). To remove the bridge
entirely: `sh scripts/uninstall.sh`.

**Foreground mode** (`muse-bridge foreground`) runs the same server
attached to your terminal: logs to stdout, Ctrl+C (or closing the
window) stops it — use it for a first run, debugging, or when you want
the bridge open only while you are at the Mac. It refuses to start while
the background agent is loaded (`muse-bridge stop` first). Under the hood
it runs `node server.js --foreground`, which you can also start directly
from the repo (`node server.js --help` lists the flags).

**Keeping the Mac awake (optional).** A sleeping Mac cannot answer, so
`keep_awake: true` in `config.json` makes the bridge hold a macOS
idle-sleep assertion (built-in `caffeinate -i -w <bridge pid>`, spawned at
startup, gone when the bridge stops) — online always while the bridge
runs, background or foreground. Trade-off, stated plainly: while the
bridge is up the Mac will not idle-sleep at all (battery drain and heat
on an unplugged laptop — plug in or stop the bridge). Closing the lid or
choosing Sleep still sleeps it. Off by default; on non-macOS systems it
logs that keep-awake is unavailable and runs normally.

## API

Base URL: `http://<mac-address-for-your-transport>:8787` (default port
8787; the startup log prints the exact addresses). Every endpoint except
`GET /health` requires `Authorization: Bearer <token>`. All responses are
JSON.

| Method | Path | Description |
|---|---|---|
| GET | `/health` | `{ok, version, mode}` — no auth, for liveness checks |
| POST | `/upload` | Raw request body → file in the inbox dir. Filename from `X-Filename` header or `?name=` query (sanitized: basename only). Returns `{path, name, size}` (201) |
| POST | `/jobs` | `{prompt, workdir?, attachments?, mode?, model?, effort?}` → `{job_id}` (202). `workdir` must exist; `attachments` must be paths under the inbox dir. `model`/`effort`: see [Permission modes](#permission-modes) |
| GET | `/jobs/:id` | `{status, exit_code, output, approval_blocked, started_at, finished_at, workdir, ...}`. `status`: `queued \| running \| done \| failed \| cancelled` |
| GET | `/jobs` | Recent jobs (id, status, started_at, prompt preview), newest first |
| POST | `/jobs/:id/cancel` | Kill the job's process group. Returns `{id, status}` |
| POST | `/sessions` | `{prompt, workdir?, mode?, model?, effort?}` → `{session_id, tmux_session, attach_command, workdir, mode, model, effort, status}` (201). Starts interactive `muse` with the prompt inside a detached tmux session |
| GET | `/sessions` | Live sessions (id, tmux name, `alive`/`dead`, attach command), newest first. Status is reconciled with `tmux has-session` on every read, so sessions survive a bridge restart |
| GET | `/sessions/:id` | One session's meta + live status |
| GET | `/sessions/:id/pane` | `{id, status, pane, idle}` — `tmux capture-pane` text plus a best-effort `idle` hint |
| POST | `/sessions/:id/input` | `{text}` — type text + Enter into the session via `tmux send-keys` (one-driver rule: only when the owner explicitly asks) |
| POST | `/sessions/:id/kill` | Kill the tmux session. Returns `{id, status: "dead"}` |
| GET | `/mode` | `{mode, muse_settings_profile, muse_args_for_mode}` |
| POST | `/mode` | `{mode}` — set the mode for subsequently started jobs (persisted) |

Example (from a remote client; use your transport's address):

```sh
BRIDGE="http://<mac-address>:8787"   # e.g. your Mac's Tailscale IP (`tailscale ip`), LAN IP, or 127.0.0.1
TOKEN="<Bearer [REDACTED]>"               # clients read it from ~/.config/muse-bridge/token on the Mac

# upload a screenshot
curl -X POST -H "Authorization: Bearer $TOKEN" \
  -H 'X-Filename: failure.png' --data-binary @failure.png \
  "$BRIDGE/upload"

# start a job (attachments are the paths returned by /upload)
curl -X POST -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"Fix the failing test shown in the screenshot at <path>. Switch to main, pull, create a new branch fix/..., do the fix.","workdir":"/Users/you/Projects/my-app","attachments":["<path>"]}' \
  "$BRIDGE/jobs"

# poll status, then cancel if needed
curl -H "Authorization: Bearer $TOKEN" "$BRIDGE/jobs/<job_id>"
curl -X POST -H "Authorization: Bearer $TOKEN" "$BRIDGE/jobs/<job_id>/cancel"
```

(If your client reaches the Mac through a proxy — as the original remote
agent does — add `--proxy "${HTTPS_PROXY%:*}:3130"` to each curl.)

## Configuration

`config.json` (copy from `config.example.json`; never commit a real one —
it is gitignored). All keys are optional; defaults are shown in the
example.

| Key | Default | Meaning |
|---|---|---|
| `port` | `8787` | HTTP port |
| `bind_mode` | `"auto"` | Transport choice (see [Choosing a transport](#choosing-a-transport)): `auto`, `localhost`, `tailscale`, `lan`, `custom` |
| `bind_host` | `null` | IP/hostname to listen on; used (and required) by `bind_mode: "custom"`. Legacy configs with no `bind_mode` key keep the old behaviour (Tailscale IP if detected, else `bind_host`, plus 127.0.0.1) |
| `data_dir` | `<server-dir>/data` | Runtime data: `inbox/` (uploads), `jobs/`, `sessions/` |
| `default_workdir` | `null` | Working directory for jobs that omit `workdir` — set it (e.g. your main project dir) |
| `allowed_workdirs` | `null` | Optional array of absolute paths (e.g. `["/Users/you/Projects"]`). When set and non-empty, `POST /jobs` and `POST /sessions` reject (403) any `workdir` — including the default — that is not equal to or inside one of these dirs, after `~` expansion, `..` normalization, and symlink resolution. `null`/absent/empty = no restriction. Start directory only: see [Security model](#security-model) |
| `token` | `null` | Bearer [REDACTED] `null` = env `MUSE_BRIDGE_TOKEN`, else the token file, else generate one on first run |
| `token_file` | `~/.config/muse-bridge/token` | Where a generated token is stored (0600) |
| `muse_bin` | `"muse"` | Agent CLI binary (Muse Code today; a full path or wrapper script also works). Resolved via `which` at startup, logged |
| `tmux_bin` | `"tmux"` | tmux binary for shared sessions (resolved via `which` at startup, logged). Headless jobs never touch tmux |
| `muse_args` | `[]` | Extra args appended to every `muse exec` call (after the mode flags), e.g. `["--model", "muse-spark-1.3"]` |
| `mode` | `"auto-review"` | Permission mode for new jobs (see [Permission modes](#permission-modes)) |
| `default_model` | `null` | Default model id (e.g. `"muse-spark-1.3"`). `null` = Muse Code decides. Per-request `model` overrides it |
| `default_effort` | `null` | Default effort tier (`none\|minimal\|low\|medium\|high\|xhigh\|max\|ultra`). `null` = Muse Code decides (`high`). Per-request `effort` overrides it |
| `sync_muse_settings` | `false` | If `true`, `POST /mode` also writes `permissions.default_profile` into `~/.config/muse/settings.json` (opt-in). Writes the colon-prefixed profile id (e.g. `:auto-review`), as Muse Code itself does — see [Permission modes](#permission-modes) |
| `keep_awake` | `false` | macOS only: hold an idle-sleep assertion (`caffeinate -i -w <pid>`) while the bridge runs. No idle sleep while up — mind battery/heat |
| `max_model_steps` | `300` | Cap on model steps per job (`0` = no cap). Prevents runaway quota burn |
| `prompt_via_file` | `true` | Pass the prompt via `--prompt-file` (also saved as `prompt.txt` in the job dir for audit). `false` = positional argument |
| `use_workspace_flag` | `true` | Pass `--workspace <workdir>` to `muse exec` (reported in community docs; set `false` if your version rejects it) |
| `max_upload_bytes` | `26214400` (25 MB) | Upload size limit |
| `max_prompt_bytes` | `204800` (200 KB) | Prompt size limit |
| `max_json_bytes` | `524288` (512 KB) | JSON body limit |
| `max_output_tail_bytes` | `204800` (200 KB) | In-memory/returned output tail per job |
| `cancel_grace_ms` | `3000` | SIGTERM → SIGKILL delay on cancel |

Environment overrides: `MUSE_BRIDGE_CONFIG` (config file path),
`MUSE_BRIDGE_TOKEN` (Bearer [REDACTED]).

## Security model

**One line:** the bridge is reachable only over the private transport you
choose, every call needs a Bearer [REDACTED] token, and whoever holds that token
can run the agent as you — so treat it like full access to your Mac.
Full policy and private reporting: [SECURITY.md](SECURITY.md).

- **Network:** binds only to the addresses chosen by `bind_mode` (default
  `auto`); never `0.0.0.0`. Private transports (localhost, Tailscale)
  mean only this Mac or devices you approved can reach the port at all;
  LAN/custom/public-tunnel choices widen that exactly as the transport
  table says — which is why the choice is explicit.
- **Auth:** Bearer [REDACTED] on every endpoint except `GET /health`, compared
  in constant time. A generated token is saved to
  `~/.config/muse-bridge/token` and never printed or logged.
- **Execution allowlist:** the server only ever spawns the configured
  agent binary (plus tmux for sessions, and opt-in `caffeinate`). It
  never runs arbitrary shell commands from requests — direct `spawn`
  with an argv array, no shell. Jobs run as the Mac user that runs the
  server, with that user's environment.
- **Permission posture:** the bridge `mode` and Muse Code's settings
  profile (`permissions.default_profile`) are two layers, and in
  `auto-review` the settings profile governs because the bridge passes
  no flags — a `:unrestricted` profile makes the run Unrestricted. Set
  both layers deliberately; see [Permission modes](#permission-modes).
- **Input validation:** job ids, paths, modes, and sizes are validated;
  attachments must live under the inbox dir; uploads are sanitized to a
  basename (no path traversal); anything unexpected is a 400.
- **Working-directory allowlist (optional):** set `allowed_workdirs`
  (array of absolute paths) to confine where jobs and sessions may
  *start*: both `POST /jobs` and `POST /sessions` then reject with
  `403` any `workdir` — including `default_workdir` — outside the
  listed folders, after expanding `~`, normalizing `..`, and resolving
  symlinks. Absent or empty means no restriction (the original
  behaviour). **Honest limitation:** this guards the start directory
  only. The agent process still runs as your macOS user and can `cd`
  elsewhere inside a session; true confinement would need OS-level
  sandboxing (`sandbox-exec` or a separate user) and is out of scope
  here.
- **Logging:** requests are logged (method, path, job id). Prompts are
  never logged in full, the token never at all, in either mode.
- **Revocation:** stop the bridge (`muse-bridge stop`, or
  `sh scripts/uninstall.sh`), rotate the token (delete the token file,
  restart), or remove the device from the Tailscale admin console.

## Which agent CLI does it run?

**Muse-first, today.** The bridge's API is agent-agnostic (any HTTP
client can drive it), but what it *runs* on the Mac is purpose-built for
**Muse Code** (Meta's terminal coding agent): it spawns the configured
binary (`muse_bin`, default `muse`) as `muse exec …` for headless jobs
and as the interactive `muse` TUI for shared sessions, and it maps its
permission modes, model, and effort controls onto Muse Code flags
(`--yolo`, `--prompt-file`, `--workspace`, `--reasoning-effort`, …). The
binary path and extra args are configurable (`muse_bin`, `muse_args`),
so a wrapper script can adapt the invocation — but other terminal coding
agents use different subcommands and flags, so pointing `muse_bin` at
them directly will not work yet.

### Roadmap

- **Other terminal coding agents (Codex, Claude Code, …)** via per-agent
  profiles for the flag mapping. This is a known follow-up, **not**
  supported today — do not expect drop-in compatibility yet.
- Open question: whether job completion should be pushed somewhere, or
  client polling (every couple of minutes while a job runs) is enough.

Before first real use, run `muse exec --help` once on the Mac to
confirm the flags against your installed Muse Code version (see
[SETUP.md](SETUP.md), step 7).

## Testing

```sh
sh test/run-tests.sh   # 260 checks, end-to-end with a fake `muse` + curl (no Muse Code needed)
```

Covered: health/auth (401s), upload + traversal sanitizing, job lifecycle
incl. failing jobs and process-group cancel, mode get/set and 400s,
model/effort passthrough to the agent argv, the `allowed_workdirs`
allowlist (unit + end-to-end: inside accepted, outside/`..`/symlink
escapes rejected with 403, unset = no restriction), shared sessions
against real
tmux (create, pane, input, kill, survival across a bridge restart),
`bind_mode` transport binding (unit + end-to-end with a fake `tailscale`
CLI), keep-awake (unit + end-to-end with a fake `caffeinate`), the
`muse-bridge` CLI against fake `launchctl`/`curl`, and foreground mode.
Session tests are skipped with a note on machines without tmux. The full
coverage breakdown lives in
[SETUP.md § "Appendix: test coverage in detail"](SETUP.md#appendix-test-coverage-in-detail).

Not tested here (needs a real setup): the real `muse exec`, binding to
a real Tailscale address, and an end-to-end curl-through-tunnel path from
a remote client to the Mac.

## Documentation & files

- [SETUP.md](SETUP.md) — step-by-step Mac setup, troubleshooting, test
  coverage appendix
- [SECURITY.md](SECURITY.md) — how to report a vulnerability + security
  model in brief
- [docs/setup-guide.md](docs/setup-guide.md) — full guide: install,
  day-to-day use, transports ([Russian version](docs/setup-guide-ru.md))

```
server.js                  the server (Node stdlib only, zero dependencies)
config.example.json        example config (copy to config.json, never commit a real one)
launchd/com.muse.bridge.plist   launchd agent sample
scripts/install.sh         install + load the launchd agent, install the muse-bridge command
scripts/muse-bridge        terminal command: start | stop | restart | status | foreground
scripts/uninstall.sh       unload the launchd agent, remove the muse-bridge command
test/fake-muse.sh          TEST FIXTURE: pretends to be the muse CLI
test/run-tests.sh          end-to-end tests (fake muse + curl): sh test/run-tests.sh
docs/                      full setup guide (EN + RU)
README.md / SETUP.md / SECURITY.md / LICENSE
```

## License

[MIT](LICENSE) — see the `LICENSE` file.
