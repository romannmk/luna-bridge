#!/usr/bin/env node
/**
 * luna-bridge — v0.1.0
 *
 * A tiny HTTP server that runs on the user's Mac and lets a remote client
 * (an AI agent, a script — anything that can send HTTP with a Bearer token)
 * run tasks and upload files for Muse Code CLI on that Mac. The flag
 * mapping below is Muse Code's; `muse_bin` selects the binary, but other
 * agent CLIs are not drop-in compatible yet (see README).
 *
 * Why this exists: in the original setup SSH to the Mac was blocked — the
 * remote environment's egress proxy only allows curl's CONNECT and only
 * forwards TLS/HTTPS, so raw SSH never gets through. HTTPS through a
 * private tunnel DOES work (curl reaches the Mac), so the bridge is an
 * HTTP server reached via the transport chosen in config (bind_mode).
 *
 * Stack: Node.js stdlib only. Zero dependencies, no build step, no npm install.
 * Runs with `node server.js` (also works under Bun). Day to day it runs in
 * the background under launchd (scripts/install.sh); `node server.js
 * --foreground` (or `luna-bridge foreground`) runs the same server attached
 * to your terminal instead, with logs on stdout — Ctrl+C stops it.
 *
 * SECURITY MODEL (read this before changing anything):
 * - Binds only to the addresses chosen by `bind_mode` (default `auto`:
 *   the Tailscale IP if one is detected, plus 127.0.0.1; otherwise
 *   127.0.0.1 only). Tailscale is ONE optional transport, never a
 *   requirement — see "Choosing a transport" in README.md. Never 0.0.0.0:
 *   with the private transports (localhost, Tailscale), only this machine
 *   or devices the user approved can even reach the port.
 * - Every endpoint except GET /health requires `Authorization: Bearer <token>`.
 * - The server ONLY ever executes the `muse` binary (allowlist). It never
 *   runs arbitrary shell commands from requests. No shell is involved at all:
 *   the child process is spawned directly with an argv array. The one other
 *   process it may spawn is macOS's built-in `caffeinate` at startup when
 *   the local config sets `keep_awake: true` — never from a request.
 * - Prompts may contain private task text: they are never logged (only a
 *   short preview at most), and the token is never logged.
 * - Optional `allowed_workdirs`: when set and non-empty, POST /jobs and
 *   POST /sessions reject (403) any start directory outside the listed
 *   folders. This guards the START directory only — the agent still runs
 *   as the macOS user and can `cd` elsewhere inside a session. True
 *   confinement would need OS-level sandboxing (sandbox-exec / a separate
 *   user) and is out of scope here. Unset/empty = no restriction.
 *
 * Config: config.json next to this file (see config.example.json). The token
 * comes from LUNA_BRIDGE_TOKEN env, config.json `token`, or a token file
 * (~/.config/luna-bridge/token). With none configured, a strong token is
 * generated on first run and saved to that file (mode 0600). The token
 * value is never printed or logged: stdout lands in logs/bridge.out.log
 * under launchd, so printing it there would leak it into a log file.
 */

'use strict';

const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const net = require('node:net');
const { spawn, execFile } = require('node:child_process');

const VERSION = '0.1.0';
const SERVER_DIR = __dirname;

// ---------------------------------------------------------------------------
// Command line
// ---------------------------------------------------------------------------
//
// The server never daemonises itself: in the default setup launchd runs it
// in the background (scripts/install.sh, logs in logs/bridge.*.log).
// `--foreground` is the explicit "run it attached to this terminal" mode:
// same server, same config, logs on stdout, Ctrl+C to stop. It exists so
// the foreground run is a documented, deliberate choice (and so the
// startup log can say so) — behaviour is otherwise identical.

const USAGE = `Usage: node server.js [--foreground]

  (no flags)    run the bridge (this is how launchd starts it, in the
                background; logs land in logs/bridge.out.log there)
  --foreground  run the bridge attached to this terminal, logs to stdout;
                Ctrl+C stops it. Same server, same config as background.
  --help, -h    print this help and exit`;

// Pure argv parser (exported for the test suite). Throws on anything it
// does not recognise so a typo'd flag fails loudly instead of silently
// starting the server in an unintended mode.
function parseArgs(argv) {
  const opts = { foreground: false, help: false };
  for (const arg of argv) {
    if (arg === '--foreground') opts.foreground = true;
    else if (arg === '--help' || arg === '-h') opts.help = true;
    else throw new Error(`unknown argument: ${arg}\n${USAGE}`);
  }
  return opts;
}

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const DEFAULTS = {
  port: 8787,
  // bind_mode: which address(es) to listen on — the explicit transport
  // choice. One of: "auto" (default: Tailscale IP if detected, plus
  // 127.0.0.1; else 127.0.0.1 only), "localhost" (127.0.0.1 only),
  // "tailscale" (Tailscale IP only; fails at startup if none is found),
  // "lan" (this machine's LAN IP; fails at startup if none is found),
  // "custom" (the bind_host below; required in that mode).
  // Tailscale is optional: with no Tailscale CLI at all, "auto" and
  // "localhost" still work — the bridge has zero third-party dependencies.
  bind_mode: 'auto',
  // bind_host: explicit IP/hostname to listen on. Used only by
  // bind_mode "custom" (required there), plus one legacy case: configs
  // written before bind_mode existed (no bind_mode key at all) keep the
  // old behaviour — the Tailscale IP if detected, else bind_host, always
  // plus 127.0.0.1.
  bind_host: null,
  // Base directory for runtime data (inbox/, jobs/). Default: <server-dir>/data
  data_dir: null,
  // Token: null = use env LUNA_BRIDGE_TOKEN, else token file, else generate.
  token: null,
  token_file: null, // default: ~/.config/luna-bridge/token
  // Default working directory for jobs when the request omits workdir.
  // No hardcoded user-specific default here on purpose: set it in config.json.
  default_workdir: null,
  // Working-directory allowlist: array of absolute paths (e.g.
  // ["/Users/you/Projects"]). When set and non-empty, POST /jobs and
  // POST /sessions reject with 403 any workdir (including the default)
  // that is not equal to or inside one of these dirs, after `~`
  // expansion, `..` normalization, and symlink resolution. null/absent/
  // empty = no restriction (the pre-allowlist behaviour). NOTE: this
  // guards the START directory only; the agent runs as this user and
  // can `cd` elsewhere inside a session (see README "Security model").
  allowed_workdirs: null,
  // Path to the muse binary ("muse" = resolve via PATH at startup).
  muse_bin: 'muse',
  // Path to the tmux binary ("tmux" = resolve via PATH at startup).
  // Used only by shared interactive sessions; headless jobs never touch tmux.
  tmux_bin: 'tmux',
  // Extra args appended to every `muse exec` invocation (after mode flags).
  // Examples: ["--model", "muse-spark-1.3"] — see README for verified flags.
  muse_args: [],
  // Current permission mode for subsequently started jobs.
  // One of: "ask-me" | "auto-review" | "unrestricted" | "read-only"
  mode: 'unrestricted',
  // Default model for runs (null = leave unset, let Muse Code decide).
  // Free-form model id, e.g. "muse-spark-1.3". Per-request `model` overrides it.
  default_model: null,
  // Default reasoning effort tier for runs (null = leave unset; Muse Code
  // default `high` applies). One of EFFORTS below. Per-request `effort`
  // overrides it.
  default_effort: null,
  // Also write the mode into ~/.config/muse/settings.json
  // (permissions.default_profile) when POST /mode is called. Default off:
  // changing the user's interactive Muse Code settings is opt-in.
  sync_muse_settings: false,
  // Keep this Mac awake while the bridge runs (opt-in, macOS only). When
  // true, the server spawns the built-in `caffeinate -i -w <own pid>` at
  // startup: the Mac will not idle-sleep for as long as the bridge process
  // runs ("online always while the bridge is running"). Trade-off: no idle
  // sleep at all while the daemon is up — mind battery/heat on a laptop.
  // On other platforms (or without caffeinate) it logs and continues.
  keep_awake: false,
  // Cap on model steps per job (0 = no cap). Prevents runaway quota burn.
  max_model_steps: 300,
  // Pass the prompt via --prompt-file (writes prompt.txt in the job dir)
  // instead of as a positional argument. Disable if your muse version
  // rejects --prompt-file.
  prompt_via_file: true,
  // Pass --workspace <workdir> to muse exec. Reported in community docs;
  // verify with `muse exec --help` on the Mac; set false if rejected.
  use_workspace_flag: true,
  // Limits
  max_upload_bytes: 25 * 1024 * 1024, // 25 MB
  max_prompt_bytes: 200 * 1024, // 200 KB
  max_json_bytes: 512 * 1024, // 512 KB
  max_output_tail_bytes: 200 * 1024, // 200 KB kept in memory / returned
  // How long (ms) to wait for SIGTERM before SIGKILL on cancel.
  cancel_grace_ms: 3000,
};

function loadConfig() {
  const configPath = process.env.LUNA_BRIDGE_CONFIG
    || path.join(SERVER_DIR, 'config.json');
  let fileConfig = {};
  if (fs.existsSync(configPath)) {
    try {
      fileConfig = JSON.parse(fs.readFileSync(configPath, 'utf8'));
    } catch (err) {
      console.error(`[config] failed to parse ${configPath}: ${err.message}`);
      process.exit(1);
    }
  }
  const cfg = { ...DEFAULTS, ...fileConfig };
  // Whether the config file named bind_mode itself. Configs predating
  // bind_mode (key absent or null) keep the legacy bind behaviour.
  cfg.bindModeExplicit = fileConfig.bind_mode !== undefined
    && fileConfig.bind_mode !== null && fileConfig.bind_mode !== '';
  cfg.configPath = configPath;
  cfg.dataDir = cfg.data_dir
    || path.join(SERVER_DIR, 'data');
  cfg.inboxDir = path.join(cfg.dataDir, 'inbox');
  cfg.jobsDir = path.join(cfg.dataDir, 'jobs');
  cfg.sessionsDir = path.join(cfg.dataDir, 'sessions');
  cfg.tokenFile = cfg.token_file
    || path.join(os.homedir(), '.config', 'luna-bridge', 'token');
  // Validate the workdir allowlist eagerly: a malformed security setting
  // must fail loudly at startup, never silently disable the restriction.
  try {
    cfg.allowedWorkdirs = normalizeAllowedWorkdirs(cfg.allowed_workdirs);
  } catch (err) {
    console.error(`[config] ${err.message} Fix allowed_workdirs in ${configPath} (array of absolute paths, or remove it for no restriction).`);
    process.exit(1);
  }
  return cfg;
}

const config = loadConfig();

function saveConfig() {
  // Persist only the user-facing keys (not derived paths).
  const out = {};
  for (const key of Object.keys(DEFAULTS)) {
    if (config[key] !== undefined) out[key] = config[key];
  }
  fs.writeFileSync(config.configPath, JSON.stringify(out, null, 2) + '\n', 'utf8');
}

// ---------------------------------------------------------------------------
// Token
// ---------------------------------------------------------------------------

function resolveToken() {
  if (process.env.LUNA_BRIDGE_TOKEN) return process.env.LUNA_BRIDGE_TOKEN;
  if (config.token) return config.token;
  try {
    if (fs.existsSync(config.tokenFile)) {
      const t = fs.readFileSync(config.tokenFile, 'utf8').trim();
      if (t) return t;
    }
  } catch { /* fall through to generation */ }
  // First run: generate and save (0600). The token value is NEVER printed
  // or logged: under launchd stdout lands in logs/bridge.out.log.
  const token = crypto.randomBytes(32).toString('hex');
  fs.mkdirSync(path.dirname(config.tokenFile), { recursive: true });
  fs.writeFileSync(config.tokenFile, token + '\n', { mode: 0o600 });
  console.log('[auth] Generated a new bearer token and saved it to:');
  console.log(`[auth]   ${config.tokenFile}`);
  console.log('[auth] The token value is never printed or logged; read it from the token file.');
  return token;
}

const TOKEN = resolveToken();
const TOKEN_HASH = crypto.createHash('sha256').update(TOKEN).digest();

function checkAuth(req) {
  const header = req.headers.authorization || '';
  const m = /^Bearer\s+(.+)$/.exec(header);
  if (!m) return false;
  const given = crypto.createHash('sha256').update(m[1].trim()).digest();
  return crypto.timingSafeEqual(given, TOKEN_HASH);
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

function log(...args) {
  console.log(new Date().toISOString(), ...args);
}

function isPlainObject(v) {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}

function sendJson(res, status, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(status, {
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(body),
  });
  res.end(body);
}

function sendError(res, status, message) {
  sendJson(res, status, { error: message });
}

function readBody(req, maxBytes) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;
    let tooBig = false;
    req.on('data', (chunk) => {
      total += chunk.length;
      if (total > maxBytes) {
        tooBig = true;
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      if (tooBig) return reject(new Error('body too large'));
      resolve(Buffer.concat(chunks));
    });
    req.on('error', reject);
  });
}

async function readJsonBody(req) {
  const buf = await readBody(req, config.max_json_bytes);
  if (buf.length === 0) return {};
  try {
    return JSON.parse(buf.toString('utf8'));
  } catch {
    throw Object.assign(new Error('invalid JSON body'), { status: 400 });
  }
}

function sanitizeFilename(name) {
  // Basename only, no path traversal; keep it filesystem-safe.
  const base = path.basename(String(name || '').trim()).replace(/[^A-Za-z0-9._-]+/g, '_');
  return base.replace(/^\.+/, '').slice(0, 200) || 'file';
}

// ---------------------------------------------------------------------------
// Working-directory allowlist (allowed_workdirs)
// ---------------------------------------------------------------------------
//
// Pure helpers (exported for the test suite). `opts` may inject
// { homeDir, cwd, realpathFn } so the contract is testable without a real
// filesystem; by default realpathFn is fs.realpathSync with a lexical
// fallback for paths that do not exist (yet).

function defaultRealpath(p) {
  try { return fs.realpathSync(p); } catch { return p; }
}

// Expand a leading `~` / `~/` against the user's home directory.
// (`~user` is not expanded — it stays a literal relative name.)
function expandHomeDir(p, homeDir = os.homedir()) {
  if (p === '~') return homeDir;
  if (p.startsWith('~/') || p.startsWith(`~${path.sep}`)) return path.join(homeDir, p.slice(2));
  return p;
}

// Canonical form of a requested workdir: `~` expanded, made absolute,
// `.`/`..` normalized (path.resolve), then symlinks resolved when the
// path exists. Throws on a non-string/empty input.
function resolveWorkdirPath(input, opts = {}) {
  if (typeof input !== 'string' || input.trim() === '') {
    throw new Error('workdir must be a non-empty string');
  }
  const homeDir = opts.homeDir || os.homedir();
  const cwd = opts.cwd || process.cwd();
  const realpathFn = opts.realpathFn || defaultRealpath;
  const expanded = expandHomeDir(input.trim(), homeDir);
  return realpathFn(path.resolve(cwd, expanded));
}

// True when `candidate` equals `dir` or lives inside it. Both must
// already be canonical (resolveWorkdirPath). The separator boundary
// keeps a sibling like /srv/ProjectsEvil out of /srv/Projects.
function isPathInsideDir(candidate, dir) {
  if (candidate === dir) return true;
  const prefix = dir.endsWith(path.sep) ? dir : dir + path.sep;
  return candidate.startsWith(prefix);
}

// Canonical allowed dirs from the raw config value. Unset (null/
// undefined) or [] -> [] (no restriction). Anything malformed throws:
// a broken security setting must fail loudly, never fail open.
function normalizeAllowedWorkdirs(allowed, opts = {}) {
  if (allowed === undefined || allowed === null) return [];
  if (!Array.isArray(allowed)) {
    throw new Error('allowed_workdirs must be an array of absolute paths');
  }
  const homeDir = opts.homeDir || os.homedir();
  const out = [];
  for (const entry of allowed) {
    if (typeof entry !== 'string' || entry.trim() === '') {
      throw new Error(`allowed_workdirs entries must be non-empty strings (got ${JSON.stringify(entry)})`);
    }
    if (!path.isAbsolute(expandHomeDir(entry.trim(), homeDir))) {
      throw new Error(`allowed_workdirs entries must be absolute paths (got ${JSON.stringify(entry)})`);
    }
    const canonical = resolveWorkdirPath(entry, opts);
    if (!out.includes(canonical)) out.push(canonical);
  }
  return out;
}

// The allowlist check itself: an empty/unset list allows any workdir
// (backward compatibility); otherwise the canonical workdir must be
// equal to or inside one of the canonical allowed dirs.
function isWorkdirAllowed(workdir, allowed, opts = {}) {
  const dirs = normalizeAllowedWorkdirs(allowed, opts);
  if (dirs.length === 0) return true;
  const candidate = resolveWorkdirPath(workdir, opts);
  return dirs.some((dir) => isPathInsideDir(candidate, dir));
}

// Shared POST /jobs + POST /sessions workdir resolution: request value,
// else config default_workdir, else the server's cwd. Returns
// { workdir } or { status, error } — 400 for a bad/missing directory,
// 403 when allowed_workdirs rejects it (checked before existence, so
// an outside path is refused without probing it; the default workdir
// goes through the same check).
function resolveRequestWorkdir(requested) {
  let raw = requested;
  if (raw === undefined || raw === null || raw === '') {
    raw = config.default_workdir || process.cwd();
  }
  if (typeof raw !== 'string' || raw.trim() === '') {
    return { status: 400, error: 'workdir must be a non-empty string' };
  }
  const workdir = resolveWorkdirPath(raw);
  let allowed;
  try {
    allowed = normalizeAllowedWorkdirs(config.allowed_workdirs);
  } catch (err) {
    // Unreachable in practice (validated at startup): fail closed.
    return { status: 403, error: `workdir rejected: ${err.message}` };
  }
  if (allowed.length > 0 && !allowed.some((dir) => isPathInsideDir(workdir, dir))) {
    return { status: 403, error: `workdir is outside allowed_workdirs: ${workdir}` };
  }
  try {
    const st = fs.statSync(workdir);
    if (!st.isDirectory()) return { status: 400, error: 'workdir is not a directory' };
  } catch {
    return { status: 400, error: 'workdir does not exist' };
  }
  return { workdir };
}

// ---------------------------------------------------------------------------
// Environment discovery (Tailscale IP, muse binary, Muse settings)
// ---------------------------------------------------------------------------

function execFileAsync(cmd, args, timeoutMs = 5000) {
  return new Promise((resolve) => {
    execFile(cmd, args, { timeout: timeoutMs }, (err, stdout) => {
      if (err) return resolve(null);
      resolve(stdout);
    });
  });
}

async function detectTailscaleIp() {
  // Never throws: a missing tailscale CLI (or one that prints nothing)
  // simply means "no Tailscale IP" — Tailscale is optional.
  for (const args of [['ip', '--v4'], ['ip']]) {
    const out = await execFileAsync('tailscale', args);
    if (!out) continue;
    for (const line of out.split('\n')) {
      const ip = line.trim();
      if (/^\d{1,3}(\.\d{1,3}){3}$/.test(ip)) return ip;
    }
  }
  return null;
}

// This machine's LAN IPv4 from the OS network interfaces, or null.
// Skips loopback/internal, link-local (169.254/16) and the Tailscale
// CGNAT range (100.64/10 — that is the "tailscale" mode's address, not
// the LAN). Prefers physical interfaces and private (RFC 1918) addresses.
function detectLanIp(interfaces = os.networkInterfaces()) {
  const candidates = [];
  for (const [name, addrs] of Object.entries(interfaces || {})) {
    for (const a of addrs || []) {
      if (a.internal) continue;
      if (a.family !== 'IPv4' && a.family !== 4) continue;
      const ip = a.address;
      if (!net.isIPv4(ip)) continue;
      if (ip.startsWith('169.254.')) continue;
      const second = Number(ip.split('.')[1]);
      if (ip.startsWith('100.') && second >= 64 && second <= 127) continue;
      candidates.push({ name, ip });
    }
  }
  if (candidates.length === 0) return null;
  const score = (c) => {
    let s = 0;
    if (/^(en|eth|wlan|wl)/.test(c.name)) s += 2;
    if (/^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)/.test(c.ip)) s += 1;
    return s;
  };
  candidates.sort((a, b) => score(b) - score(a));
  return candidates[0].ip;
}

function isValidBindHost(host) {
  if (typeof host !== 'string' || host.trim() === '') return false;
  const h = host.trim();
  if (net.isIP(h)) return true;
  // Hostname: dot-separated labels of letters/digits/hyphens, no label
  // starting or ending with a hyphen (covers "localhost", "mac.local").
  return h.length <= 253
    && h.split('.').every((label) => /^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$/.test(label));
}

const BIND_MODES = ['auto', 'localhost', 'tailscale', 'lan', 'custom'];

// One plain-language line on how a client reaches the server in this mode.
function describeReach(mode, hosts, port, tailscaleIp) {
  const url = (h) => `http://${h}:${port}`;
  switch (mode) {
    case 'localhost':
      return `Only programs on this machine can reach it, at ${url('127.0.0.1')} — for remote access, forward to it (SSH -L) or put a tunnel (e.g. Cloudflare Tunnel) in front of that address.`;
    case 'tailscale':
      return `Devices signed in to your tailnet reach it at ${url(hosts[0])}.`;
    case 'lan':
      return `Devices on the same local network reach it at ${url(hosts[0])}.`;
    case 'custom':
      return `Clients that can route to ${hosts[0]} reach it at ${url(hosts[0])}.`;
    case 'auto':
    default:
      if (tailscaleIp && hosts.includes(tailscaleIp)) {
        return `Devices signed in to your tailnet reach it at ${url(tailscaleIp)}; programs on this machine can also use ${url('127.0.0.1')}.`;
      }
      return `Only programs on this machine can reach it, at ${url('127.0.0.1')} — to reach it from elsewhere, add a transport later (Tailscale, Cloudflare Tunnel, LAN or SSH -L; see "Choosing a transport" in README.md).`;
  }
}

// Resolve the bind_mode/bind_host config into the addresses to listen on.
// Pure: `detected` carries { tailscaleIp, lanIp } (either may be null).
// Returns { mode, hosts, reach }; throws an Error with a fix-it message
// when the chosen mode cannot be satisfied (fail loudly, never silently
// fall back to a different exposure than the user picked).
function resolveBindHosts(cfg, detected) {
  const port = cfg.port ?? 8787;
  const { tailscaleIp = null, lanIp = null } = detected || {};
  const rawMode = cfg.bind_mode;
  const explicit = cfg.bindModeExplicit !== undefined
    ? cfg.bindModeExplicit
    : (rawMode !== undefined && rawMode !== null && rawMode !== '');
  const mode = explicit ? rawMode : 'auto';
  if (!BIND_MODES.includes(mode)) {
    throw new Error(`invalid bind_mode ${JSON.stringify(rawMode)} — must be one of: ${BIND_MODES.join(', ')}. Fix bind_mode in config.json (or remove it for the default "auto").`);
  }
  const bindHost = (typeof cfg.bind_host === 'string' && cfg.bind_host.trim() !== '')
    ? cfg.bind_host.trim() : null;
  let hosts;
  switch (mode) {
    case 'localhost':
      hosts = ['127.0.0.1'];
      break;
    case 'tailscale':
      if (!tailscaleIp) {
        throw new Error('bind_mode is "tailscale" but no Tailscale IP was found (the tailscale CLI is missing, not signed in, or printed no address). Fix: install/start Tailscale and check `tailscale ip` prints a 100.x.x.x address — or set bind_mode to "auto", "localhost", "lan" or "custom" in config.json.');
      }
      hosts = [tailscaleIp];
      break;
    case 'lan':
      if (!lanIp) {
        throw new Error('bind_mode is "lan" but no LAN IPv4 address was found on this machine (no active network interface?). Fix: connect this machine to a network — or set bind_mode to "auto", "localhost", "tailscale" or "custom" in config.json.');
      }
      hosts = [lanIp];
      break;
    case 'custom':
      if (!bindHost) {
        throw new Error('bind_mode is "custom" but bind_host is not set. Fix: set bind_host in config.json to the IP or hostname to listen on (e.g. "192.168.1.10") — or set bind_mode to "auto", "localhost", "tailscale" or "lan".');
      }
      if (!isValidBindHost(bindHost)) {
        throw new Error(`bind_host ${JSON.stringify(bindHost)} is not a valid IP address or hostname. Fix: set bind_host in config.json to a valid IP (e.g. "192.168.1.10") or hostname (e.g. "mac.local").`);
      }
      if (bindHost === '0.0.0.0' || bindHost === '::') {
        throw new Error(`bind_host ${JSON.stringify(bindHost)} means "every network interface" — luna-bridge never binds to all interfaces. Fix: set bind_host to one specific IP or hostname.`);
      }
      hosts = [bindHost];
      break;
    case 'auto':
    default:
      hosts = ['127.0.0.1'];
      if (tailscaleIp && !hosts.includes(tailscaleIp)) hosts.push(tailscaleIp);
      // Legacy configs (no bind_mode key) with an explicit bind_host keep
      // the pre-bind_mode behaviour: bind_host when no Tailscale IP.
      else if (!explicit && bindHost && bindHost !== '127.0.0.1') hosts.push(bindHost);
      break;
  }
  return { mode, hosts, reach: describeReach(mode, hosts, port, tailscaleIp) };
}

async function resolveMuseBin() {
  if (config.muse_bin.includes(path.sep)) return config.muse_bin;
  const out = await execFileAsync('which', [config.muse_bin]);
  return out ? out.trim().split('\n')[0] : null;
}

async function resolveTmuxBin() {
  if (config.tmux_bin.includes(path.sep)) return config.tmux_bin;
  const out = await execFileAsync('which', [config.tmux_bin]);
  return out ? out.trim().split('\n')[0] : null;
}

function museSettingsPath() {
  return path.join(os.homedir(), '.config', 'muse', 'settings.json');
}

function readMuseDefaultProfile() {
  try {
    const raw = fs.readFileSync(museSettingsPath(), 'utf8');
    const json = JSON.parse(raw);
    const p = json && json.permissions && json.permissions.default_profile;
    return typeof p === 'string' ? p : null;
  } catch {
    return null;
  }
}

function writeMuseDefaultProfile(profile) {
  const p = museSettingsPath();
  let json = {};
  try {
    json = JSON.parse(fs.readFileSync(p, 'utf8'));
  } catch { /* start fresh */ }
  if (!isPlainObject(json)) json = {};
  if (!isPlainObject(json.permissions)) json.permissions = {};
  json.permissions.default_profile = profile;
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, JSON.stringify(json, null, 2) + '\n', 'utf8');
}

// ---------------------------------------------------------------------------
// Permission modes -> muse exec flags
// ---------------------------------------------------------------------------
//
// Verified against Meta's official docs (dev.meta.ai/docs/muse-code/permissions,
// crawled 2026-11-05) and the Muse Code CLI cheat sheet (musecodes.io, CLI
// 1.4.13). Confirm with `muse exec --help` on your machine if a flag is
// ever rejected.
//
// Profiles (Meta docs): Ask me, Auto-review (default), Unrestricted
// (= --yolo), Read-only. Default profile setting:
//   permissions.default_profile in ~/.config/muse/settings.json
// Flags:
//   --yolo               no approval, no sandbox, workspace trusted
//                        (= Unrestricted profile)
//   --disable-approval   skip approval prompts, keep the sandbox
//   --disable-sandbox    keep approval, drop the sandbox
//   --approval-mode      on-request (default) | untrusted | never
//   --approval-judge     on | off  (off = every decision goes to the user)
//   --sandbox-network    proxy-only (default) | restricted | unrestricted
//   --trust-workspace    trust the folder without the first-run prompt
//   --disable-write / --disable-shell  (community docs; read-only hardening)
// Headless (`muse exec`): --json, --prompt-file <path>, --max-model-steps <n>,
//   --session-id <uuid>, --no-session-log, --model <id>,
//   --reasoning-effort <tier> (alias --effort). Exit codes: 0 done, 1 failed
//   or cancelled (incl. step limit), 2 usage error, 130/143 interrupted.

const MODES = ['ask-me', 'auto-review', 'unrestricted', 'read-only'];

// Reasoning-effort tiers accepted by `muse exec` / interactive `muse`
// (`--reasoning-effort <TIER>`, alias `--effort`; verified with
// `muse --help` and `muse exec --help`). Muse Code default: `high`.
const EFFORTS = ['none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra'];

// Validate one run's model/effort request fields. Returns { model, effort }
// (effective values, null = unset) or { error } on invalid input.
// `body` is the request JSON; `defaults` is { model, effort } from config.
// Explicit null in the request means "unset" (falls back to the default);
// any other present value must be valid.
function resolveModelEffort(body, defaults) {
  let model;
  if (body.model === undefined || body.model === null) {
    model = defaults.model;
  } else if (typeof body.model !== 'string' || body.model.trim() === '') {
    return { error: 'model must be a non-empty string' };
  } else {
    model = body.model;
  }
  if (model !== null && model !== undefined && (typeof model !== 'string' || model.trim() === '')) {
    return { error: 'model must be a non-empty string' };
  }
  let effort;
  if (body.effort === undefined || body.effort === null) {
    effort = defaults.effort;
  } else if (typeof body.effort !== 'string' || !EFFORTS.includes(body.effort)) {
    return { error: `effort must be one of: ${EFFORTS.join(', ')}` };
  } else {
    effort = body.effort;
  }
  if (effort !== null && effort !== undefined && !EFFORTS.includes(effort)) {
    return { error: `effort must be one of: ${EFFORTS.join(', ')}` };
  }
  return { model: model ?? null, effort: effort ?? null };
}

function configModelEffort() {
  const model = (typeof config.default_model === 'string' && config.default_model.trim() !== '')
    ? config.default_model
    : null;
  const effort = EFFORTS.includes(config.default_effort) ? config.default_effort : null;
  return { model, effort };
}

// Append --model / --reasoning-effort flags for a run (headless or
// interactive). Null/undefined = leave unset, let Muse Code decide.
function appendModelEffortFlags(args, model, effort) {
  if (model !== null && model !== undefined) args.push('--model', model);
  if (effort !== null && effort !== undefined) args.push('--reasoning-effort', effort);
}

function modeFlags(mode) {
  switch (mode) {
    case 'unrestricted':
      return ['--yolo'];
    case 'ask-me':
      // Every eligible approval goes to the user; in headless runs there is
      // no user to answer, so the job will stall on the first approval.
      // The bridge flags that via approval_blocked in job status.
      return ['--approval-mode', 'on-request', '--approval-judge', 'off'];
    case 'read-only':
      return ['--disable-write', '--disable-shell'];
    case 'auto-review':
    default:
      return [];
  }
}

function buildMuseArgs(job) {
  const args = ['exec'];
  args.push(...modeFlags(job.mode));
  args.push('--trust-workspace');
  appendModelEffortFlags(args, job.model, job.effort);
  if (config.max_model_steps > 0) {
    args.push('--max-model-steps', String(config.max_model_steps));
  }
  if (config.use_workspace_flag) {
    args.push('--workspace', job.workdir);
  }
  if (Array.isArray(config.muse_args)) args.push(...config.muse_args);
  if (config.prompt_via_file) {
    args.push('--prompt-file', job.promptFile);
  } else {
    args.push(job.prompt);
  }
  return args;
}

// ---------------------------------------------------------------------------
// Jobs
// ---------------------------------------------------------------------------

const jobs = new Map(); // id -> job record (in-memory; meta.json on disk too)

const APPROVAL_MARKERS = /approval required|waiting for approval|needs approval|approval request|permission denied|permission required/i;

function newJobId() {
  return crypto.randomBytes(6).toString('hex');
}

function jobPaths(id) {
  const dir = path.join(config.jobsDir, id);
  return {
    dir,
    metaFile: path.join(dir, 'meta.json'),
    promptFile: path.join(dir, 'prompt.txt'),
    logFile: path.join(dir, 'log.txt'),
  };
}

function writeMeta(job) {
  const p = jobPaths(job.id);
  const meta = {
    id: job.id,
    status: job.status,
    prompt_preview: job.prompt.slice(0, 120),
    workdir: job.workdir,
    attachments: job.attachments,
    mode: job.mode,
    model: job.model ?? null,
    effort: job.effort ?? null,
    exit_code: job.exitCode,
    approval_blocked: job.approvalBlocked,
    started_at: job.startedAt,
    finished_at: job.finishedAt,
    output_truncated: job.outputTruncated,
  };
  try {
    fs.mkdirSync(p.dir, { recursive: true });
    fs.writeFileSync(p.metaFile, JSON.stringify(meta, null, 2) + '\n', 'utf8');
  } catch { /* meta is best-effort; the log file is the source of truth */ }
}

function loadJobFromDisk(id) {
  const p = jobPaths(id);
  try {
    const meta = JSON.parse(fs.readFileSync(p.metaFile, 'utf8'));
    const log = fs.existsSync(p.logFile) ? fs.readFileSync(p.logFile, 'utf8') : '';
    const tail = log.slice(-config.max_output_tail_bytes);
    return {
      id: meta.id,
      status: meta.status,
      prompt: null, // full prompt is in prompt.txt; preview only in meta
      prompt_preview: meta.prompt_preview,
      workdir: meta.workdir,
      attachments: meta.attachments,
      mode: meta.mode,
      model: meta.model ?? null,
      effort: meta.effort ?? null,
      exitCode: meta.exit_code,
      approvalBlocked: meta.approval_blocked,
      startedAt: meta.started_at,
      finishedAt: meta.finished_at,
      output: tail,
      outputTruncated: log.length > tail.length,
      fromDisk: true,
    };
  } catch {
    return null;
  }
}

function jobPublic(job) {
  return {
    id: job.id,
    status: job.status,
    prompt_preview: job.prompt ? job.prompt.slice(0, 120) : (job.prompt_preview || ''),
    workdir: job.workdir,
    attachments: job.attachments,
    mode: job.mode,
    model: job.model ?? null,
    effort: job.effort ?? null,
    exit_code: job.exitCode,
    approval_blocked: job.approvalBlocked,
    output: job.output || '',
    output_truncated: job.outputTruncated,
    started_at: job.startedAt,
    finished_at: job.finishedAt,
  };
}

function appendOutput(job, chunk) {
  const text = chunk.toString('utf8');
  try {
    fs.appendFileSync(jobPaths(job.id).logFile, text);
  } catch { /* ignore */ }
  job.output = (job.output + text).slice(-config.max_output_tail_bytes);
  job.outputTruncated = true; // true once output ever exceeded the tail; see below
  // Correct the flag: truncated only if the full log is longer than the tail.
  try {
    const size = fs.statSync(jobPaths(job.id).logFile).size;
    job.outputTruncated = size > Buffer.byteLength(job.output);
  } catch { /* keep default */ }
  if (APPROVAL_MARKERS.test(text)) job.approvalBlocked = true;
}

async function createJob({ prompt, workdir, attachments, mode, model, effort }) {
  const id = newJobId();
  const p = jobPaths(id);
  fs.mkdirSync(p.dir, { recursive: true });
  fs.writeFileSync(p.promptFile, prompt, 'utf8');
  fs.writeFileSync(p.logFile, '', 'utf8');

  const job = {
    id,
    status: 'queued',
    prompt,
    promptFile: p.promptFile,
    workdir,
    attachments: attachments || [],
    mode: mode || config.mode,
    model: model ?? null,
    effort: effort ?? null,
    exitCode: null,
    approvalBlocked: false,
    output: '',
    outputTruncated: false,
    startedAt: new Date().toISOString(),
    finishedAt: null,
    child: null,
    cancelled: false,
  };
  jobs.set(id, job);
  writeMeta(job);
  log(`[job ${id}] created (mode=${job.mode}, model=${job.model ?? '-'}, effort=${job.effort ?? '-'}, workdir=${workdir})`);

  const museBin = await resolveMuseBin();
  if (!museBin) {
    job.status = 'failed';
    job.finishedAt = new Date().toISOString();
    appendOutput(job, `error: muse binary not found (muse_bin=${config.muse_bin}). Is Muse Code installed and on PATH?\n`);
    writeMeta(job);
    return job;
  }

  const args = buildMuseArgs(job);
  let child;
  try {
    child = spawn(museBin, args, {
      cwd: workdir,
      detached: true, // own process group so cancel kills the whole tree
      stdio: ['ignore', 'pipe', 'pipe'],
      env: { ...process.env },
    });
  } catch (err) {
    job.status = 'failed';
    job.finishedAt = new Date().toISOString();
    appendOutput(job, `error: failed to spawn muse: ${err.message}\n`);
    writeMeta(job);
    return job;
  }

  job.child = child;
  job.status = 'running';
  writeMeta(job);
  log(`[job ${id}] started: ${museBin} ${args.map((a) => (a === job.prompt ? '<prompt>' : a)).join(' ')}`);

  child.stdout.on('data', (d) => appendOutput(job, d));
  child.stderr.on('data', (d) => appendOutput(job, d));
  child.on('error', (err) => {
    job.status = 'failed';
    job.finishedAt = new Date().toISOString();
    appendOutput(job, `error: muse process error: ${err.message}\n`);
    writeMeta(job);
  });
  child.on('close', (code, signal) => {
    job.child = null;
    job.finishedAt = new Date().toISOString();
    if (job.cancelled || signal === 'SIGTERM' || signal === 'SIGKILL') {
      job.status = 'cancelled';
      job.exitCode = code;
    } else if (code === 0) {
      job.status = 'done';
      job.exitCode = 0;
    } else {
      // muse exec exit codes: 1 failed/cancelled (incl. step limit),
      // 2 usage error, 130/143 interrupted.
      job.status = 'failed';
      job.exitCode = code;
    }
    writeMeta(job);
    log(`[job ${id}] finished status=${job.status} exit=${code} signal=${signal || '-'}`);
  });

  return job;
}

function cancelJob(job) {
  if (!job.child || job.status !== 'running') return false;
  job.cancelled = true;
  try {
    // Negative pid = the whole process group (detached: true).
    process.kill(-job.child.pid, 'SIGTERM');
  } catch { /* already gone */ }
  setTimeout(() => {
    if (job.child) {
      try {
        process.kill(-job.child.pid, 'SIGKILL');
      } catch { /* already gone */ }
    }
  }, config.cancel_grace_ms).unref();
  return true;
}

function getJob(id) {
  if (!/^[A-Za-z0-9-]{8,64}$/.test(id)) return null;
  if (jobs.has(id)) return jobs.get(id);
  const fromDisk = loadJobFromDisk(id);
  if (fromDisk) {
    // Keep a light in-memory record so later reads are cheap.
    jobs.set(id, { ...fromDisk, child: null, cancelled: false, promptFile: jobPaths(id).promptFile });
    return jobs.get(id);
  }
  return null;
}

function listJobs() {
  const rows = [];
  for (const job of jobs.values()) {
    rows.push({
      id: job.id,
      status: job.status,
      prompt_preview: job.prompt ? job.prompt.slice(0, 120) : (job.prompt_preview || ''),
      started_at: job.startedAt,
    });
  }
  // Also include finished jobs from disk that are not in memory.
  try {
    for (const id of fs.readdirSync(config.jobsDir)) {
      if (!jobs.has(id) && /^[A-Za-z0-9-]{8,64}$/.test(id)) {
        const j = loadJobFromDisk(id);
        if (j) rows.push({
          id: j.id,
          status: j.status,
          prompt_preview: j.prompt_preview || '',
          started_at: j.startedAt,
        });
      }
    }
  } catch { /* no jobs dir yet */ }
  rows.sort((a, b) => String(b.started_at).localeCompare(String(a.started_at)));
  return rows.slice(0, 50);
}

// ---------------------------------------------------------------------------
// Shared interactive sessions (tmux)
//
// Unlike headless jobs (one-shot `muse exec` with piped stdout), a shared
// session runs the interactive `muse` TUI inside a detached tmux session:
//
//   tmux new-session -d -s luna-<id> -c <workdir> muse <mode flags> "<prompt>"
//
// The owner attaches from a terminal on the Mac (`tmux attach -t luna-<id>`)
// and Luna reads the pane remotely (`tmux capture-pane -p -t luna-<id>`).
// The tmux server is independent of this bridge process, so sessions survive
// a bridge restart: every read reconciles the recorded status with live
// `tmux has-session` state.
//
// ONE-DRIVER RULE: only one party types at a time. Luna sends input only
// when the owner explicitly asks — otherwise she only reads the pane.
// ---------------------------------------------------------------------------

const sessions = new Map(); // id -> session record (in-memory; meta.json on disk too)

// Best-effort hint that the pane shows the agent waiting at its prompt.
// A heuristic only: matched against visible pane text, never authoritative.
const IDLE_MARKERS = /(❯|›|»|Type your message|type a message|waiting for input|approval required|waiting for approval|press enter|Do you trust this workspace\?)/i;

function newSessionId() {
  return crypto.randomBytes(6).toString('hex');
}

function tmuxSessionName(id) {
  return `luna-${id}`;
}

function attachCommand(id) {
  return `tmux attach -t ${tmuxSessionName(id)}`;
}

function sessionPaths(id) {
  const dir = path.join(config.sessionsDir, id);
  return {
    dir,
    metaFile: path.join(dir, 'meta.json'),
    promptFile: path.join(dir, 'prompt.txt'),
  };
}

function writeSessionMeta(s) {
  const p = sessionPaths(s.id);
  const meta = {
    id: s.id,
    tmux_session: s.tmuxSession,
    workdir: s.workdir,
    mode: s.mode,
    model: s.model ?? null,
    effort: s.effort ?? null,
    prompt_preview: (s.prompt || '').slice(0, 120),
    created_at: s.createdAt,
    status: s.status,
    killed_at: s.killedAt || null,
  };
  try {
    fs.mkdirSync(p.dir, { recursive: true });
    fs.writeFileSync(p.metaFile, JSON.stringify(meta, null, 2) + '\n', 'utf8');
  } catch { /* meta is best-effort */ }
}

function loadSessionFromDisk(id) {
  const p = sessionPaths(id);
  try {
    const meta = JSON.parse(fs.readFileSync(p.metaFile, 'utf8'));
    return {
      id: meta.id,
      tmuxSession: meta.tmux_session,
      workdir: meta.workdir,
      mode: meta.mode,
      model: meta.model ?? null,
      effort: meta.effort ?? null,
      prompt: null, // full prompt is in prompt.txt; preview only in meta
      prompt_preview: meta.prompt_preview,
      createdAt: meta.created_at,
      status: meta.status,
      killedAt: meta.killed_at || null,
    };
  } catch {
    return null;
  }
}

function sessionPublic(s) {
  return {
    id: s.id,
    tmux_session: s.tmuxSession,
    attach_command: attachCommand(s.id),
    status: s.status,
    workdir: s.workdir,
    mode: s.mode,
    model: s.model ?? null,
    effort: s.effort ?? null,
    prompt_preview: s.prompt ? s.prompt.slice(0, 120) : (s.prompt_preview || ''),
    created_at: s.createdAt,
  };
}

function runTmuxBin(tmuxBin, args, timeoutMs = 10000) {
  return new Promise((resolve) => {
    // No shell involved: argv array straight to the tmux binary, same as jobs.
    execFile(tmuxBin, args, { timeout: timeoutMs, maxBuffer: 4 * 1024 * 1024 }, (err, stdout, stderr) => {
      if (err) {
        resolve({ ok: false, out: String(stdout || '') + String(stderr || '') });
        return;
      }
      resolve({ ok: true, out: String(stdout || '') });
    });
  });
}

// null = unknown (tmux binary missing: caller must not flip live state).
async function tmuxHasSession(name) {
  const bin = await resolveTmuxBin();
  if (!bin) return null;
  return await new Promise((resolve) => {
    execFile(bin, ['has-session', '-t', name], { timeout: 5000 }, (err) => resolve(!err));
  });
}

async function refreshSessionStatus(s) {
  const alive = await tmuxHasSession(s.tmuxSession);
  if (alive === null) return s; // cannot probe; keep recorded status
  const next = alive ? 'alive' : 'dead';
  if (next !== s.status) {
    s.status = next;
    writeSessionMeta(s);
  }
  return s;
}

function buildMuseInteractiveArgs(session) {
  // Bare `muse [OPTIONS] [PROMPT]` runs the interactive TUI; the initial
  // prompt is a positional argument (verified with `muse --help` on the
  // installed CLI). Same mode mapping as headless jobs, plus
  // --trust-workspace to skip the first-run trust prompt.
  // Exec-only flags (--json, --max-model-steps, --prompt-file, --workspace,
  // --session-id) do NOT apply here and are deliberately left out.
  const args = [...modeFlags(session.mode), '--trust-workspace'];
  appendModelEffortFlags(args, session.model, session.effort);
  if (Array.isArray(config.muse_args)) args.push(...config.muse_args);
  args.push(session.prompt);
  return args;
}

async function createSession({ prompt, workdir, mode, model, effort }) {
  const id = newSessionId();
  const p = sessionPaths(id);
  fs.mkdirSync(p.dir, { recursive: true });
  fs.writeFileSync(p.promptFile, prompt, 'utf8');

  const s = {
    id,
    tmuxSession: tmuxSessionName(id),
    prompt,
    workdir,
    mode: mode || config.mode,
    model: model ?? null,
    effort: effort ?? null,
    createdAt: new Date().toISOString(),
    status: 'dead',
    killedAt: null,
  };
  sessions.set(id, s);

  const museBin = await resolveMuseBin();
  if (!museBin) {
    writeSessionMeta(s);
    return { session: s, error: `muse binary not found (muse_bin=${config.muse_bin}). Is Muse Code installed and on PATH?` };
  }
  const tmuxBin = await resolveTmuxBin();
  if (!tmuxBin) {
    writeSessionMeta(s);
    return { session: s, error: `tmux binary not found (tmux_bin=${config.tmux_bin}). Install tmux (brew install tmux) and retry.` };
  }

  const r = await runTmuxBin(tmuxBin, [
    'new-session', '-d',
    '-s', s.tmuxSession,
    '-x', '200', '-y', '50',
    '-c', workdir,
    museBin, ...buildMuseInteractiveArgs(s),
  ]);
  if (!r.ok) {
    writeSessionMeta(s);
    log(`[session ${id}] tmux new-session failed: ${r.out.slice(0, 200)}`);
    return { session: s, error: `tmux new-session failed: ${r.out.slice(0, 200)}` };
  }
  const alive = await tmuxHasSession(s.tmuxSession);
  s.status = alive ? 'alive' : 'dead';
  writeSessionMeta(s);
  log(`[session ${id}] created (mode=${s.mode}, model=${s.model ?? '-'}, effort=${s.effort ?? '-'}, workdir=${workdir}, status=${s.status})`);
  return { session: s };
}

async function getSession(id) {
  if (!/^[A-Za-z0-9-]{8,64}$/.test(id)) return null;
  if (sessions.has(id)) return sessions.get(id);
  const fromDisk = loadSessionFromDisk(id);
  if (fromDisk) {
    sessions.set(id, fromDisk);
    return fromDisk;
  }
  return null;
}

async function listSessions() {
  const seen = new Set();
  const all = [];
  for (const s of sessions.values()) {
    seen.add(s.id);
    all.push(s);
  }
  // Include sessions from disk that are not in memory (bridge restart:
  // the tmux server outlives this process, so they may still be alive).
  try {
    for (const id of fs.readdirSync(config.sessionsDir)) {
      if (!seen.has(id) && /^[A-Za-z0-9-]{8,64}$/.test(id)) {
        const s = loadSessionFromDisk(id);
        if (s) {
          sessions.set(id, s);
          all.push(s);
        }
      }
    }
  } catch { /* no sessions dir yet */ }
  await Promise.all(all.map((s) => refreshSessionStatus(s)));
  all.sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)));
  return all.slice(0, 50).map(sessionPublic);
}

async function captureSessionPane(s) {
  const bin = await resolveTmuxBin();
  if (!bin) return { ok: false, error: `tmux binary not found (tmux_bin=${config.tmux_bin})` };
  const r = await runTmuxBin(bin, ['capture-pane', '-p', '-J', '-S', '-', '-t', s.tmuxSession]);
  if (!r.ok) return { ok: false, error: `no live pane for session ${s.id}` };
  let text = r.out.replace(/\s+$/, '');
  if (Buffer.byteLength(text) > config.max_output_tail_bytes) {
    text = text.slice(-config.max_output_tail_bytes);
  }
  return { ok: true, pane: text };
}

async function sendSessionInput(s, text) {
  const bin = await resolveTmuxBin();
  if (!bin) return { ok: false, error: `tmux binary not found (tmux_bin=${config.tmux_bin})` };
  // -l sends the text literally; a separate Enter submits it.
  const first = await runTmuxBin(bin, ['send-keys', '-t', s.tmuxSession, '-l', '--', text]);
  if (!first.ok) return { ok: false, error: `send-keys failed for session ${s.id}: ${first.out.slice(0, 200)}` };
  const second = await runTmuxBin(bin, ['send-keys', '-t', s.tmuxSession, 'Enter']);
  if (!second.ok) return { ok: false, error: `send-keys (Enter) failed for session ${s.id}: ${second.out.slice(0, 200)}` };
  return { ok: true };
}

async function killSession(s) {
  const bin = await resolveTmuxBin();
  if (bin) {
    await runTmuxBin(bin, ['kill-session', '-t', s.tmuxSession]);
  }
  s.status = 'dead';
  s.killedAt = new Date().toISOString();
  writeSessionMeta(s);
  log(`[session ${s.id}] killed`);
  return s;
}

// ---------------------------------------------------------------------------
// HTTP server
// ---------------------------------------------------------------------------

function resolveUnderInbox(name) {
  const resolved = path.resolve(config.inboxDir, name);
  if (!resolved.startsWith(path.resolve(config.inboxDir) + path.sep)) return null;
  return resolved;
}

async function handleUpload(req, res, query) {
  const rawName = req.headers['x-filename'] || query.get('name') || '';
  const name = sanitizeFilename(rawName);
  if (!name || (name === 'file' && !rawName)) {
    return sendError(res, 400, 'filename required via X-Filename header or ?name= query');
  }
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const unique = `${stamp}-${crypto.randomBytes(4).toString('hex')}-${name}`;
  const dest = path.join(config.inboxDir, unique);
  fs.mkdirSync(config.inboxDir, { recursive: true });

  const stream = fs.createWriteStream(dest, { mode: 0o600 });
  let total = 0;
  let failed = null;
  let finished = false;
  let ended = false;
  await new Promise((resolve) => {
    const done = () => resolve();
    req.on('data', (chunk) => {
      if (failed) return;
      total += chunk.length;
      if (total > config.max_upload_bytes) {
        failed = Object.assign(new Error('upload too large'), { status: 413 });
        req.destroy();
        stream.destroy();
        done();
        return;
      }
      if (!stream.write(chunk)) req.pause();
    });
    stream.on('drain', () => req.resume());
    req.on('end', () => { ended = true; stream.end(); });
    req.on('error', (err) => { failed = failed || err; done(); });
    req.on('close', () => {
      // 'close' fires after 'end' on the normal path (ended=true): then we
      // wait for the file stream's 'finish'. Without 'end' it is an abort.
      if (!finished && !ended) {
        failed = failed || Object.assign(new Error('upload aborted'), { status: 400 });
        stream.destroy();
        done();
      }
    });
    stream.on('finish', () => { finished = true; done(); });
    stream.on('error', (err) => { failed = failed || err; done(); });
  });
  if (failed || !finished) {
    try { fs.unlinkSync(dest); } catch { /* ignore */ }
    if (failed) throw failed;
    throw Object.assign(new Error('upload aborted'), { status: 400 });
  }
  log(`[upload] ${unique} (${total} bytes)`);
  sendJson(res, 201, { path: dest, name: unique, size: total });
}

async function handleCreateJob(req, res) {
  const body = await readJsonBody(req);
  if (!isPlainObject(body)) throw Object.assign(new Error('JSON object expected'), { status: 400 });
  const prompt = body.prompt;
  if (typeof prompt !== 'string' || prompt.trim() === '') {
    return sendError(res, 400, 'prompt must be a non-empty string');
  }
  if (Buffer.byteLength(prompt) > config.max_prompt_bytes) {
    return sendError(res, 400, 'prompt too large');
  }
  const wd = resolveRequestWorkdir(body.workdir);
  if (wd.error) return sendError(res, wd.status, wd.error);
  const workdir = wd.workdir;
  const attachments = [];
  if (body.attachments !== undefined) {
    if (!Array.isArray(body.attachments)) {
      return sendError(res, 400, 'attachments must be an array of paths');
    }
    for (const a of body.attachments) {
      if (typeof a !== 'string') return sendError(res, 400, 'attachments must be strings');
      const resolved = path.resolve(a);
      const inboxRoot = path.resolve(config.inboxDir) + path.sep;
      if (!resolved.startsWith(inboxRoot) || !fs.existsSync(resolved)) {
        return sendError(res, 400, `attachment not under inbox dir or missing: ${a}`);
      }
      attachments.push(resolved);
    }
  }
  // Per-job mode override (validated against the same allowlist).
  let mode;
  if (body.mode !== undefined) {
    if (!MODES.includes(body.mode)) {
      return sendError(res, 400, `mode must be one of: ${MODES.join(', ')}`);
    }
    mode = body.mode;
  }
  // Per-job model/effort override (validated; falls back to config defaults).
  const me = resolveModelEffort(body, configModelEffort());
  if (me.error) return sendError(res, 400, me.error);
  const job = await createJob({ prompt, workdir, attachments, mode, model: me.model, effort: me.effort });
  sendJson(res, 202, { job_id: job.id });
}

function handleGetMode(_req, res) {
  sendJson(res, 200, {
    mode: config.mode,
    muse_settings_profile: readMuseDefaultProfile(),
    muse_args_for_mode: modeFlags(config.mode),
  });
}

async function handlePostMode(req, res) {
  const body = await readJsonBody(req);
  if (!isPlainObject(body) || !MODES.includes(body.mode)) {
    return sendError(res, 400, `mode must be one of: ${MODES.join(', ')}`);
  }
  config.mode = body.mode;
  saveConfig();
  if (config.sync_muse_settings) {
    try {
      writeMuseDefaultProfile(body.mode);
    } catch (err) {
      log(`[mode] warning: could not write Muse settings: ${err.message}`);
    }
  }
  log(`[mode] set to ${body.mode}`);
  sendJson(res, 200, { mode: config.mode });
}

async function handleCreateSession(req, res) {
  const body = await readJsonBody(req);
  if (!isPlainObject(body)) throw Object.assign(new Error('JSON object expected'), { status: 400 });
  const prompt = body.prompt;
  if (typeof prompt !== 'string' || prompt.trim() === '') {
    return sendError(res, 400, 'prompt must be a non-empty string');
  }
  if (Buffer.byteLength(prompt) > config.max_prompt_bytes) {
    return sendError(res, 400, 'prompt too large');
  }
  const wd = resolveRequestWorkdir(body.workdir);
  if (wd.error) return sendError(res, wd.status, wd.error);
  const workdir = wd.workdir;
  // Per-session mode override (validated against the same allowlist as jobs).
  let mode;
  if (body.mode !== undefined) {
    if (!MODES.includes(body.mode)) {
      return sendError(res, 400, `mode must be one of: ${MODES.join(', ')}`);
    }
    mode = body.mode;
  }
  // Per-session model/effort override (validated; falls back to config defaults).
  const me = resolveModelEffort(body, configModelEffort());
  if (me.error) return sendError(res, 400, me.error);
  const { session, error } = await createSession({ prompt, workdir, mode, model: me.model, effort: me.effort });
  const out = {
    session_id: session.id,
    tmux_session: session.tmuxSession,
    attach_command: attachCommand(session.id),
    workdir: session.workdir,
    mode: session.mode,
    model: session.model ?? null,
    effort: session.effort ?? null,
    status: session.status,
  };
  if (error) out.error = error;
  sendJson(res, 201, out);
}

async function handleSessionInput(req, res, s) {
  const body = await readJsonBody(req);
  if (!isPlainObject(body) || typeof body.text !== 'string' || body.text === '') {
    return sendError(res, 400, 'text must be a non-empty string');
  }
  if (Buffer.byteLength(body.text) > config.max_prompt_bytes) {
    return sendError(res, 400, 'text too large');
  }
  await refreshSessionStatus(s);
  if (s.status !== 'alive') {
    return sendError(res, 404, 'session is not alive');
  }
  // ONE-DRIVER RULE (see section header): Luna calls this only when the
  // owner explicitly asks her to type into the shared session.
  const r = await sendSessionInput(s, body.text);
  if (!r.ok) return sendError(res, 500, r.error);
  log(`[session ${s.id}] input sent (${Buffer.byteLength(body.text)} bytes)`);
  sendJson(res, 200, { id: s.id, status: s.status, sent_bytes: Buffer.byteLength(body.text) });
}

async function route(req, res) {
  const url = new URL(req.url, 'http://localhost');
  const pathname = url.pathname.replace(/\/+$/, '') || '/';
  const method = req.method;

  // Public: health only.
  if (method === 'GET' && pathname === '/health') {
    return sendJson(res, 200, { ok: true, version: VERSION, mode: config.mode });
  }
  if (!checkAuth(req)) {
    return sendError(res, 401, 'unauthorized');
  }

  if (method === 'POST' && pathname === '/upload') {
    return handleUpload(req, res, url.searchParams);
  }
  if (method === 'POST' && pathname === '/jobs') {
    return handleCreateJob(req, res);
  }
  if (method === 'GET' && pathname === '/jobs') {
    return sendJson(res, 200, { jobs: listJobs() });
  }
  const jobMatch = pathname.match(/^\/jobs\/([A-Za-z0-9-]{8,64})(\/cancel)?$/);
  if (jobMatch) {
    const job = getJob(jobMatch[1]);
    if (!job) return sendError(res, 404, 'job not found');
    if (method === 'GET' && !jobMatch[2]) {
      return sendJson(res, 200, jobPublic(job));
    }
    if (method === 'POST' && jobMatch[2] === '/cancel') {
      const wasRunning = cancelJob(job);
      return sendJson(res, 200, {
        id: job.id,
        status: wasRunning ? 'cancelling' : job.status,
      });
    }
  }
  if (method === 'GET' && pathname === '/mode') {
    return handleGetMode(req, res);
  }
  if (method === 'POST' && pathname === '/mode') {
    return handlePostMode(req, res);
  }
  if (method === 'POST' && pathname === '/sessions') {
    return handleCreateSession(req, res);
  }
  if (method === 'GET' && pathname === '/sessions') {
    const list = await listSessions();
    return sendJson(res, 200, { sessions: list });
  }
  const sessionMatch = pathname.match(/^\/sessions\/([A-Za-z0-9-]{8,64})(\/(pane|input|kill))?$/);
  if (sessionMatch) {
    const s = await getSession(sessionMatch[1]);
    if (!s) return sendError(res, 404, 'session not found');
    const sub = sessionMatch[2];
    if (method === 'GET' && !sub) {
      await refreshSessionStatus(s);
      return sendJson(res, 200, sessionPublic(s));
    }
    if (method === 'GET' && sub === '/pane') {
      await refreshSessionStatus(s);
      if (s.status !== 'alive') {
        return sendError(res, 404, 'session is not alive (no live pane)');
      }
      const cap = await captureSessionPane(s);
      if (!cap.ok) {
        await refreshSessionStatus(s);
        return sendError(res, 404, cap.error);
      }
      return sendJson(res, 200, {
        id: s.id,
        status: s.status,
        pane: cap.pane,
        idle: IDLE_MARKERS.test(cap.pane),
      });
    }
    if (method === 'POST' && sub === '/input') {
      return handleSessionInput(req, res, s);
    }
    if (method === 'POST' && sub === '/kill') {
      await killSession(s);
      return sendJson(res, 200, { id: s.id, status: s.status });
    }
  }
  return sendError(res, 404, 'not found');
}

function handleRequest(req, res) {
  const started = Date.now();
  res.on('finish', () => {
    const url = new URL(req.url, 'http://localhost');
    log(`[http] ${req.method} ${url.pathname} -> ${res.statusCode} (${Date.now() - started}ms)`);
  });
  Promise.resolve()
    .then(() => route(req, res))
    .catch((err) => {
      if (!res.headersSent) {
        const status = err.status || 500;
        sendError(res, status, err.message || 'internal error');
      }
      log(`[http] error ${req.method} ${req.url}: ${err.message}`);
    });
}

// ---------------------------------------------------------------------------
// Keep-awake (opt-in, macOS only)
// ---------------------------------------------------------------------------
//
// With `keep_awake: true`, the bridge holds a macOS idle-sleep assertion
// for as long as the bridge process runs: `caffeinate -i -w <own pid>`
// (built into macOS — no third-party dependency). `-i` prevents idle
// sleep; `-w <pid>` makes caffeinate exit when the bridge exits, so the
// assertion can never outlive the bridge. The caffeinate child is also
// killed explicitly on shutdown (see the signal handlers in main()).
// Anything goes wrong — not macOS, caffeinate missing — log and continue:
// keep-awake must never crash the bridge.

let caffeinateChild = null;

// Returns the caffeinate child process, or null when keep-awake is off,
// not applicable, or could not be started. `opts` (enabled, platform,
// pid, spawnFn, logFn) exists so the test suite can exercise the gating
// on any OS with a fake spawn.
function startKeepAwake(opts = {}) {
  const enabled = opts.enabled !== undefined ? opts.enabled : config.keep_awake;
  if (!enabled) return null;
  const logFn = opts.logFn || log;
  const platform = opts.platform || process.platform;
  if (platform !== 'darwin') {
    logFn(`[keep-awake] keep_awake is on, but keep-awake is macOS-only — continuing without it (platform: ${platform})`);
    return null;
  }
  const spawnFn = opts.spawnFn || spawn;
  const pid = opts.pid || process.pid;
  let child;
  try {
    child = spawnFn('caffeinate', ['-i', '-w', String(pid)], { stdio: 'ignore' });
  } catch (err) {
    logFn(`[keep-awake] warning: could not start caffeinate (${err.message}) — continuing without keep-awake`);
    return null;
  }
  caffeinateChild = child;
  if (child && typeof child.on === 'function') {
    // A missing caffeinate binary reports asynchronously via 'error'
    // (ENOENT), not by throwing — handle it the same way: warn, continue.
    child.on('error', (err) => {
      logFn(`[keep-awake] warning: caffeinate failed (${err.message}) — continuing without keep-awake`);
      if (caffeinateChild === child) caffeinateChild = null;
    });
    child.on('exit', () => {
      if (caffeinateChild === child) caffeinateChild = null;
    });
  }
  logFn('[keep-awake] keep-awake is on: this Mac will not idle-sleep while the bridge runs');
  return child;
}

function stopKeepAwake() {
  if (!caffeinateChild) return;
  try {
    caffeinateChild.kill();
  } catch { /* already gone */ }
  caffeinateChild = null;
}

// ---------------------------------------------------------------------------
// Startup
// ---------------------------------------------------------------------------

async function main(opts = {}) {
  fs.mkdirSync(config.inboxDir, { recursive: true });
  fs.mkdirSync(config.jobsDir, { recursive: true });
  fs.mkdirSync(config.sessionsDir, { recursive: true });

  // Detect only what the chosen transport needs: e.g. bind_mode
  // "localhost" never touches the tailscale CLI at all. Detection never
  // crashes startup — a missing tailscale CLI means "no Tailscale IP".
  const wantedMode = config.bindModeExplicit ? config.bind_mode : 'auto';
  const tailscaleIp = (wantedMode === 'auto' || wantedMode === 'tailscale')
    ? await detectTailscaleIp() : null;
  const lanIp = wantedMode === 'lan' ? detectLanIp() : null;
  // Throws (fail loudly, exit 1 via main().catch) when the chosen mode
  // cannot be satisfied — never silently bind a different address.
  const bind = resolveBindHosts(config, { tailscaleIp, lanIp });
  const bindHosts = bind.hosts;

  const museBin = await resolveMuseBin();
  const tmuxBin = await resolveTmuxBin();
  log(`luna-bridge v${VERSION} starting`);
  if (opts.foreground) {
    log('[env] foreground mode: running in this terminal, logs to stdout (Ctrl+C to stop)');
  }
  log(`[env] muse: ${museBin || `NOT FOUND (muse_bin=${config.muse_bin})`}`);
  log(`[env] tmux: ${tmuxBin || `NOT FOUND (tmux_bin=${config.tmux_bin}) — shared sessions unavailable until tmux is installed`}`);
  if (wantedMode === 'auto' || wantedMode === 'tailscale') {
    log(`[env] tailscale ip: ${tailscaleIp || 'not detected (Tailscale is optional)'}`);
  }
  log(`[env] mode: ${config.mode} (flags: ${modeFlags(config.mode).join(' ') || '(defaults)'})`);
  log(`[env] data dir: ${config.dataDir}`);
  if (config.allowedWorkdirs.length > 0) {
    log(`[env] allowed_workdirs: ${config.allowedWorkdirs.join(', ')} (jobs/sessions must start inside one of these; start directory only — see README)`);
  } else {
    log('[env] allowed_workdirs: not set (no workdir restriction)');
  }
  log(`[net] bind_mode: ${bind.mode}`);

  // One http.Server per bind address: calling listen() twice on the same
  // server throws ERR_SERVER_ALREADY_LISTEN, so each address gets its own.
  // A failed bind (e.g. a Tailscale IP the OS cannot bind, EADDRNOTAVAIL)
  // must not kill the server — warn and keep the addresses that work.
  const bound = [];
  for (const host of bindHosts) {
    try {
      const server = http.createServer(handleRequest);
      await new Promise((resolve, reject) => {
        server.once('error', reject);
        server.listen(config.port, host, () => {
          log(`[http] listening on http://${host}:${config.port}`);
          resolve();
        });
      });
      bound.push(host);
    } catch (err) {
      log(`[warn] could not listen on ${host}:${config.port}: ${err.message}`);
    }
  }
  if (bound.length === 0) {
    throw new Error(`could not bind to any address (${bindHosts.join(', ')})`);
  }
  // Keep-awake (opt-in): hold the idle-sleep assertion from here on, and
  // release it on shutdown. Without a handler, SIGTERM/SIGINT would kill
  // the process before the caffeinate child could be reaped (its
  // `-w <pid>` would still end it, but kill it explicitly as specified).
  startKeepAwake();
  for (const sig of ['SIGINT', 'SIGTERM']) {
    process.on(sig, () => {
      stopKeepAwake();
      process.exit(0);
    });
  }
  process.on('exit', stopKeepAwake);
  log(`[net] Listening on: ${bound.map((h) => `http://${h}:${config.port}`).join(', ')} (bind_mode: ${bind.mode})`);
  // Reach line from the addresses that actually bound (a failed bind
  // above only warned), so it never claims an address that is not live.
  log(`[net] How a client reaches it: ${describeReach(bind.mode, bound, config.port, tailscaleIp)}`);
}

// Exported for the test suite (test/run-tests.sh); requiring this file
// does not start the server.
module.exports = {
  BIND_MODES,
  USAGE,
  detectLanIp,
  expandHomeDir,
  isPathInsideDir,
  isValidBindHost,
  isWorkdirAllowed,
  normalizeAllowedWorkdirs,
  parseArgs,
  resolveBindHosts,
  resolveWorkdirPath,
  startKeepAwake,
  stopKeepAwake,
};

if (require.main === module) {
  let opts;
  try {
    opts = parseArgs(process.argv.slice(2));
  } catch (err) {
    console.error(`[fatal] ${err.message}`);
    process.exit(2);
  }
  if (opts.help) {
    console.log(USAGE);
  } else {
    main(opts).catch((err) => {
      console.error(`[fatal] ${err.message}`);
      process.exit(1);
    });
  }
}
