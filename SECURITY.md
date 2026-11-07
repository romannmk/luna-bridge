# Security policy

## Reporting a vulnerability

Do **not** open a public issue for a security problem.

Report it privately through GitHub: open the repository's **Security** tab
and choose **Report a vulnerability** (GitHub private vulnerability
reporting). Include the affected file or endpoint, how to reproduce the
problem, and what an attacker gains. You should receive an acknowledgement
within a few days; fixes for confirmed issues are released as soon as
practical, and reporters are credited unless they ask not to be.

Please do not include anyone's live bridge token, private network address, or
other secret in a report. A redacted log excerpt is enough.

## Security model in brief

luna-bridge is a small HTTP server that runs a coding-agent CLI on the
owner's own machine. Every endpoint except `GET /health` requires an
`Authorization: Bearer <token>` header; the token is a 32-byte random value
stored in a `0600` file, compared in constant time, and never printed or
logged. The server binds only to the addresses selected by `bind_mode`
(127.0.0.1 when no transport is configured; never `0.0.0.0`), so by default
no port is reachable from outside the machine — remote access requires an
explicit private transport the owner chooses (for example a mesh VPN, an SSH
forward, or a tunnel in front of 127.0.0.1). The server only ever spawns the
one configured agent binary (plus tmux for shared sessions and, opt-in on
macOS, `caffeinate`); it never executes arbitrary shell commands from
requests. An optional `allowed_workdirs` config (array of absolute
paths) restricts where jobs and sessions may *start* (403 outside the
list); it does not confine the agent afterwards — it still runs as the
owner's user and can `cd` elsewhere inside a session, so true
confinement would need OS-level sandboxing (`sandbox-exec` or a
separate user), which is out of scope. Treat the token as full access to that agent on that machine:
whoever holds it can run tasks as the user who runs the bridge. Revoke
access by stopping the bridge and rotating the token (delete the token file
and restart). See "Security model" in [README.md](README.md) for details.
