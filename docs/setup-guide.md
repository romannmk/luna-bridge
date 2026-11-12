# Luna Bridge — complete guide: installation, day-to-day use, and going open source

> English version. Russian version: [setup-guide-ru.md](setup-guide-ru.md).

> A tiny HTTP bridge between a remote AI agent and Muse Code on your Mac.
> The agent sends a task (and a screenshot), the bridge runs `muse`
> locally, the agent collects the result and reports back. No SSH, no ports
> open to the internet.

## What it is and how it works

Luna Bridge is a single `server.js` file in plain Node.js (standard library
only, zero dependencies, no build step). It runs on a Mac as a launchd agent
(or in a terminal with `--foreground`) and does exactly three things:

1. Accepts files and tasks over HTTP with Bearer-token authorization.
2. Runs the Muse Code CLI (`muse exec` for headless jobs, or the
   interactive `muse` TUI inside tmux for shared sessions) in a working
   directory you name.
3. Returns job status, output, and live session screens to the client.

```text
Phone / chat (task + screenshot)
        |
        v
   Remote client (AI agent, script, ...)
        |  curl, HTTP(S) + Bearer token
        v
  Private transport ---------------+
  (Tailscale / LAN / tunnel / SSH) |
        v                          |
  luna-bridge on the Mac :8787 ---+
        |
        +-- muse exec "<task>"        -> headless job
        +-- tmux: interactive muse    -> shared session
        |
        v
  Result -> client -> report to the developer (+ "open a draft PR?")
```

The key architectural principle: **the network is a separate, replaceable
layer.** The bridge core does not know how a request reached the Mac. It
needs only an address to bind to and an HTTP request with a valid token.
That is why Tailscale can be dropped without rewriting the server (see
"Transports" below).

Status: version 0.1.0, in daily use. For the exact commands and config keys,
[README.md](../README.md) and [SETUP.md](../SETUP.md) are canonical; this
guide explains the whole flow end to end.

## What you need

### On the Mac (where the code runs)

| Component | Why | How to check |
|---|---|---|
| macOS, a normal user session | The server runs as your user, no sudo | — |
| Node.js 18+ (or Bun) | Server runtime; no dependencies | `node --version` |
| Muse Code CLI, signed in | The only agent binary the bridge runs today (see "Which agent CLI?" in README.md) | `muse --version`, `muse exec --help` |
| tmux | Shared sessions: an interactive `muse` you can attach to | `which tmux` (else `brew install tmux`) |
| git | Branches, worktrees, PRs — that is Muse Code's own work | `git --version` |
| A private route from the client | See "Transports" below | e.g. `tailscale ip` |

Remote Login (SSH) is **not** needed — the bridge was designed as an SSH
replacement. It is only needed if you pick the SSH port-forward transport.

### On the client side (whoever sends tasks)

- Any HTTP client that can send `Authorization: Bearer <token>` (in the
  original setup, a remote AI agent using `curl`).
- The client must know three things: the bridge base URL
  (`http://<mac-address>:8787`), the token, and the project directory.
- For the "from the phone" scenario, the developer only needs a chat with
  the agent: write the task, attach a screenshot, the agent does the rest.

### Accounts and quota

- A Muse Code subscription for the Mac's owner (jobs spend that quota;
  parallel sessions share one quota).
- Whatever repository access Muse Code needs for the work, exactly as in
  local use.
- An account with your chosen transport provider, if you use one
  (Tailscale, Cloudflare, …). LAN and localhost need none.

## Installing on the Mac, step by step

### Step 1. Install the prerequisites

```sh
brew install node tmux   # if not installed yet
```

Pick a transport as well (see "Transports" below). With the defaults the
bridge runs on localhost, so you can defer that choice.

### Step 2. Clone the project

```sh
git clone https://github.com/romannmk/luna-bridge.git
cd luna-bridge
```

### Step 3. Create your config

```sh
cp config.example.json config.json
```

`config.json` is listed in `.gitignore` and never leaves your machine. The
minimum worth setting:

- `bind_mode` (and `bind_host` for `custom`) — your transport choice. The
  default `auto` binds the Tailscale IP if one is detected, plus
  127.0.0.1; otherwise 127.0.0.1 only.
- `default_workdir` — the default project folder, e.g.
  `/Users/<you>/Projects/my-app`.
- `muse_bin` — the full path to `muse` if it is not on the PATH of the
  launchd environment (find it with `command -v muse`), e.g.
  `/Users/<you>/.local/bin/muse`.
- `mode` — the permission mode, `auto-review` by default.
  `unrestricted` runs tasks with no approval prompts and no sandbox;
  switch to it only deliberately (see "Security" below). Note the two layers: in
  `auto-review` the bridge passes no flags, so Muse Code's
  `permissions.default_profile` (in `~/.config/muse/settings.json`)
  governs the run — set both layers to auto-review for the recommended
  posture (see "Permission modes" below).
- Leave everything else at the defaults for the first run (full key
  reference below).

### Step 4. First run in the foreground — get a token

```sh
node server.js --foreground
```

If no token exists yet, the server generates a strong one (32 random bytes,
hex), saves it to `~/.config/luna-bridge/token` with mode `0600`, and logs
the file path. **The token value itself is never printed to stdout or the
logs** (under launchd, stdout lands in a log file — printing it there would
leak it).

Check the server is alive:

```sh
curl http://127.0.0.1:8787/health
# {"ok":true,"version":"0.1.0","mode":"auto-review"}
```

Stop it with Ctrl+C.

### Step 5. Give the token to the client

The client reads the token from `~/.config/luna-bridge/token` when it has
that access, or the owner passes the value once over a secure channel.
Never publish, commit, or attach the token to an issue. To rotate it:
delete the token file and restart the bridge — a new token is generated
and the old one stops working.

### Step 6. Install the launchd agent (starts at login)

```sh
sh scripts/install.sh
```

The script fills real paths into `launchd/com.luna.bridge.plist`, copies it
to `~/Library/LaunchAgents/com.luna.bridge.plist`, loads it, and installs
the `luna-bridge` terminal command to `~/.local/bin`. Logs:
`logs/bridge.out.log` and `logs/bridge.err.log` in the project folder.

Day to day, open and close the bridge with that command:

```sh
luna-bridge start       # open the bridge
luna-bridge stop        # close the bridge
luna-bridge restart     # reload (e.g. after editing config.json)
luna-bridge status      # loaded? pid? health?
luna-bridge foreground  # run in this terminal instead (stop first)
```

Remove everything with `sh scripts/uninstall.sh`.

### Step 7. Verify the Muse Code flags once

```sh
muse exec --help
```

The bridge relies on: `--yolo`, `--trust-workspace`, `--max-model-steps`,
`--prompt-file`, `--workspace`, `--model`, `--reasoning-effort`. If your CLI
version rejects one, turn it off in config (`prompt_via_file: false`,
`use_workspace_flag: false`) — no code change needed.

### Step 8. Check reachability from the client side

From the client's machine (or any device on the same private network):

```sh
curl http://<mac-address>:8787/health
```

The startup log prints `Listening on: …` plus a plain-language "How a
client reaches it" line. If it only lists 127.0.0.1 but you expected remote
access, your transport is not in place yet: check `bind_mode` and restart.

## Day-to-day use, step by step

### A normal task (headless job)

1. The developer sends the agent a task and attaches a screenshot.
2. The agent uploads the attachment: `POST /upload` (body = the file,
   name in the `X-Filename` header). The file lands in `data/inbox/` on
   the Mac; the bridge returns its path.
3. The agent starts a job: `POST /jobs` with
   `{prompt, workdir, attachments, model?, effort?}`. The prompt names the
   attachment paths. The bridge spawns `muse exec` in `workdir`.
4. The agent polls `GET /jobs/:id` until the status is `done`, `failed`,
   or `cancelled`. Full output is written to `data/jobs/<id>/log.txt`,
   next to `prompt.txt` and `meta.json` — you can `tail -f` it on the Mac.
5. The agent reports back and asks about a draft PR. **Nothing is merged
   automatically.**
6. To stop mid-flight: `POST /jobs/:id/cancel` (SIGTERM to the process
   group, SIGKILL after `cancel_grace_ms`).

### A shared session (interactive, the owner can join)

1. The agent creates a session: `POST /sessions` — the bridge starts the
   interactive `muse` TUI inside the tmux session `luna-<id>` with the
   initial prompt.
2. The owner joins the same live process on the Mac:

```sh
tmux attach -t luna-<id>
```

Detach without stopping the session: `Ctrl-B`, then `D`. Sessions survive
a bridge restart — tmux lives independently.

3. The agent reads the screen with `GET /sessions/:id/pane` — it sees
   both what the owner typed in the session and the agent's replies. The
   one-driver rule applies: while the owner is typing, the remote client
   does not write to the session.
4. The agent can send text into the session (`POST /sessions/:id/input`) —
   only when the owner explicitly asks.
5. Close it with `POST /sessions/:id/kill`.

Note: there is no live attach to a headless `muse exec` run — resuming in
Muse Code always starts a new process from the event log, and a running
session is locked. Interactive work therefore always goes through tmux
sessions.

### Parallel sessions in different worktrees

Parallelism is built in: every job is a separate process with its own
directory. A worktree is a plain git operation, done by Muse Code itself
when the prompt asks for it:

1. A preparatory job runs `git worktree add ../<proj>-<branch> <branch>`
   for each branch.
2. One job per worktree, each with a different `workdir` — they genuinely
   run at the same time.
3. Cleanup (remove worktrees and demo branches) is a separate job.

Caveats: one Muse Code quota is shared by everything; parallel builds may
contend for shared caches and dev-server ports; branches still merge
through separate PRs.

### Per-run model and effort

`POST /jobs` and `POST /sessions` accept two optional fields:

- `model` — a free-form model id, passed as `--model <ID>` (e.g. a hard
  task on a large model, a quick check on a small one).
- `effort` — one of `none | minimal | low | medium | high | xhigh | max |
  ultra`, passed as `--reasoning-effort <TIER>`; an invalid value gets a
  `400`.

Defaults come from `default_model` / `default_effort` in config
(`muse-ember-1.0` / `medium` by default — cheap by default; a `null`
value falls back to these defaults instead of leaving the flags unset).
The effective values are recorded in `meta.json` and returned in statuses.

## API reference

Base: `http://<mac-address>:8787`. Every endpoint except `GET /health`
requires `Authorization: Bearer <token>`. All responses are JSON.

| Method | Path | What it does |
|---|---|---|
| GET | `/health` | `{ok, version, mode}`, no auth |
| POST | `/upload` | Body = a file; stores it in `data/inbox/`, returns `{path, name, size}` (201) |
| POST | `/jobs` | `{prompt, workdir?, attachments?, mode?, model?, effort?}` → `{job_id}` (202) |
| GET | `/jobs` | Recent jobs, newest first |
| GET | `/jobs/:id` | Status, `exit_code`, output tail, `approval_blocked` |
| POST | `/jobs/:id/cancel` | Stop a job |
| POST | `/sessions` | Create a shared tmux session; returns the `tmux attach` command |
| GET | `/sessions`, `/sessions/:id` | List sessions / one session's status |
| GET | `/sessions/:id/pane` | Current session screen (capture-pane) + an idle hint |
| POST | `/sessions/:id/input` | Send text into the session |
| POST | `/sessions/:id/kill` | Close the session |
| GET | `/mode` | Current permission mode and its flags |
| POST | `/mode` | Set the mode for subsequent runs (persisted to config) |

Job statuses: `queued | running | done | failed | cancelled`. Output in
responses is a tail of up to `max_output_tail_bytes` (200 KB); the full log
is on disk at `data/jobs/<id>/log.txt`.

### Permission modes

| Bridge mode | `muse exec` flags | Meaning |
|---|---|---|
| `unrestricted` | `--yolo` | No approvals, no sandbox |
| `auto-review` | — (none) | No mode flags: the Muse Code settings profile governs; with the Auto-review profile, an automated judge clears routine approvals |
| `ask-me` | `--approval-mode on-request --approval-judge off` | Every approval goes to the user; headless jobs stall and the bridge reports `approval_blocked: true` when it can tell |
| `read-only` | `--disable-write --disable-shell` | Read only |

Every run also gets `--trust-workspace`, plus `--max-model-steps <cap>`
when a cap is set (default `300`; a per-job `max_model_steps` on
`POST /jobs` overrides it, `0` = no cap). The full headless template is
`muse exec <mode flags> --trust-workspace --model <ID>
--reasoning-effort <TIER> --max-model-steps <N> --workspace <workdir>
--prompt-file <job>/prompt.txt`. When the cap is hit, `muse exec` exits
`1` and the job is marked `failed` — that is the cap working, not a
crash: narrow the task or raise the cap and rerun.

**Two layers must agree.** The bridge mode only chooses the flags above.
The second layer is Muse Code's own default profile,
`permissions.default_profile` in `~/.config/muse/settings.json`
(Muse Code writes values like `:auto-review`, `:unrestricted`).
`unrestricted`, `ask-me`, and `read-only` pass explicit flags, so the
bridge mode decides. `auto-review` passes **no flags**, so the settings
profile governs: with `"default_profile": ":unrestricted"` the run
behaves Unrestricted (no approvals, no sandbox) even though the bridge
mode says `auto-review`. **Recommended: both layers on auto-review** —
bridge `mode` `auto-review` and settings profile `:auto-review`.
`GET /mode` shows both layers at once (`mode`,
`muse_settings_profile`, `muse_args_for_mode`).

**`sync_muse_settings`.** When `true` (default `false`), `POST /mode`
also writes `permissions.default_profile` into
`~/.config/muse/settings.json`. It writes the colon-prefixed profile
id (`:auto-review`), the same form Muse Code itself uses for its
built-in profiles.

**Headless jobs vs live sessions.** A headless job (`muse exec`, piped
output) has no input channel: the bridge can read output and cancel,
nothing else. In `ask-me` it stalls on the first approval — nobody can
answer. In `auto-review` (both layers), the automated judge clears
routine approvals, so jobs run unattended. Approving from your phone
works **only in a live shared tmux session**: the prompt shows in the
pane (`GET /sessions/:id/pane`) and is answered by typing there — you
attached via tmux, or the client via `POST /sessions/:id/input` on your
explicit word. Headless jobs have no equivalent.

**`approval_blocked` and its blind spot.** The bridge regex-scans each
output chunk for markers (`approval required`, `waiting for approval`,
`needs approval`, `approval request`, `permission denied`, `permission
required`) and sets `approval_blocked: true` in the job status on a
match. A job that hangs **silently — zero output — never matches**, so
the flag stays `false` (e.g. a run stalled at startup). `running` with
an empty or frozen output tail means "suspect a stall", not "healthy";
cancel it (`POST /jobs/:id/cancel`) and read
`data/jobs/<id>/log.txt`.

### Configuration keys

| Key | Default | Meaning |
|---|---|---|
| `port` | `8787` | HTTP port |
| `bind_mode` | `auto` | Transport choice: `auto`, `localhost`, `tailscale`, `lan`, `custom` (see "Transports") |
| `bind_host` | `null` | Explicit IP/hostname; required when `bind_mode` is `custom` |
| `data_dir` | `<server-dir>/data` | Holds `inbox/`, `jobs/`, `sessions/` |
| `default_workdir` | `null` | Working directory for jobs that omit `workdir` |
| `allowed_workdirs` | `null` | Optional array of absolute paths; when set and non-empty, jobs/sessions may only start in/under these dirs (else 403). Start directory only — the agent runs as your user and can `cd` elsewhere; see "Security" |
| `default_model`, `default_effort` | `"muse-ember-1.0"`, `"medium"` | Default model and effort tier (cheap by default; `null` falls back to these) |
| `token` | `null` | Bearer token; `null` = env `LUNA_BRIDGE_TOKEN`, else the token file, else generate |
| `token_file` | `~/.config/luna-bridge/token` | Where a generated token is stored (0600) |
| `muse_bin` | `muse` | Path to the Muse Code binary |
| `tmux_bin` | `tmux` | Path to the tmux binary (shared sessions only) |
| `muse_args` | `[]` | Extra args appended to every agent invocation |
| `mode` | `auto-review` | Permission mode |
| `sync_muse_settings` | `false` | Also write the mode to `~/.config/muse/settings.json` on `POST /mode` (colon-prefixed id, e.g. `:auto-review` — see "Permission modes") |
| `keep_awake` | `false` | macOS only: hold an idle-sleep assertion (`caffeinate`) while the bridge runs |
| `max_model_steps` | `300` | Per-job step cap (`0` = no cap) |
| `prompt_via_file` | `true` | Pass the prompt via `--prompt-file` |
| `use_workspace_flag` | `true` | Pass `--workspace <workdir>` |
| `max_upload_bytes` | 25 MB | Upload size limit |
| `max_prompt_bytes` | 200 KB | Prompt size limit |
| `max_json_bytes` | 512 KB | JSON body limit |
| `max_output_tail_bytes` | 200 KB | Output tail kept in memory and responses |
| `cancel_grace_ms` | `3000` | SIGTERM → SIGKILL delay on cancel |

Environment: `LUNA_BRIDGE_CONFIG` (config path), `LUNA_BRIDGE_TOKEN`
(token).

## Transports: Tailscale is optional

The transport is an explicit install-time choice, recorded as `bind_mode`
in `config.json`. At startup the server logs the exact addresses it listens
on and how a client reaches it. The bridge never binds `0.0.0.0`.

| Option (`bind_mode`) | What to install | What is exposed to whom | Trade-off |
|---|---|---|---|
| Localhost only (`localhost`, or `auto` with no Tailscale IP) | Nothing | The port exists only on this Mac (`127.0.0.1`) | Safest and dependency-free, but no remote client can connect by itself |
| Tailscale (`tailscale`, or `auto` with Tailscale present) | Tailscale app + account, on the Mac and each client | The port on the Mac's `100.x.x.x` tailnet address, only to approved devices | Private and simple, but depends on a third-party service |
| Cloudflare Tunnel (`localhost` + tunnel to `127.0.0.1:8787`) | `cloudflared` (+ account/domain for a named tunnel) | A public HTTPS URL; anyone who knows it can reach the port (the token still gates the API) | Reachable anywhere with no inbound ports, but the endpoint is public — keep the token secret, consider Cloudflare Access |
| LAN (`lan`) | Nothing | The port on the Mac's LAN IP, to every device on the local network | Dependency-free at home, but anyone on that network can reach the port (token still required) |
| Custom address (`custom` + `bind_host`) | Nothing | The port on exactly the address you name | Full manual control; you own the exposure decision; startup fails if `bind_host` is missing or invalid |
| SSH port forward (`ssh -L 8787:127.0.0.1:8787 <mac>`, with `localhost`) | Remote Login on the Mac, an SSH client on the client | Nothing new: the client uses its own `127.0.0.1:8787`, forwarded over SSH | Reuses existing SSH trust, but the client must hold the connection open and be able to SSH at all |

Notes:

- `auto` (the default) = the Tailscale IP if one is detected, plus
  127.0.0.1; otherwise 127.0.0.1 only. A missing `tailscale` CLI is never
  an error in this mode.
- `tailscale` and `lan` fail loudly at startup when the address they need
  does not exist, instead of silently binding something else.
- Background (launchd) and foreground runs bind exactly the addresses the
  same `bind_mode` selects.

The recommendation stands as implemented: localhost is the dependency-free
baseline, transports are documented recipes, and Tailscale is the first
recipe — not a requirement. Never expose the port to the internet
directly; go through a VPN, an SSH tunnel, or an HTTPS proxy with its own
access control.

## Security

- **Network:** binds only to the addresses `bind_mode` selects (127.0.0.1
  with no transport configured). Never `0.0.0.0`.
- **Authorization:** a Bearer token on everything except `GET /health`;
  compared in constant time (via SHA-256). The token lives in a `0600`
  file and is never printed to stdout or logs.
- **Execution:** the server spawns only the configured agent binary
  (allowlist), directly with an argv array and no shell — arbitrary
  commands from requests cannot run by design. The only other processes
  are tmux (shared sessions) and, opt-in on macOS, `caffeinate`.
- **Workdir allowlist:** with `allowed_workdirs` set (array of
  absolute paths), `POST /jobs` and `POST /sessions` reject (403) any
  start directory outside the list — including the default — after
  `~` expansion, `..` normalization, and symlink resolution. Absent
  or empty = no restriction. Limitation: this guards the start
  directory only; the agent still runs as your macOS user and can
  `cd` elsewhere inside a session. True confinement would need
  OS-level sandboxing (`sandbox-exec` / a separate user).
- **Validation:** attachments are accepted only from `data/inbox/`;
  filenames are sanitized to a basename (no path traversal); upload,
  prompt, and JSON sizes are capped; an invalid `model` / `effort` /
  `mode` gets a `400`.
- **Logs:** requests are logged without full prompts (only a short preview
  in metadata) and without the token. On disk each job keeps
  `prompt.txt`, `log.txt`, and `meta.json`.
- **Revoking access:** stop the bridge (`luna-bridge stop`), rotate the
  token (delete the token file and restart), or remove the device from
  your private network.
- **`unrestricted` is a deliberate risk:** it (`--yolo`) means a
  submitted task runs with no approvals. Choose it only deliberately —
  the shipped default is `auto-review`. That is stated loudly in the
  README, not hidden in config. Report vulnerabilities privately —
  see [SECURITY.md](../SECURITY.md).
- **Permission posture has two layers:** the bridge `mode` and Muse
  Code's `permissions.default_profile`. In `auto-review` the bridge
  passes no flags, so the settings profile decides — `:unrestricted`
  there means no approvals and no sandbox. Verify both with `GET /mode`
  (see "Permission modes").

## Project layout

```text
server.js                        the server (Node stdlib only)
config.example.json              example config
config.json                      your config (gitignored)
launchd/com.luna.bridge.plist    launchd agent template
scripts/install.sh               install + load the agent, install the CLI
scripts/luna-bridge              start | stop | restart | status | foreground
scripts/uninstall.sh             unload the agent, remove the CLI
test/fake-muse.sh                fixture pretending to be the muse CLI
test/run-tests.sh                end-to-end tests (fake muse + curl)
docs/setup-guide.md              this guide (English)
docs/setup-guide-ru.md           this guide (Russian)
data/inbox/                      uploaded attachments (gitignored)
data/jobs/<id>/                  prompt.txt, log.txt, meta.json per job
data/sessions/<id>/              prompt.txt, meta.json per session
logs/                            launchd logs (gitignored)
README.md, SETUP.md              documentation
SECURITY.md, LICENSE             vulnerability reporting; MIT license
```

Tests run without a real Muse Code install: `sh test/run-tests.sh`
(jobs, sessions, model/effort, auth, upload, cancel, validation,
transports, keep-awake, the `luna-bridge` CLI, and foreground mode).

## Going open source: checklist and status

1. **Push all local commits** — origin must match the code the docs
   describe before the visibility flip.
2. **Audit the whole history for secrets** — search `git log -p --all`
   for token values, private addresses, home-directory paths, and other
   personal data; scrub the working tree, and rewrite history (or start
   clean) only for findings that actually landed in old commits.
3. **Scrub personal data** — absolute paths with a username, private
   project names as example workdirs, personal asides in the README:
   replace with neutral examples (`/Users/you/Projects/my-app`,
   "your AI agent").
4. **One public name** — repository, project, and config use
   `luna-bridge`; the launchd label is `com.luna.bridge`. `Muse Code`
   appears only as the name of Meta's product.
5. **Transport is a choice, not a dependency** — `bind_mode` with a
   localhost baseline and documented transport recipes (implemented; see
   "Transports" above).
6. **License** — MIT (`LICENSE`).
7. **Required files** — `LICENSE`, `SECURITY.md` (threat model in one
   line: the token is full access to the agent on that machine), and
   `.gitignore` covering config, token, `data/`, and `logs/`.
8. **Documentation in English** — README and SETUP are English; this guide
   exists in English (canonical) and Russian.
9. **README matches the code** — jobs, sessions, model/effort, parallel
   worktrees, transports, keep-awake, foreground mode.
10. **Final check on a clean machine:** clone →
    `cp config.example.json config.json` → `sh scripts/install.sh` →
    `curl /health` → `sh test/run-tests.sh` green → a first real job. If
    any step needs an "oh, and you also have to know that…", that is a
    missing paragraph in the docs.

## Known limitations

- The server targets macOS (launchd, tmux, paths). The client can live
  anywhere. A Linux port (systemd) is the natural first direction for
  contributors.
- Agent CLI support is Muse Code only today: `muse_bin` picks the
  binary, but the subcommands and flags are Muse Code's. Per-agent
  profiles (Codex, Claude Code, …) are a follow-up, not a config tweak.
- There is no live attach to a headless job (a Muse Code limitation, not
  the bridge's); interactive work uses tmux sessions.
- Job completion is discovered by polling; there are no push
  notifications beyond the client's own reporting.
- One Muse Code quota is shared by all parallel jobs and sessions.
