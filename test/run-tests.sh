#!/bin/sh
# muse-bridge end-to-end test (runs the server locally with a FAKE muse CLI).
# Usage: sh test/run-tests.sh
# Requires: node, curl. Exits non-zero if any check fails.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d /tmp/muse-bridge-test.XXXXXX)"
# The fake muse fixture must be executable: the server spawns it directly.
# A checkout (or an API push) can lose the exec bit, so enforce it here.
chmod +x "$ROOT/test/fake-muse.sh" 2>/dev/null || true
PORT=8799
TOKEN="test-token-do-not-use-in-production"
export MUSE_BRIDGE_TOKEN="$TOKEN"

mkdir -p "$TMP/work" "$TMP/data"
cat > "$TMP/config.json" <<EOF
{
  "port": $PORT,
  "bind_host": "127.0.0.1",
  "data_dir": "$TMP/data",
  "default_workdir": "$TMP/work",
  "muse_bin": "$ROOT/test/fake-muse.sh",
  "mode": "unrestricted",
  "max_model_steps": 0
}
EOF
export MUSE_BRIDGE_CONFIG="$TMP/config.json"

PASS=0
FAIL=0
check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1)); echo "PASS: $1"
  else
    FAIL=$((FAIL + 1)); echo "FAIL: $1 (expected [$2], got [$3])"
  fi
}
contains() { # contains <name> <needle> <haystack>
  case "$3" in
    *"$2"*) PASS=$((PASS + 1)); echo "PASS: $1" ;;
    *) FAIL=$((FAIL + 1)); echo "FAIL: $1 (missing [$2])" ;;
  esac
}

# --- start server -----------------------------------------------------------
node "$ROOT/server.js" > "$TMP/server.log" 2>&1 &
SERVER_PID=$!
CREATED_TMUX=""
cleanup_tmux() {
  # Kill only the tmux sessions this suite created (never anything else).
  for s in $CREATED_TMUX; do
    tmux kill-session -t "$s" 2>/dev/null
  done
}
trap 'kill $SERVER_PID 2>/dev/null; cleanup_tmux; rm -rf "$TMP"' EXIT
BASE="http://127.0.0.1:$PORT"
AUTH="Authorization: Bearer $TOKEN"

# wait for health (no auth required)
i=0
until curl -s "$BASE/health" >/dev/null 2>&1; do
  i=$((i + 1)); [ "$i" -gt 50 ] && { echo "FAIL: server did not start"; cat "$TMP/server.log"; exit 1; }
  sleep 0.2
done

# --- 1. health --------------------------------------------------------------
HEALTH="$(curl -s "$BASE/health")"
contains "health ok" '"ok":true' "$HEALTH"
contains "health version" '"version":"0.1.0"' "$HEALTH"

# --- 2. auth: no token -> 401 ----------------------------------------------
CODE="$(curl -s -o /dev/null -w '%{http_code}' "$BASE/jobs")"
check "no token -> 401" "401" "$CODE"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer wrong" "$BASE/jobs")"
check "wrong token -> 401" "401" "$CODE"

# --- 3. upload ---------------------------------------------------------------
printf 'fake screenshot bytes' > "$TMP/shot.png"
UP="$(curl -s -w '\n%{http_code}' -X POST -H "$AUTH" -H 'X-Filename: shot.png' \
  --data-binary @"$TMP/shot.png" "$BASE/upload")"
UP_CODE="$(echo "$UP" | tail -1)"
UP_BODY="$(echo "$UP" | sed -e '$d')"
check "upload status 201" "201" "$UP_CODE"
contains "upload returns path" '"path"' "$UP_BODY"
UP_PATH="$(echo "$UP_BODY" | sed -n 's/.*"path": *"\([^"]*\)".*/\1/p')"
[ -f "$UP_PATH" ] && check "uploaded file exists on disk" "yes" "yes" || check "uploaded file exists on disk" "yes" "no"

# upload with path traversal in the name must be sanitized, not escape inbox
UP2="$(curl -s -X POST -H "$AUTH" -H 'X-Filename: ../../evil.txt' --data-binary 'x' "$BASE/upload")"
case "$UP2" in
  *"..\""* | *"../"*) FAIL=$((FAIL + 1)); echo "FAIL: traversal name not sanitized: $UP2" ;;
  *) PASS=$((PASS + 1)); echo "PASS: traversal filename sanitized" ;;
esac

# --- 4. create a job, poll until done ---------------------------------------
JOB="$(curl -s -X POST -H "$AUTH" -H 'Content-Type: application/json' -d "{\"prompt\": \"fix the bug\", \"workdir\": \"$TMP/work\", \"attachments\": [\"$UP_PATH\"]}" "$BASE/jobs")"
JOB_ID="$(echo "$JOB" | sed -n 's/.*"job_id": *"\([^"]*\)".*/\1/p')"
[ -n "$JOB_ID" ] && check "job created (got id)" "yes" "yes" || check "job created (got id)" "yes" "no"

STATUS=""
i=0
while [ "$i" -lt 50 ]; do
  STATUS="$(curl -s -H "$AUTH" "$BASE/jobs/$JOB_ID")"
  case "$STATUS" in
    *'"status":"done"'*|*'"status":"failed"'*|*'"status":"cancelled"'*) break ;;
  esac
  i=$((i + 1)); sleep 0.2
done
contains "job finished done" '"status":"done"' "$STATUS"
contains "job output has fake-muse lines" 'fake-muse: step 3/3 done' "$STATUS"
contains "job output shows prompt" 'fix the bug' "$STATUS"
contains "job exit_code 0" '"exit_code":0' "$STATUS"

# --- 5. failing job ----------------------------------------------------------
JOBF="$(curl -s -X POST -H "$AUTH" -H 'Content-Type: application/json' -d "{\"prompt\": \"please fail\", \"workdir\": \"$TMP/work\"}" "$BASE/jobs")"
JOBF_ID="$(echo "$JOBF" | sed -n 's/.*"job_id": *"\([^"]*\)".*/\1/p')"
i=0
while [ "$i" -lt 50 ]; do
  STATUSF="$(curl -s -H "$AUTH" "$BASE/jobs/$JOBF_ID")"
  case "$STATUSF" in
    *'"status":"failed"'*) break ;;
  esac
  i=$((i + 1)); sleep 0.2
done
contains "failing job -> failed" '"status":"failed"' "$STATUSF"
contains "failing job exit_code 1" '"exit_code":1' "$STATUSF"

# --- 6. cancel a slow job -----------------------------------------------------
JOBS="$(curl -s -X POST -H "$AUTH" -H 'Content-Type: application/json' -d "{\"prompt\": \"slow job please\", \"workdir\": \"$TMP/work\"}" "$BASE/jobs")"
JOBS_ID="$(echo "$JOBS" | sed -n 's/.*"job_id": *"\([^"]*\)".*/\1/p')"
sleep 1
CANCEL="$(curl -s -X POST -H "$AUTH" "$BASE/jobs/$JOBS_ID/cancel")"
contains "cancel accepted" 'cancelling' "$CANCEL"
sleep 1
STATUSC="$(curl -s -H "$AUTH" "$BASE/jobs/$JOBS_ID")"
contains "cancelled job -> cancelled" '"status":"cancelled"' "$STATUSC"

# --- 7. mode get/set -----------------------------------------------------------
MODE="$(curl -s -H "$AUTH" "$BASE/mode")"
contains "mode is unrestricted" '"mode":"unrestricted"' "$MODE"
SETM="$(curl -s -X POST -H "$AUTH" -H 'Content-Type: application/json' -d '{"mode":"read-only"}' "$BASE/mode")"
contains "mode set to read-only" '"mode":"read-only"' "$SETM"
BADMODE_CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "$AUTH" -H 'Content-Type: application/json' -d '{"mode":"explode"}' "$BASE/mode")"
check "bad mode -> 400" "400" "$BADMODE_CODE"
# restore
curl -s -X POST -H "$AUTH" -H 'Content-Type: application/json' -d '{"mode":"unrestricted"}' "$BASE/mode" >/dev/null

# --- 8. bad input -> 400 -------------------------------------------------------
CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "$AUTH" -H 'Content-Type: application/json' -d '{"prompt": ""}' "$BASE/jobs")"
check "empty prompt -> 400" "400" "$CODE"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "$AUTH" -H 'Content-Type: application/json' -d "{\"prompt\": \"x\", \"workdir\": \"/does/not/exist\"}" "$BASE/jobs")"
check "bad workdir -> 400" "400" "$CODE"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "$AUTH" -H 'Content-Type: application/json' -d "{\"prompt\": \"x\", \"attachments\": [\"/etc/passwd\"]}" "$BASE/jobs")"
check "attachment outside inbox -> 400" "400" "$CODE"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -H "$AUTH" "$BASE/jobs/does-not-exist")"
check "unknown job -> 404" "404" "$CODE"

# --- 8b. model/effort: passthrough, validation, full enum --------------------
MEJOB="$(curl -s -X POST -H "$AUTH" -H 'Content-Type: application/json' -d "{\"prompt\": \"tiny hello\", \"workdir\": \"$TMP/work\", \"model\": \"muse-spark-1.3\", \"effort\": \"low\"}" "$BASE/jobs")"
MEJOB_ID="$(echo "$MEJOB" | sed -n 's/.*"job_id": *"\([^"]*\)".*/\1/p')"
i=0
while [ "$i" -lt 50 ]; do
  MESTATUS="$(curl -s -H "$AUTH" "$BASE/jobs/$MEJOB_ID")"
  case "$MESTATUS" in
    *'"status":"done"'*|*'"status":"failed"'*|*'"status":"cancelled"'*) break ;;
  esac
  i=$((i + 1)); sleep 0.2
done
contains "model/effort job finished done" '"status":"done"' "$MESTATUS"
contains "model flag reaches muse" '--model muse-spark-1.3' "$MESTATUS"
contains "effort flag reaches muse" '--reasoning-effort low' "$MESTATUS"
contains "job reports model" '"model":"muse-spark-1.3"' "$MESTATUS"
contains "job reports effort" '"effort":"low"' "$MESTATUS"
MEMETA="$(cat "$TMP/data/jobs/$MEJOB_ID/meta.json")"
contains "job meta.json records model" '"model": "muse-spark-1.3"' "$MEMETA"
contains "job meta.json records effort" '"effort": "low"' "$MEMETA"

# every documented effort tier is accepted and passed through (jobs run in parallel)
for TIER in none minimal low medium high xhigh max ultra; do
  TJ="$(curl -s -X POST -H "$AUTH" -H 'Content-Type: application/json' -d "{\"prompt\": \"tiny hello\", \"workdir\": \"$TMP/work\", \"effort\": \"$TIER\"}" "$BASE/jobs")"
  TJ_ID="$(echo "$TJ" | sed -n 's/.*"job_id": *"\([^"]*\)".*/\1/p')"
  eval "TIERJOB_$TIER=\"$TJ_ID\""
done
for TIER in none minimal low medium high xhigh max ultra; do
  eval "TJ_ID=\"\$TIERJOB_$TIER\""
  i=0
  while [ "$i" -lt 50 ]; do
    TS="$(curl -s -H "$AUTH" "$BASE/jobs/$TJ_ID")"
    case "$TS" in
      *'"status":"done"'*) break ;;
    esac
    i=$((i + 1)); sleep 0.2
  done
  contains "effort $TIER passed to muse" "--reasoning-effort $TIER" "$TS"
done

# validation: bad effort / bad model -> 400
CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "$AUTH" -H 'Content-Type: application/json' -d '{"prompt": "x", "effort": "turbo"}' "$BASE/jobs")"
check "bad effort -> 400" "400" "$CODE"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "$AUTH" -H 'Content-Type: application/json' -d '{"prompt": "x", "effort": ""}' "$BASE/jobs")"
check "empty effort -> 400" "400" "$CODE"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "$AUTH" -H 'Content-Type: application/json' -d '{"prompt": "x", "effort": 123}' "$BASE/jobs")"
check "numeric effort -> 400" "400" "$CODE"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "$AUTH" -H 'Content-Type: application/json' -d '{"prompt": "x", "model": ""}' "$BASE/jobs")"
check "empty model -> 400" "400" "$CODE"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "$AUTH" -H 'Content-Type: application/json' -d '{"prompt": "x", "model": 123}' "$BASE/jobs")"
check "numeric model -> 400" "400" "$CODE"

# --- 9. shared sessions (real tmux + fake muse in interactive mode) --------
if command -v tmux >/dev/null 2>&1; then
  # auth
  CODE="$(curl -s -o /dev/null -w '%{http_code}' "$BASE/sessions")"
  check "sessions: no token -> 401" "401" "$CODE"
  CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer [REDACTED]" -H 'Content-Type: application/json' -d '{"prompt":"x"}' "$BASE/sessions")"
  check "sessions: wrong token -> 401" "401" "$CODE"

  # validation
  CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "$AUTH" -H 'Content-Type: application/json' -d '{"prompt": ""}' "$BASE/sessions")"
  check "sessions: empty prompt -> 400" "400" "$CODE"
  CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "$AUTH" -H 'Content-Type: application/json' -d '{"prompt": "x", "workdir": "/does/not/exist"}' "$BASE/sessions")"
  check "sessions: bad workdir -> 400" "400" "$CODE"
  CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "$AUTH" -H 'Content-Type: application/json' -d '{"prompt": "x", "mode": "explode"}' "$BASE/sessions")"
  check "sessions: bad mode -> 400" "400" "$CODE"
  CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "$AUTH" -H 'Content-Type: application/json' -d '{"prompt": "x", "effort": "turbo"}' "$BASE/sessions")"
  check "sessions: bad effort -> 400" "400" "$CODE"
  CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "$AUTH" -H 'Content-Type: application/json' -d '{"prompt": "x", "model": ""}' "$BASE/sessions")"
  check "sessions: empty model -> 400" "400" "$CODE"
  CODE="$(curl -s -o /dev/null -w '%{http_code}' -H "$AUTH" "$BASE/sessions/does-not-exist")"
  check "sessions: unknown session -> 404" "404" "$CODE"

  # create session A (full lifecycle: create -> pane -> input -> kill)
  SESS="$(curl -s -w '\n%{http_code}' -X POST -H "$AUTH" -H 'Content-Type: application/json' -d "{\"prompt\": \"interactive hello alpha\", \"workdir\": \"$TMP/work\"}" "$BASE/sessions")"
  SESS_CODE="$(echo "$SESS" | tail -1)"
  SESS_BODY="$(echo "$SESS" | sed -e '$d')"
  check "session create status 201" "201" "$SESS_CODE"
  SESS_ID="$(echo "$SESS_BODY" | sed -n 's/.*"session_id": *"\([^"]*\)".*/\1/p')"
  SESS_TMUX="$(echo "$SESS_BODY" | sed -n 's/.*"tmux_session": *"\([^"]*\)".*/\1/p')"
  [ -n "$SESS_ID" ] && check "session created (got id)" "yes" "yes" || check "session created (got id)" "yes" "no"
  check "tmux session named muse-<id>" "muse-$SESS_ID" "$SESS_TMUX"
  contains "attach_command format" "tmux attach -t muse-$SESS_ID" "$SESS_BODY"
  contains "session starts alive" '"status":"alive"' "$SESS_BODY"
  CREATED_TMUX="$CREATED_TMUX $SESS_TMUX"
  [ -f "$TMP/data/sessions/$SESS_ID/meta.json" ] && check "session meta.json persisted" "yes" "yes" || check "session meta.json persisted" "yes" "no"

  # pane: poll until the fake TUI shows up
  PANE=""
  i=0
  while [ "$i" -lt 50 ]; do
    PANE="$(curl -s -H "$AUTH" "$BASE/sessions/$SESS_ID/pane")"
    case "$PANE" in
      *"fake-muse TUI ready"*) break ;;
    esac
    i=$((i + 1)); sleep 0.2
  done
  contains "pane shows TUI output" 'fake-muse TUI ready' "$PANE"
  contains "pane idle hint true" '"idle":true' "$PANE"

  # list + get
  SLIST="$(curl -s -H "$AUTH" "$BASE/sessions")"
  contains "session list contains session" "$SESS_ID" "$SLIST"
  contains "session list shows alive" '"status":"alive"' "$SLIST"
  SGET="$(curl -s -H "$AUTH" "$BASE/sessions/$SESS_ID")"
  contains "session get has attach command" "tmux attach -t muse-$SESS_ID" "$SGET"

  # input: owner-asked typing; the fake TUI echoes it back into the pane
  INP="$(curl -s -X POST -H "$AUTH" -H 'Content-Type: application/json' -d '{"text":"hello owner"}' "$BASE/sessions/$SESS_ID/input")"
  contains "input accepted" '"sent_bytes":11' "$INP"
  PANE2=""
  i=0
  while [ "$i" -lt 50 ]; do
    PANE2="$(curl -s -H "$AUTH" "$BASE/sessions/$SESS_ID/pane")"
    case "$PANE2" in
      *"fake-muse heard: hello owner"*) break ;;
    esac
    i=$((i + 1)); sleep 0.2
  done
  contains "pane shows typed input echo" 'fake-muse heard: hello owner' "$PANE2"
  CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "$AUTH" -H 'Content-Type: application/json' -d '{"text":""}' "$BASE/sessions/$SESS_ID/input")"
  check "sessions: empty input -> 400" "400" "$CODE"

  # kill session A
  KILL="$(curl -s -X POST -H "$AUTH" "$BASE/sessions/$SESS_ID/kill")"
  contains "kill marks session dead" '"status":"dead"' "$KILL"
  SGET_DEAD="$(curl -s -H "$AUTH" "$BASE/sessions/$SESS_ID")"
  contains "dead session reads back dead" '"status":"dead"' "$SGET_DEAD"
  PANE_CODE="$(curl -s -o /dev/null -w '%{http_code}' -H "$AUTH" "$BASE/sessions/$SESS_ID/pane")"
  check "pane of dead session -> 404" "404" "$PANE_CODE"
  if tmux has-session -t "$SESS_TMUX" 2>/dev/null; then
    check "tmux session actually gone" "gone" "alive"
  else
    check "tmux session actually gone" "gone" "gone"
  fi

  # create session B and leave it alive: the restart test below must find it.
  # It carries model/effort so the pane proves the flags reach the TUI too.
  SESSB="$(curl -s -X POST -H "$AUTH" -H 'Content-Type: application/json' -d "{\"prompt\": \"interactive hello beta\", \"workdir\": \"$TMP/work\", \"model\": \"muse-wonder-full-1.0\", \"effort\": \"xhigh\"}" "$BASE/sessions")"
  SESSB_ID="$(echo "$SESSB" | sed -n 's/.*"session_id": *"\([^"]*\)".*/\1/p')"
  SESSB_TMUX="muse-$SESSB_ID"
  contains "session create echoes model" '"model":"muse-wonder-full-1.0"' "$SESSB"
  contains "session create echoes effort" '"effort":"xhigh"' "$SESSB"
  CREATED_TMUX="$CREATED_TMUX $SESSB_TMUX"
  i=0
  while [ "$i" -lt 50 ]; do
    PANE_B="$(curl -s -H "$AUTH" "$BASE/sessions/$SESSB_ID/pane")"
    case "$PANE_B" in
      *"fake-muse TUI ready"*) break ;;
    esac
    i=$((i + 1)); sleep 0.2
  done
  contains "second session pane ready" 'fake-muse TUI ready' "$PANE_B"
  contains "session model flag reaches TUI" '--model muse-wonder-full-1.0' "$PANE_B"
  contains "session effort flag reaches TUI" '--reasoning-effort xhigh' "$PANE_B"
  SESSB_META="$(cat "$TMP/data/sessions/$SESSB_ID/meta.json")"
  contains "session meta.json records model" '"model": "muse-wonder-full-1.0"' "$SESSB_META"
  contains "session meta.json records effort" '"effort": "xhigh"' "$SESSB_META"
else
  echo "SKIP: tmux not installed - session tests skipped"
fi

# --- 9b. restart: job survives from disk -------------------------------------
kill $SERVER_PID 2>/dev/null
sleep 0.5
node "$ROOT/server.js" > "$TMP/server2.log" 2>&1 &
SERVER_PID=$!
i=0
until curl -s "$BASE/health" >/dev/null 2>&1; do
  i=$((i + 1)); [ "$i" -gt 50 ] && { echo "FAIL: server did not restart"; cat "$TMP/server2.log"; exit 1; }
  sleep 0.2
done
AFTER="$(curl -s -H "$AUTH" "$BASE/jobs/$JOB_ID")"
contains "job survives restart (from disk)" '"status":"done"' "$AFTER"
contains "restarted job keeps output" 'fake-muse: step 3/3 done' "$AFTER"
contains "restarted job keeps null model (unset run)" '"model":null' "$AFTER"
contains "restarted job keeps null effort (unset run)" '"effort":null' "$AFTER"
AFTERME="$(curl -s -H "$AUTH" "$BASE/jobs/$MEJOB_ID")"
contains "restarted model/effort job keeps model" '"model":"muse-spark-1.3"' "$AFTERME"
contains "restarted model/effort job keeps effort" '"effort":"low"' "$AFTERME"

if command -v tmux >/dev/null 2>&1; then
  # sessions survive a bridge restart: the tmux server is independent, and
  # GET /sessions reconciles recorded status with live tmux state.
  AFTER_SESS="$(curl -s -H "$AUTH" "$BASE/sessions")"
  contains "session survives restart (still listed)" "$SESSB_ID" "$AFTER_SESS"
  AFTER_SGET="$(curl -s -H "$AUTH" "$BASE/sessions/$SESSB_ID")"
  contains "restarted session still alive" '"status":"alive"' "$AFTER_SGET"
  contains "restarted session keeps model" '"model":"muse-wonder-full-1.0"' "$AFTER_SGET"
  contains "restarted session keeps effort" '"effort":"xhigh"' "$AFTER_SGET"
  AFTER_PANE="$(curl -s -H "$AUTH" "$BASE/sessions/$SESSB_ID/pane")"
  contains "restarted session pane readable" 'fake-muse TUI ready' "$AFTER_PANE"
fi

# --- 9c. config defaults: default_model/default_effort ------------------------
# Rewrite the config with defaults, restart, and verify runs without
# per-request fields pick the defaults up — while per-request values win.
cat > "$TMP/config.json" <<EOF
{
  "port": $PORT,
  "bind_host": "127.0.0.1",
  "data_dir": "$TMP/data",
  "default_workdir": "$TMP/work",
  "muse_bin": "$ROOT/test/fake-muse.sh",
  "mode": "unrestricted",
  "max_model_steps": 0,
  "default_model": "muse-wonder-1.0",
  "default_effort": "medium"
}
EOF
kill $SERVER_PID 2>/dev/null
sleep 0.5
node "$ROOT/server.js" > "$TMP/server3.log" 2>&1 &
SERVER_PID=$!
i=0
until curl -s "$BASE/health" >/dev/null 2>&1; do
  i=$((i + 1)); [ "$i" -gt 50 ] && { echo "FAIL: server did not restart with defaults"; cat "$TMP/server3.log"; exit 1; }
  sleep 0.2
done
DJOB="$(curl -s -X POST -H "$AUTH" -H 'Content-Type: application/json' -d "{\"prompt\": \"tiny hello\", \"workdir\": \"$TMP/work\"}" "$BASE/jobs")"
DJOB_ID="$(echo "$DJOB" | sed -n 's/.*"job_id": *"\([^"]*\)".*/\1/p')"
i=0
while [ "$i" -lt 50 ]; do
  DSTATUS="$(curl -s -H "$AUTH" "$BASE/jobs/$DJOB_ID")"
  case "$DSTATUS" in
    *'"status":"done"'*|*'"status":"failed"'*) break ;;
  esac
  i=$((i + 1)); sleep 0.2
done
contains "default model flag reaches muse" '--model muse-wonder-1.0' "$DSTATUS"
contains "default effort flag reaches muse" '--reasoning-effort medium' "$DSTATUS"
contains "default model reported" '"model":"muse-wonder-1.0"' "$DSTATUS"
contains "default effort reported" '"effort":"medium"' "$DSTATUS"
# per-request values override the config defaults
OJOB="$(curl -s -X POST -H "$AUTH" -H 'Content-Type: application/json' -d "{\"prompt\": \"tiny hello\", \"workdir\": \"$TMP/work\", \"effort\": \"low\"}" "$BASE/jobs")"
OJOB_ID="$(echo "$OJOB" | sed -n 's/.*"job_id": *"\([^"]*\)".*/\1/p')"
i=0
while [ "$i" -lt 50 ]; do
  OSTATUS="$(curl -s -H "$AUTH" "$BASE/jobs/$OJOB_ID")"
  case "$OSTATUS" in
    *'"status":"done"'*|*'"status":"failed"'*) break ;;
  esac
  i=$((i + 1)); sleep 0.2
done
contains "override effort flag reaches muse" '--reasoning-effort low' "$OSTATUS"
contains "override effort reported" '"effort":"low"' "$OSTATUS"
contains "default model still applies on override" '--model muse-wonder-1.0' "$OSTATUS"

# --- 10. job list -------------------------------------------------------------
LIST="$(curl -s -H "$AUTH" "$BASE/jobs")"
contains "list contains jobs" '"jobs"' "$LIST"
contains "list contains first job" "$JOB_ID" "$LIST"

if command -v tmux >/dev/null 2>&1; then
  # cleanup: kill the leftover session, verify it is really gone
  KILLB="$(curl -s -X POST -H "$AUTH" "$BASE/sessions/$SESSB_ID/kill")"
  contains "cleanup kill marks dead" '"status":"dead"' "$KILLB"
  if tmux has-session -t "$SESSB_TMUX" 2>/dev/null; then
    check "cleanup tmux session gone" "gone" "alive"
  else
    check "cleanup tmux session gone" "gone" "gone"
  fi
fi

# --- 11. bind_mode resolution (unit, via server.js exports) -------------------
# The pure resolver is the contract for "Tailscale is optional": every mode,
# with and without a detected Tailscale/LAN IP, plus the legacy no-bind_mode
# behaviour. Requiring server.js must not start a server (require.main guard).
cat > "$TMP/bind-unit.js" <<'UNITEOF'
'use strict';
const { resolveBindHosts, detectLanIp, isValidBindHost } = require(process.argv[2]);
let pass = 0; let fail = 0;
function hosts(name, cfg, detected, expected) {
  let got;
  try { got = resolveBindHosts(cfg, detected).hosts.join(','); } catch (e) { got = `THrew: ${e.message}`; }
  if (got === expected) { pass += 1; console.log(`PASS: bind unit: ${name}`); }
  else { fail += 1; console.log(`FAIL: bind unit: ${name} (expected [${expected}], got [${got}])`); }
}
function throws(name, cfg, detected, needle) {
  try {
    resolveBindHosts(cfg, detected);
    fail += 1; console.log(`FAIL: bind unit: ${name} (did not throw)`);
  } catch (e) {
    if (e.message.includes(needle)) { pass += 1; console.log(`PASS: bind unit: ${name}`); }
    else { fail += 1; console.log(`FAIL: bind unit: ${name} (threw [${e.message}], missing [${needle}])`); }
  }
}
function eq(name, got, expected) {
  if (got === expected) { pass += 1; console.log(`PASS: bind unit: ${name}`); }
  else { fail += 1; console.log(`FAIL: bind unit: ${name} (expected [${expected}], got [${got}])`); }
}
const TS = { tailscaleIp: '100.64.0.10', lanIp: '192.168.1.20' };
const NONE = { tailscaleIp: null, lanIp: null };
// auto: Tailscale IP if detected (+127), otherwise 127 only; never throws
hosts('auto with Tailscale IP', { bind_mode: 'auto' }, TS, '127.0.0.1,100.64.0.10');
hosts('auto without Tailscale IP', { bind_mode: 'auto' }, NONE, '127.0.0.1');
hosts('auto without Tailscale ignores bind_host', { bind_mode: 'auto', bind_host: '192.168.1.99' }, NONE, '127.0.0.1');
// no bind_mode at all (existing configs): same as before bind_mode existed
hosts('no bind_mode with Tailscale IP (legacy)', {}, TS, '127.0.0.1,100.64.0.10');
hosts('no bind_mode, bind_host set, no Tailscale (legacy)', { bind_host: '192.168.1.99' }, NONE, '127.0.0.1,192.168.1.99');
hosts('no bind_mode, bind_host set, Tailscale wins (legacy)', { bind_host: '192.168.1.99' }, TS, '127.0.0.1,100.64.0.10');
hosts('no bind_mode, nothing detected (legacy)', {}, NONE, '127.0.0.1');
// localhost: 127 only, even when a Tailscale IP exists
hosts('localhost with Tailscale present', { bind_mode: 'localhost' }, TS, '127.0.0.1');
// tailscale: that IP only; without one it must fail loudly
hosts('tailscale with Tailscale IP', { bind_mode: 'tailscale' }, TS, '100.64.0.10');
throws('tailscale without IP fails loudly', { bind_mode: 'tailscale' }, NONE, 'bind_mode is "tailscale" but no Tailscale IP was found');
// lan: detected LAN IP; the fallback when none exists is a loud failure
hosts('lan with LAN IP', { bind_mode: 'lan' }, TS, '192.168.1.20');
throws('lan without LAN IP fails loudly (lan fallback)', { bind_mode: 'lan' }, NONE, 'bind_mode is "lan" but no LAN IPv4 address was found');
// custom: bind_host required and must be a valid IP/hostname, never wildcard
hosts('custom with bind_host IP', { bind_mode: 'custom', bind_host: '192.168.1.50' }, NONE, '192.168.1.50');
hosts('custom with bind_host hostname', { bind_mode: 'custom', bind_host: 'mac.local' }, NONE, 'mac.local');
throws('custom without bind_host fails loudly', { bind_mode: 'custom' }, NONE, 'bind_mode is "custom" but bind_host is not set');
throws('custom with invalid bind_host fails loudly', { bind_mode: 'custom', bind_host: 'not a host!!' }, NONE, 'is not a valid IP address or hostname');
throws('custom with wildcard bind_host fails loudly', { bind_mode: 'custom', bind_host: '0.0.0.0' }, NONE, 'never binds to all interfaces');
// invalid mode name
throws('invalid bind_mode fails loudly', { bind_mode: 'internet' }, NONE, 'invalid bind_mode');
// reach line: plain language, mentions the address a client should use
eq('reach line for auto+Tailscale names the tailnet URL',
  resolveBindHosts({ bind_mode: 'auto', port: 8787 }, TS).reach.includes('http://100.64.0.10:8787'), true);
eq('reach line for localhost says this machine only',
  resolveBindHosts({ bind_mode: 'localhost', port: 8787 }, NONE).reach.includes('Only programs on this machine'), true);
// LAN detection from OS interfaces: skips loopback/link-local/Tailscale CGNAT
const ifaces = {
  lo0: [{ address: '127.0.0.1', family: 'IPv4', internal: true }],
  utun9: [{ address: '100.64.0.10', family: 'IPv4', internal: false }],
  en7: [{ address: '169.254.1.2', family: 'IPv4', internal: false }],
  en0: [{ address: '192.168.1.20', family: 'IPv4', internal: false }],
};
eq('detectLanIp picks the LAN IPv4', detectLanIp(ifaces), '192.168.1.20');
eq('detectLanIp with no LAN interface -> null', detectLanIp({ lo0: ifaces.lo0, utun9: ifaces.utun9 }), null);
// bind_host validation
eq('isValidBindHost accepts an IPv4', isValidBindHost('10.0.0.5'), true);
eq('isValidBindHost accepts localhost', isValidBindHost('localhost'), true);
eq('isValidBindHost rejects junk', isValidBindHost('bad host!!'), false);
eq('isValidBindHost rejects empty', isValidBindHost(''), false);
console.log(`BINDUNIT_PASS=${pass} BINDUNIT_FAIL=${fail}`);
process.exit(fail === 0 ? 0 : 1);
UNITEOF
BINDOUT="$(node "$TMP/bind-unit.js" "$ROOT/server.js")"
echo "$BINDOUT" | grep -v '^BINDUNIT_' || true
BPASS="$(echo "$BINDOUT" | sed -n 's/.*BINDUNIT_PASS=\([0-9]*\).*/\1/p')"
BFAIL="$(echo "$BINDOUT" | sed -n 's/.*BINDUNIT_FAIL=\([0-9]*\).*/\1/p')"
PASS=$((PASS + ${BPASS:-0}))
FAIL=$((FAIL + ${BFAIL:-1}))

# --- 12. bind_mode end-to-end (real server spawns, fake tailscale CLI) --------
# A fake `tailscale` on PATH makes detection deterministic on any machine:
# "no-ts" exits 1 with no output (same as the CLI being unusable/absent for
# auto). "fake-ts" reports this machine's real LAN IP as its "Tailscale IP":
# an address the server can really bind on any OS (127.0.0.2 is NOT bindable
# on macOS without a loopback alias). With no LAN IP, the two cases that
# need a second bindable address are skipped (the unit tests above still
# cover their resolution logic).
FAKE_TS_IP="$(node -e 'const {detectLanIp} = require(process.argv[1]); const ip = detectLanIp(); if (ip) console.log(ip);' "$ROOT/server.js")"
mkdir -p "$TMP/no-ts-bin" "$TMP/fake-ts-bin" "$TMP/data-bind"
printf '#!/bin/sh\nexit 1\n' > "$TMP/no-ts-bin/tailscale"
printf '#!/bin/sh\necho %s\n' "$FAKE_TS_IP" > "$TMP/fake-ts-bin/tailscale"
chmod +x "$TMP/no-ts-bin/tailscale" "$TMP/fake-ts-bin/tailscale"

write_bind_config() { # $1=file $2=port $3=json-extra-lines
  cat > "$1" <<EOF
{
  "port": $2,
  "data_dir": "$TMP/data-bind",
  "default_workdir": "$TMP/work",
  "muse_bin": "$ROOT/test/fake-muse.sh",
  "mode": "unrestricted",
  "max_model_steps": 0$3
}
EOF
}
wait_health() { # $1=url
  i=0
  until curl -s -m 2 "$1/health" >/dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -gt 50 ] && return 1
    sleep 0.2
  done
  return 0
}
expect_startup_fail() { # $1=name $2=config $3=path-prefix $4=log-needle
  MUSE_BRIDGE_CONFIG="$2" PATH="$3:$PATH" node "$ROOT/server.js" > "$TMP/bind-fail.log" 2>&1 &
  BPID=$!
  i=0
  while kill -0 $BPID 2>/dev/null && [ "$i" -lt 50 ]; do i=$((i + 1)); sleep 0.2; done
  if kill -0 $BPID 2>/dev/null; then
    kill $BPID 2>/dev/null
    check "$1: server exits" "exited" "still running"
  else
    wait $BPID; BCODE=$?
    check "$1: server exits non-zero" "1" "$BCODE"
  fi
  contains "$1: clear startup message" "$4" "$(cat "$TMP/bind-fail.log")"
}

# localhost mode: serves on 127.0.0.1, log names mode + address + reach line
write_bind_config "$TMP/bind-localhost.json" 8801 ',
  "bind_mode": "localhost"'
MUSE_BRIDGE_CONFIG="$TMP/bind-localhost.json" PATH="$TMP/no-ts-bin:$PATH" node "$ROOT/server.js" > "$TMP/bind-localhost.log" 2>&1 &
BPID=$!
if wait_health "http://127.0.0.1:8801"; then
  check "bind localhost: health on 127.0.0.1" "ok" "ok"
else
  check "bind localhost: health on 127.0.0.1" "ok" "no-health"; cat "$TMP/bind-localhost.log"
fi
BLOG="$(cat "$TMP/bind-localhost.log")"
contains "bind localhost: log names the mode" 'bind_mode: localhost' "$BLOG"
contains "bind localhost: log lists the address" 'Listening on: http://127.0.0.1:8801' "$BLOG"
contains "bind localhost: log says how a client reaches it" 'How a client reaches it: Only programs on this machine' "$BLOG"
case "$BLOG" in
  *"$TOKEN"*) check "bind localhost: startup log never prints the token" "clean" "token leaked" ;;
  *) check "bind localhost: startup log never prints the token" "clean" "clean" ;;
esac
kill $BPID 2>/dev/null; sleep 0.3

# auto without any Tailscale IP: 127.0.0.1 only, no crash
write_bind_config "$TMP/bind-auto-nots.json" 8802 ',
  "bind_mode": "auto"'
MUSE_BRIDGE_CONFIG="$TMP/bind-auto-nots.json" PATH="$TMP/no-ts-bin:$PATH" node "$ROOT/server.js" > "$TMP/bind-auto-nots.log" 2>&1 &
BPID=$!
if wait_health "http://127.0.0.1:8802"; then
  check "bind auto/no-Tailscale: health on 127.0.0.1" "ok" "ok"
else
  check "bind auto/no-Tailscale: health on 127.0.0.1" "ok" "no-health"; cat "$TMP/bind-auto-nots.log"
fi
contains "bind auto/no-Tailscale: log lists 127 only + later-transport hint" 'add a transport later' "$(cat "$TMP/bind-auto-nots.log")"
kill $BPID 2>/dev/null; sleep 0.3

if [ -n "$FAKE_TS_IP" ]; then
  # auto with a detected Tailscale IP (fake CLI -> $FAKE_TS_IP): binds it too
  write_bind_config "$TMP/bind-auto-ts.json" 8803 ',
    "bind_mode": "auto"'
  MUSE_BRIDGE_CONFIG="$TMP/bind-auto-ts.json" PATH="$TMP/fake-ts-bin:$PATH" node "$ROOT/server.js" > "$TMP/bind-auto-ts.log" 2>&1 &
  BPID=$!
  if wait_health "http://$FAKE_TS_IP:8803"; then
    check "bind auto/Tailscale: health on the Tailscale IP" "ok" "ok"
  else
    check "bind auto/Tailscale: health on the Tailscale IP" "ok" "no-health"; cat "$TMP/bind-auto-ts.log"
  fi
  if wait_health "http://127.0.0.1:8803"; then
    check "bind auto/Tailscale: health also on 127.0.0.1 (existing behaviour)" "ok" "ok"
  else
    check "bind auto/Tailscale: health also on 127.0.0.1 (existing behaviour)" "ok" "no-health"
  fi
  kill $BPID 2>/dev/null; sleep 0.3

  # tailscale mode with a detected IP: binds that IP only, not 127.0.0.1
  write_bind_config "$TMP/bind-ts.json" 8804 ',
    "bind_mode": "tailscale"'
  MUSE_BRIDGE_CONFIG="$TMP/bind-ts.json" PATH="$TMP/fake-ts-bin:$PATH" node "$ROOT/server.js" > "$TMP/bind-ts.log" 2>&1 &
  BPID=$!
  if wait_health "http://$FAKE_TS_IP:8804"; then
    check "bind tailscale: health on the Tailscale IP" "ok" "ok"
  else
    check "bind tailscale: health on the Tailscale IP" "ok" "no-health"; cat "$TMP/bind-ts.log"
  fi
  if curl -s -m 2 "http://127.0.0.1:8804/health" >/dev/null 2>&1; then
    check "bind tailscale: 127.0.0.1 not bound (tailscale only)" "closed" "open"
  else
    check "bind tailscale: 127.0.0.1 not bound (tailscale only)" "closed" "closed"
  fi
  kill $BPID 2>/dev/null; sleep 0.3
else
  echo "SKIP: no LAN IP on this machine - auto/tailscale bind e2e skipped (unit tests above cover resolution)"
fi

# tailscale mode without an IP: fail loudly at startup
write_bind_config "$TMP/bind-ts-fail.json" 8806 ',
  "bind_mode": "tailscale"'
expect_startup_fail "bind tailscale/no-IP" "$TMP/bind-ts-fail.json" "$TMP/no-ts-bin" 'bind_mode is "tailscale" but no Tailscale IP was found'

# custom mode without bind_host: fail loudly at startup
write_bind_config "$TMP/bind-custom-missing.json" 8806 ',
  "bind_mode": "custom"'
expect_startup_fail "bind custom/no-host" "$TMP/bind-custom-missing.json" "$TMP/no-ts-bin" 'bind_mode is "custom" but bind_host is not set'

# custom mode with an invalid bind_host: fail loudly at startup
write_bind_config "$TMP/bind-custom-bad.json" 8806 ',
  "bind_mode": "custom",
  "bind_host": "not a host!!"'
expect_startup_fail "bind custom/bad-host" "$TMP/bind-custom-bad.json" "$TMP/no-ts-bin" 'is not a valid IP address or hostname'

# custom mode with a valid bind_host: binds exactly that address
write_bind_config "$TMP/bind-custom.json" 8805 ',
  "bind_mode": "custom",
  "bind_host": "127.0.0.1"'
MUSE_BRIDGE_CONFIG="$TMP/bind-custom.json" PATH="$TMP/no-ts-bin:$PATH" node "$ROOT/server.js" > "$TMP/bind-custom.log" 2>&1 &
BPID=$!
if wait_health "http://127.0.0.1:8805"; then
  check "bind custom: health on bind_host" "ok" "ok"
else
  check "bind custom: health on bind_host" "ok" "no-health"; cat "$TMP/bind-custom.log"
fi
contains "bind custom: log names the mode" 'bind_mode: custom' "$(cat "$TMP/bind-custom.log")"
kill $BPID 2>/dev/null; sleep 0.3

# invalid bind_mode: fail loudly at startup
write_bind_config "$TMP/bind-invalid.json" 8806 ',
  "bind_mode": "internet"'
expect_startup_fail "bind invalid-mode" "$TMP/bind-invalid.json" "$TMP/no-ts-bin" 'invalid bind_mode'

# --- 13. keep_awake (unit, via server.js exports) ------------------------------
# startKeepAwake is pure-injectable (platform/spawn/log/pid), so the gating
# contract — spawn caffeinate only when enabled AND only on macOS, never
# crash when it cannot start — is testable on any OS with a fake spawn.
cat > "$TMP/keep-awake-unit.js" <<'KAEOF'
'use strict';
const { EventEmitter } = require('node:events');
const srv = require(process.argv[2]);
let pass = 0; let fail = 0;
function eq(name, got, expected) {
  if (got === expected) { pass += 1; console.log(`PASS: keep-awake unit: ${name}`); }
  else { fail += 1; console.log(`FAIL: keep-awake unit: ${name} (expected [${expected}], got [${got}])`); }
}
if (typeof srv.startKeepAwake !== 'function' || typeof srv.stopKeepAwake !== 'function') {
  eq('server.js exports startKeepAwake/stopKeepAwake', 'missing', 'functions');
  console.log(`KAUNIT_PASS=${pass} KAUNIT_FAIL=${fail}`);
  process.exit(1);
}
eq('server.js exports startKeepAwake/stopKeepAwake', 'functions', 'functions');
function fakeSpawn(rec) {
  return (cmd, args) => {
    rec.calls.push(`${cmd} ${args.join(' ')}`);
    const child = new EventEmitter();
    child.killed = false;
    child.kill = () => { child.killed = true; };
    rec.child = child;
    return child;
  };
}
function run(opts) {
  const rec = { calls: [], child: null };
  const logs = [];
  const out = srv.startKeepAwake({ spawnFn: fakeSpawn(rec), logFn: (m) => logs.push(String(m)), pid: 4242, ...opts });
  srv.stopKeepAwake();
  return { rec, logs: logs.join('\n'), out };
}
// disabled -> never spawns, even on macOS
let r = run({ enabled: false, platform: 'darwin' });
eq('disabled on darwin: no spawn', r.rec.calls.length, 0);
eq('disabled on darwin: returns null', r.out, null);
// enabled on macOS -> caffeinate -i -w <own pid>, plain-language log line
r = run({ enabled: true, platform: 'darwin' });
eq('enabled on darwin: spawns caffeinate -i -w <pid>', r.rec.calls.join(','), 'caffeinate -i -w 4242');
eq('enabled on darwin: returns the child', r.out === r.rec.child, true);
eq('enabled on darwin: logs the plain-language line', r.logs.includes('will not idle-sleep while the bridge runs'), true);
// enabled elsewhere -> no spawn, macOS-only log, no crash
r = run({ enabled: true, platform: 'linux' });
eq('enabled on linux: no spawn', r.rec.calls.length, 0);
eq('enabled on linux: returns null', r.out, null);
eq('enabled on linux: logs macOS-only', r.logs.includes('macOS-only'), true);
// spawn throws (e.g. caffeinate missing) -> null + warning, never a crash
{
  const logs = [];
  const out = srv.startKeepAwake({
    enabled: true, platform: 'darwin', pid: 4242,
    spawnFn: () => { throw new Error('spawn caffeinate ENOENT'); },
    logFn: (m) => logs.push(String(m)),
  });
  eq('spawn throws: returns null (no crash)', out, null);
  eq('spawn throws: logs continuing without keep-awake', logs.join('\n').includes('continuing without keep-awake'), true);
}
// child emits an async error (how a missing binary really reports) -> warning
{
  const rec = { calls: [], child: null };
  const logs = [];
  srv.startKeepAwake({ enabled: true, platform: 'darwin', pid: 4242, spawnFn: fakeSpawn(rec), logFn: (m) => logs.push(String(m)) });
  rec.child.emit('error', new Error('spawn caffeinate ENOENT'));
  eq('child error event: logs continuing without keep-awake', logs.join('\n').includes('continuing without keep-awake'), true);
  srv.stopKeepAwake();
}
// shutdown path: stopKeepAwake kills the caffeinate child
{
  const rec = { calls: [], child: null };
  srv.startKeepAwake({ enabled: true, platform: 'darwin', pid: 4242, spawnFn: fakeSpawn(rec), logFn: () => {} });
  srv.stopKeepAwake();
  eq('stopKeepAwake kills the caffeinate child', rec.child.killed, true);
}
console.log(`KAUNIT_PASS=${pass} KAUNIT_FAIL=${fail}`);
process.exit(fail === 0 ? 0 : 1);
KAEOF
KAOUT="$(node "$TMP/keep-awake-unit.js" "$ROOT/server.js")"
echo "$KAOUT" | grep -v '^KAUNIT_' || true
KPASS="$(echo "$KAOUT" | sed -n 's/.*KAUNIT_PASS=\([0-9]*\).*/\1/p')"
KFAIL="$(echo "$KAOUT" | sed -n 's/.*KAUNIT_FAIL=\([0-9]*\).*/\1/p')"
PASS=$((PASS + ${KPASS:-0}))
FAIL=$((FAIL + ${KFAIL:-1}))

# --- 14. keep_awake end-to-end (fake caffeinate on PATH, macOS only) -----------
# On macOS the real server must run the fake `caffeinate` first on PATH with
# `-i -w <server pid>` when keep_awake is true, never when it is off, and the
# child must be gone after the server is terminated. On other platforms the
# unit tests above are the coverage (the server must not spawn there).
if [ "$(uname -s)" = "Darwin" ]; then
  mkdir -p "$TMP/fake-caffeinate-bin" "$TMP/data-ka"
  cat > "$TMP/fake-caffeinate-bin/caffeinate" <<'CFEOF'
#!/bin/sh
echo "$@" > "$FAKE_CAFFEINATE_MARKER"
echo $$ > "$FAKE_CAFFEINATE_PIDFILE"
sleep 60
CFEOF
  chmod +x "$TMP/fake-caffeinate-bin/caffeinate"
  export FAKE_CAFFEINATE_MARKER="$TMP/caffeinate-args.txt"
  export FAKE_CAFFEINATE_PIDFILE="$TMP/caffeinate.pid"

  write_bind_config "$TMP/ka-on.json" 8811 ',
  "bind_mode": "localhost",
  "keep_awake": true'
  # write_bind_config points data_dir at $TMP/data-bind; fine for these runs.
  rm -f "$FAKE_CAFFEINATE_MARKER" "$FAKE_CAFFEINATE_PIDFILE"
  MUSE_BRIDGE_CONFIG="$TMP/ka-on.json" PATH="$TMP/fake-caffeinate-bin:$PATH" node "$ROOT/server.js" > "$TMP/ka-on.log" 2>&1 &
  KAPID=$!
  if wait_health "http://127.0.0.1:8811"; then
    check "keep-awake on: health on 127.0.0.1" "ok" "ok"
  else
    check "keep-awake on: health on 127.0.0.1" "ok" "no-health"; cat "$TMP/ka-on.log"
  fi
  i=0
  while [ ! -f "$FAKE_CAFFEINATE_MARKER" ] && [ "$i" -lt 25 ]; do i=$((i + 1)); sleep 0.2; done
  KARGS="$(cat "$FAKE_CAFFEINATE_MARKER" 2>/dev/null || echo missing)"
  check "keep-awake on: caffeinate spawned as -i -w <server pid>" "-i -w $KAPID" "$KARGS"
  contains "keep-awake on: startup log says the Mac will not idle-sleep" 'keep-awake is on: this Mac will not idle-sleep while the bridge runs' "$(cat "$TMP/ka-on.log")"
  # Never kill pid 0 (that is the whole process group): without a recorded
  # caffeinate pid there is nothing to check beyond reporting the failure.
  CFPID="$(cat "$FAKE_CAFFEINATE_PIDFILE" 2>/dev/null || echo '')"
  kill $KAPID 2>/dev/null
  case "$CFPID" in
    '' | *[!0-9]*)
      check "keep-awake on: caffeinate child killed on server shutdown" "gone" "no caffeinate pid recorded" ;;
    *)
      i=0
      while kill -0 "$CFPID" 2>/dev/null && [ "$i" -lt 25 ]; do i=$((i + 1)); sleep 0.2; done
      if kill -0 "$CFPID" 2>/dev/null; then
        check "keep-awake on: caffeinate child killed on server shutdown" "gone" "alive"
        kill "$CFPID" 2>/dev/null
      else
        check "keep-awake on: caffeinate child killed on server shutdown" "gone" "gone"
      fi ;;
  esac
  sleep 0.3

  write_bind_config "$TMP/ka-off.json" 8812 ',
  "bind_mode": "localhost"'
  rm -f "$FAKE_CAFFEINATE_MARKER" "$FAKE_CAFFEINATE_PIDFILE"
  MUSE_BRIDGE_CONFIG="$TMP/ka-off.json" PATH="$TMP/fake-caffeinate-bin:$PATH" node "$ROOT/server.js" > "$TMP/ka-off.log" 2>&1 &
  KAPID=$!
  if wait_health "http://127.0.0.1:8812"; then
    check "keep-awake off (default): health on 127.0.0.1" "ok" "ok"
  else
    check "keep-awake off (default): health on 127.0.0.1" "ok" "no-health"; cat "$TMP/ka-off.log"
  fi
  sleep 0.5
  [ -f "$FAKE_CAFFEINATE_MARKER" ] && check "keep-awake off (default): caffeinate never spawned" "absent" "spawned" || check "keep-awake off (default): caffeinate never spawned" "absent" "absent"
  kill $KAPID 2>/dev/null; sleep 0.3
  unset FAKE_CAFFEINATE_MARKER FAKE_CAFFEINATE_PIDFILE
else
  echo "SKIP: not macOS - keep-awake e2e skipped (unit tests above cover the gating)"
fi

# --- 15. muse-bridge CLI (fake launchctl + fake curl on PATH) -----------------
# The real launchd agent is never touched here: a fake `launchctl` keeps its
# loaded-state in a temp file and logs every call, a fake `curl` answers (or
# refuses) the health check, and HOME points at a temp dir with a dummy plist.
CLI="$ROOT/scripts/muse-bridge"
mkdir -p "$TMP/fake-cli-bin" "$TMP/cli-home/Library/LaunchAgents"
printf 'dummy plist (tests only)\n' > "$TMP/cli-home/Library/LaunchAgents/com.muse.bridge.plist"
cat > "$TMP/fake-cli-bin/launchctl" <<'LCEOF'
#!/bin/sh
echo "$@" >> "$FAKE_LAUNCHCTL_LOG"
case "$1" in
  list)
    if [ -f "$FAKE_LAUNCHCTL_STATE" ]; then
      printf '{\n\t"Label" = "com.muse.bridge";\n\t"PID" = 4242;\n};\n'
      exit 0
    fi
    exit 1 ;;
  load) touch "$FAKE_LAUNCHCTL_STATE"; exit 0 ;;
  unload) rm -f "$FAKE_LAUNCHCTL_STATE"; exit 0 ;;
  *) exit 2 ;;
esac
LCEOF
cat > "$TMP/fake-cli-bin/curl" <<'CUEOF'
#!/bin/sh
if [ "${FAKE_CURL_OK:-1}" = "1" ]; then
  printf '{"ok":true,"version":"0.1.0","mode":"unrestricted"}'
  exit 0
fi
exit 7
CUEOF
chmod +x "$TMP/fake-cli-bin/launchctl" "$TMP/fake-cli-bin/curl"
export FAKE_LAUNCHCTL_STATE="$TMP/cli-state"
export FAKE_LAUNCHCTL_LOG="$TMP/cli-launchctl.log"
run_cli() { # run_cli <args...> -> sets CLI_OUT, CLI_CODE; FAKE_CURL_OK may be preset
  CLI_OUT="$(PATH="$TMP/fake-cli-bin:$PATH" HOME="$TMP/cli-home" FAKE_CURL_OK="${FAKE_CURL_OK:-1}" sh "$CLI" "$@" 2>&1)"
  CLI_CODE=$?
}

[ -x "$CLI" ] && check "cli: scripts/muse-bridge is executable" "yes" "yes" || check "cli: scripts/muse-bridge is executable" "yes" "no"

rm -f "$FAKE_LAUNCHCTL_STATE" "$FAKE_LAUNCHCTL_LOG"
FAKE_CURL_OK=0 run_cli status
check "cli status (stopped): exit 1" "1" "$CLI_CODE"
contains "cli status (stopped): says not loaded" 'not loaded' "$CLI_OUT"

FAKE_CURL_OK=1 run_cli start
check "cli start: exit 0" "0" "$CLI_CODE"
contains "cli start: launchctl load of the agent plist" "load $TMP/cli-home/Library/LaunchAgents/com.muse.bridge.plist" "$(cat "$FAKE_LAUNCHCTL_LOG")"
contains "cli start: reports healthy" 'health OK' "$CLI_OUT"
[ -f "$FAKE_LAUNCHCTL_STATE" ] && check "cli start: agent loaded (fake state)" "loaded" "loaded" || check "cli start: agent loaded (fake state)" "loaded" "not loaded"

FAKE_CURL_OK=1 run_cli start
check "cli start (already loaded): exit 0" "0" "$CLI_CODE"
contains "cli start (already loaded): says already" 'already' "$CLI_OUT"

FAKE_CURL_OK=1 run_cli status
check "cli status (running): exit 0" "0" "$CLI_CODE"
contains "cli status (running): shows pid from launchctl" 'pid 4242' "$CLI_OUT"
contains "cli status (running): health OK" 'health OK' "$CLI_OUT"

FAKE_CURL_OK=0 run_cli status
check "cli status (loaded, health failing): exit 1" "1" "$CLI_CODE"
contains "cli status (loaded, health failing): says health check failed" 'health check failed' "$CLI_OUT"

: > "$FAKE_LAUNCHCTL_LOG"
FAKE_CURL_OK=1 run_cli restart
check "cli restart: exit 0" "0" "$CLI_CODE"
CLI_LOG="$(cat "$FAKE_LAUNCHCTL_LOG")"
contains "cli restart: unloads then loads" 'unload' "$CLI_LOG"
case "$CLI_LOG" in
  *unload*load*) check "cli restart: unload before load" "ordered" "ordered" ;;
  *) check "cli restart: unload before load" "ordered" "wrong order: $CLI_LOG" ;;
esac

run_cli stop
check "cli stop: exit 0" "0" "$CLI_CODE"
[ -f "$FAKE_LAUNCHCTL_STATE" ] && check "cli stop: agent unloaded (fake state)" "gone" "still loaded" || check "cli stop: agent unloaded (fake state)" "gone" "gone"

run_cli stop
check "cli stop (already stopped): exit 0" "0" "$CLI_CODE"
contains "cli stop (already stopped): says already stopped" 'already stopped' "$CLI_OUT"

FAKE_CURL_OK=1 run_cli restart
check "cli restart (was stopped): exit 0 and loads" "0" "$CLI_CODE"
[ -f "$FAKE_LAUNCHCTL_STATE" ] && check "cli restart (was stopped): agent loaded" "loaded" "loaded" || check "cli restart (was stopped): agent loaded" "loaded" "not loaded"

run_cli bogus-command
[ "$CLI_CODE" -ne 0 ] && check "cli unknown command: non-zero exit" "nonzero" "nonzero" || check "cli unknown command: non-zero exit" "nonzero" "zero"
contains "cli unknown command: prints usage" 'usage:' "$CLI_OUT"

run_cli help
check "cli help: exit 0" "0" "$CLI_CODE"
contains "cli help: lists start/stop/restart/status" 'restart' "$CLI_OUT"

# foreground: execs `node <server.js> --foreground` in this terminal (fake
# node records its argv); refuses while the launchd agent is loaded so the
# two instances never fight over the port.
cat > "$TMP/fake-cli-bin/node" <<'NDEOF'
#!/bin/sh
echo "$@" >> "$FAKE_NODE_LOG"
echo "fake-node running: $@"
exit 0
NDEOF
chmod +x "$TMP/fake-cli-bin/node"
export FAKE_NODE_LOG="$TMP/cli-node.log"

rm -f "$FAKE_LAUNCHCTL_STATE" "$FAKE_NODE_LOG"
run_cli foreground
check "cli foreground: exit 0 (fake node ran)" "0" "$CLI_CODE"
contains "cli foreground: says logs go to this terminal" 'foreground' "$CLI_OUT"
contains "cli foreground: node invoked with server.js --foreground" "server.js --foreground" "$(cat "$FAKE_NODE_LOG" 2>/dev/null || echo missing)"

touch "$FAKE_LAUNCHCTL_STATE"
rm -f "$FAKE_NODE_LOG"
run_cli foreground
check "cli foreground (agent loaded): exit 1" "1" "$CLI_CODE"
contains "cli foreground (agent loaded): says stop the background bridge first" 'muse-bridge stop' "$CLI_OUT"
[ -f "$FAKE_NODE_LOG" ] && check "cli foreground (agent loaded): node never started" "absent" "started" || check "cli foreground (agent loaded): node never started" "absent" "absent"
rm -f "$FAKE_LAUNCHCTL_STATE"

run_cli foreground extra-arg
check "cli foreground with extra arg: exit 2" "2" "$CLI_CODE"
contains "cli foreground with extra arg: prints usage" 'usage:' "$CLI_OUT"
unset FAKE_NODE_LOG

mv "$TMP/cli-home/Library/LaunchAgents/com.muse.bridge.plist" "$TMP/plist.bak"
run_cli start
check "cli start (no plist installed): exit 1" "1" "$CLI_CODE"
contains "cli start (no plist installed): points at install.sh" 'install.sh' "$CLI_OUT"
mv "$TMP/plist.bak" "$TMP/cli-home/Library/LaunchAgents/com.muse.bridge.plist"
unset FAKE_LAUNCHCTL_STATE FAKE_LAUNCHCTL_LOG

# --- 16. --foreground (server flag: attached to the terminal, logs to stdout) -
# parseArgs unit checks via the server.js exports.
cat > "$TMP/foreground-unit.js" <<'FGEOF'
const { parseArgs } = require(process.argv[2]);
let pass = 0, fail = 0;
function eq(name, got, expected) {
  if (got === expected) { pass += 1; console.log(`PASS: foreground unit: ${name}`); }
  else { fail += 1; console.log(`FAIL: foreground unit: ${name} (expected [${expected}], got [${got}])`); }
}
eq('no args: foreground off (launchd default)', parseArgs([]).foreground, false);
eq('--foreground: foreground on', parseArgs(['--foreground']).foreground, true);
eq('--help: help on', parseArgs(['--help']).help, true);
eq('no args: help off', parseArgs([]).help, false);
let threw = false;
try { parseArgs(['--bogus']); } catch { threw = true; }
eq('unknown flag throws', threw, true);
console.log(`FGUNIT_PASS=${pass} FGUNIT_FAIL=${fail}`);
FGEOF
FGOUT="$(node "$TMP/foreground-unit.js" "$ROOT/server.js")"
echo "$FGOUT" | grep -v '^FGUNIT_' || true
FPASS="$(echo "$FGOUT" | sed -n 's/.*FGUNIT_PASS=\([0-9]*\).*/\1/p')"
FFAIL="$(echo "$FGOUT" | sed -n 's/.*FGUNIT_FAIL=\([0-9]*\).*/\1/p')"
PASS=$((PASS + ${FPASS:-0}))
FAIL=$((FAIL + ${FFAIL:-1}))

# --help / unknown flag: usage out, no server started.
node "$ROOT/server.js" --help > "$TMP/fg-help.log" 2>&1
check "server --help: exit 0" "0" "$?"
contains "server --help: documents --foreground" '--foreground' "$(cat "$TMP/fg-help.log")"
node "$ROOT/server.js" --bogus > "$TMP/fg-bogus.log" 2>&1
check "server --bogus: exit 2" "2" "$?"
contains "server --bogus: prints usage" 'Usage:' "$(cat "$TMP/fg-bogus.log")"

# End to end: --foreground serves health, stays attached (still running
# until signalled), startup logs land on STDOUT (stderr kept separate),
# and Ctrl+C (SIGINT) stops it.
write_bind_config "$TMP/fg.json" 8813 ',
  "bind_mode": "localhost"'
MUSE_BRIDGE_CONFIG="$TMP/fg.json" node "$ROOT/server.js" --foreground > "$TMP/fg.out.log" 2> "$TMP/fg.err.log" &
FGPID=$!
if wait_health "http://127.0.0.1:8813"; then
  check "foreground: health on 127.0.0.1" "ok" "ok"
else
  check "foreground: health on 127.0.0.1" "ok" "no-health"; cat "$TMP/fg.out.log" "$TMP/fg.err.log"
fi
if kill -0 $FGPID 2>/dev/null; then
  check "foreground: process stays in the foreground (still running)" "running" "running"
else
  check "foreground: process stays in the foreground (still running)" "running" "exited"
fi
contains "foreground: stdout says foreground mode, logs to stdout" 'foreground mode' "$(cat "$TMP/fg.out.log")"
contains "foreground: stdout has the Listening on line" 'Listening on' "$(cat "$TMP/fg.out.log")"
case "$(cat "$TMP/fg.err.log")" in
  *'Listening on'*) check "foreground: Listening on line is on stdout, not stderr" "stdout-only" "on-stderr" ;;
  *) check "foreground: Listening on line is on stdout, not stderr" "stdout-only" "stdout-only" ;;
esac
kill -INT $FGPID 2>/dev/null
i=0
while kill -0 $FGPID 2>/dev/null && [ "$i" -lt 25 ]; do i=$((i + 1)); sleep 0.2; done
if kill -0 $FGPID 2>/dev/null; then
  check "foreground: SIGINT (Ctrl+C) stops it" "stopped" "still running"
  kill $FGPID 2>/dev/null
else
  check "foreground: SIGINT (Ctrl+C) stops it" "stopped" "stopped"
fi
sleep 0.3

# --- 17. allowed_workdirs (unit, via server.js exports) -----------------------
# Pure resolver contract: unset/empty = no restriction (back-compat); when set,
# the workdir must be equal to or inside an allowed dir after `~` expansion,
# `..` normalization, and symlink resolution (realpathFn injected here).
cat > "$TMP/workdir-unit.js" <<'WDEOF'
'use strict';
const srv = require(process.argv[2]);
let pass = 0; let fail = 0;
function eq(name, got, expected) {
  if (got === expected) { pass += 1; console.log(`PASS: workdir unit: ${name}`); }
  else { fail += 1; console.log(`FAIL: workdir unit: ${name} (expected [${expected}], got [${got}])`); }
}
function throws(name, fn, needle) {
  try { fn(); fail += 1; console.log(`FAIL: workdir unit: ${name} (did not throw)`); }
  catch (e) {
    if (e.message.includes(needle)) { pass += 1; console.log(`PASS: workdir unit: ${name}`); }
    else { fail += 1; console.log(`FAIL: workdir unit: ${name} (threw [${e.message}], missing [${needle}])`); }
  }
}
if (typeof srv.isWorkdirAllowed !== 'function' || typeof srv.normalizeAllowedWorkdirs !== 'function'
  || typeof srv.resolveWorkdirPath !== 'function') {
  eq('server.js exports workdir helpers', 'missing', 'functions');
  console.log(`WDUNIT_PASS=${pass} WDUNIT_FAIL=${fail}`);
  process.exit(1);
}
eq('server.js exports workdir helpers', 'functions', 'functions');
const { isWorkdirAllowed, normalizeAllowedWorkdirs, resolveWorkdirPath } = srv;
const OPTS = { homeDir: '/Users/test', cwd: '/srv', realpathFn: (p) => p };
// unset / empty: no restriction (current behaviour preserved)
eq('unset (undefined) allows anywhere', isWorkdirAllowed('/etc', undefined, OPTS), true);
eq('unset (null) allows anywhere', isWorkdirAllowed('/etc', null, OPTS), true);
eq('empty list allows anywhere', isWorkdirAllowed('/etc', [], OPTS), true);
eq('normalize unset -> []', JSON.stringify(normalizeAllowedWorkdirs(null, OPTS)), '[]');
// allowed: equal, inside, trailing slash, second entry
eq('equal to allowed dir', isWorkdirAllowed('/srv/projects', ['/srv/projects'], OPTS), true);
eq('inside allowed dir', isWorkdirAllowed('/srv/projects/app/src', ['/srv/projects'], OPTS), true);
eq('allowed dir with trailing slash', isWorkdirAllowed('/srv/projects/app', ['/srv/projects/'], OPTS), true);
eq('inside second allowed dir', isWorkdirAllowed('/other/app', ['/srv/projects', '/other'], OPTS), true);
// rejected: outside, sibling prefix, parent
eq('outside allowed dir', isWorkdirAllowed('/etc', ['/srv/projects'], OPTS), false);
eq('sibling prefix is not inside (ProjectsEvil)', isWorkdirAllowed('/srv/projectsEvil', ['/srv/projects'], OPTS), false);
eq('parent of allowed dir rejected', isWorkdirAllowed('/srv', ['/srv/projects'], OPTS), false);
// `..` escapes are normalized away before the check
eq('.. escape rejected', isWorkdirAllowed('/srv/projects/../etc', ['/srv/projects'], OPTS), false);
eq('.. that stays inside allowed', isWorkdirAllowed('/srv/projects/app/../other', ['/srv/projects'], OPTS), true);
// `~` expansion on both the request and the allowed entries
eq('~/ request inside allowed', isWorkdirAllowed('~/Projects/app', ['/Users/test/Projects'], OPTS), true);
eq('~/ allowed entry', isWorkdirAllowed('/Users/test/Projects/app', ['~/Projects'], OPTS), true);
eq('bare ~ resolves to home', resolveWorkdirPath('~', OPTS), '/Users/test');
eq('~/ resolves under home', resolveWorkdirPath('~/Projects', OPTS), '/Users/test/Projects');
// symlink resolution: a link inside the allowed tree pointing out is rejected
const LINKS = { '/srv/projects/link': '/etc/secret', '/srv/projects/real': '/srv/projects/real' };
const LINKOPTS = { ...OPTS, realpathFn: (p) => LINKS[p] || p };
eq('symlink escaping allowed dir rejected', isWorkdirAllowed('/srv/projects/link', ['/srv/projects'], LINKOPTS), false);
eq('non-link path still allowed with realpath', isWorkdirAllowed('/srv/projects/real', ['/srv/projects'], LINKOPTS), true);
// root as an allowed dir allows everything under it
eq('root allowed dir', isWorkdirAllowed('/anywhere/deep', ['/'], OPTS), true);
// invalid config fails loudly (never silently disables the restriction)
throws('non-array allowed_workdirs throws', () => normalizeAllowedWorkdirs('/srv/projects', OPTS), 'allowed_workdirs must be an array');
throws('non-string entry throws', () => normalizeAllowedWorkdirs([123], OPTS), 'allowed_workdirs');
throws('empty-string entry throws', () => normalizeAllowedWorkdirs([''], OPTS), 'allowed_workdirs');
throws('relative entry throws', () => normalizeAllowedWorkdirs(['relative/dir'], OPTS), 'absolute');
console.log(`WDUNIT_PASS=${pass} WDUNIT_FAIL=${fail}`);
process.exit(fail === 0 ? 0 : 1);
WDEOF
WDOUT="$(node "$TMP/workdir-unit.js" "$ROOT/server.js")"
echo "$WDOUT" | grep -v '^WDUNIT_' || true
WPASS="$(echo "$WDOUT" | sed -n 's/.*WDUNIT_PASS=\([0-9]*\).*/\1/p')"
WFAIL="$(echo "$WDOUT" | sed -n 's/.*WDUNIT_FAIL=\([0-9]*\).*/\1/p')"
PASS=$((PASS + ${WPASS:-0}))
FAIL=$((FAIL + ${WFAIL:-1}))

# --- 18. allowed_workdirs end-to-end (jobs + sessions) ------------------------
# The main test server above runs WITHOUT allowed_workdirs: a job outside any
# would-be list must still be accepted (backward compatibility).
CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "$AUTH" -H 'Content-Type: application/json' -d "{\"prompt\": \"tiny hello\", \"workdir\": \"$TMP\"}" "$BASE/jobs")"
check "allowlist unset: job outside any list accepted (202)" "202" "$CODE"

mkdir -p "$TMP/allowed/sub" "$TMP/outside" "$TMP/allowed-evil" "$TMP/fakehome/Projects/app" "$TMP/data-allow"
ln -s "$TMP/outside" "$TMP/allowed/link-out" 2>/dev/null || true
cat > "$TMP/allow.json" <<EOF
{
  "port": 8814,
  "bind_mode": "localhost",
  "data_dir": "$TMP/data-allow",
  "default_workdir": "$TMP/allowed/sub",
  "allowed_workdirs": ["$TMP/allowed", "$TMP/fakehome/Projects"],
  "muse_bin": "$ROOT/test/fake-muse.sh",
  "mode": "unrestricted",
  "max_model_steps": 0
}
EOF
MUSE_BRIDGE_CONFIG="$TMP/allow.json" HOME="$TMP/fakehome" node "$ROOT/server.js" > "$TMP/allow.log" 2>&1 &
APID=$!
ABASE="http://127.0.0.1:8814"
if wait_health "$ABASE"; then
  check "allowlist server: health on 127.0.0.1" "ok" "ok"
else
  check "allowlist server: health on 127.0.0.1" "ok" "no-health"; cat "$TMP/allow.log"
fi
contains "allowlist server: startup log names allowed_workdirs" 'allowed_workdirs' "$(cat "$TMP/allow.log")"

acode() { # acode <path> <json> -> http status against the allowlist server
  curl -s -o /dev/null -w '%{http_code}' -X POST -H "$AUTH" -H 'Content-Type: application/json' -d "$2" "$ABASE$1"
}
ajob() { # ajob <workdir> -> http status for POST /jobs with that workdir
  acode /jobs '{"prompt":"tiny hello","workdir":"'"$1"'"}'
}
check "allowlist job inside -> 202" "202" "$(ajob "$TMP/allowed/sub")"
check "allowlist job at allowed root -> 202" "202" "$(ajob "$TMP/allowed")"
check "allowlist job default workdir (inside) -> 202" "202" "$(acode /jobs '{"prompt":"tiny hello"}')"
check "allowlist job ~/ expansion -> 202" "202" "$(ajob '~/Projects/app')"
check "allowlist job outside -> 403" "403" "$(ajob "$TMP/outside")"
check "allowlist job sibling prefix -> 403" "403" "$(ajob "$TMP/allowed-evil")"
check "allowlist job .. escape -> 403" "403" "$(ajob "$TMP/allowed/sub/../../outside")"
if [ -L "$TMP/allowed/link-out" ]; then
  check "allowlist job symlink escape -> 403" "403" "$(ajob "$TMP/allowed/link-out")"
fi
ABODY="$(curl -s -X POST -H "$AUTH" -H 'Content-Type: application/json' -d "{\"prompt\":\"x\",\"workdir\":\"$TMP/outside\"}" "$ABASE/jobs")"
contains "allowlist rejection names allowed_workdirs" 'allowed_workdirs' "$ABODY"

asess() { # asess <workdir> -> http status for POST /sessions with that workdir
  acode /sessions '{"prompt":"x","workdir":"'"$1"'"}'
}
check "allowlist session outside -> 403" "403" "$(asess "$TMP/outside")"
check "allowlist session .. escape -> 403" "403" "$(asess "$TMP/allowed/sub/../../outside")"
if command -v tmux >/dev/null 2>&1; then
  ASESS="$(curl -s -w '\n%{http_code}' -X POST -H "$AUTH" -H 'Content-Type: application/json' -d "{\"prompt\":\"interactive hello allow\",\"workdir\":\"$TMP/allowed/sub\"}" "$ABASE/sessions")"
  check "allowlist session inside -> 201" "201" "$(echo "$ASESS" | tail -1)"
  ASESS_ID="$(echo "$ASESS" | sed -n 's/.*"session_id": *"\([^"]*\)".*/\1/p')"
  CREATED_TMUX="$CREATED_TMUX muse-$ASESS_ID"
  [ -n "$ASESS_ID" ] && curl -s -X POST -H "$AUTH" "$ABASE/sessions/$ASESS_ID/kill" >/dev/null
fi
kill $APID 2>/dev/null; sleep 0.3

# default_workdir outside the list: a request that omits workdir is rejected.
cat > "$TMP/allow-bad-default.json" <<EOF
{
  "port": 8815,
  "bind_mode": "localhost",
  "data_dir": "$TMP/data-allow",
  "default_workdir": "$TMP/outside",
  "allowed_workdirs": ["$TMP/allowed"],
  "muse_bin": "$ROOT/test/fake-muse.sh",
  "mode": "unrestricted",
  "max_model_steps": 0
}
EOF
MUSE_BRIDGE_CONFIG="$TMP/allow-bad-default.json" node "$ROOT/server.js" > "$TMP/allow-bad-default.log" 2>&1 &
APID=$!
if wait_health "http://127.0.0.1:8815"; then
  check "allowlist bad-default server: health" "ok" "ok"
else
  check "allowlist bad-default server: health" "ok" "no-health"; cat "$TMP/allow-bad-default.log"
fi
CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "$AUTH" -H 'Content-Type: application/json' -d '{"prompt":"x"}' "http://127.0.0.1:8815/jobs")"
check "allowlist job with default outside -> 403" "403" "$CODE"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "$AUTH" -H 'Content-Type: application/json' -d '{"prompt":"x"}' "http://127.0.0.1:8815/sessions")"
check "allowlist session with default outside -> 403" "403" "$CODE"
kill $APID 2>/dev/null; sleep 0.3

# --- summary ------------------------------------------------------------------
echo
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
