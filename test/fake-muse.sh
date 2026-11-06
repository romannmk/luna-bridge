#!/bin/sh
# ==========================================================================
# TEST FIXTURE ONLY — not part of the shipped luna-bridge server.
# This script pretends to be the `muse` CLI so the bridge can be tested
# end-to-end on a machine without Muse Code installed.
# Behaviour:
#   - echoes its argv (so job output shows what the bridge invoked),
#   - prints the --prompt-file contents if given,
#   - exits 1 if any argument contains "fail",
#   - sleeps ~30s (printing progress) if any argument contains "slow",
#   - otherwise prints a few lines with small delays and exits 0.
# ==========================================================================
echo "fake-muse argv: $*"
PROMPT_FILE=""
PREV=""
for arg in "$@"; do
  if [ "$PREV" = "--prompt-file" ]; then
    PROMPT_FILE="$arg"
  fi
  PREV="$arg"
done
if [ -n "$PROMPT_FILE" ] && [ -f "$PROMPT_FILE" ]; then
  echo "fake-muse prompt file ($PROMPT_FILE):"
  cat "$PROMPT_FILE"
  PROMPT_TEXT="$(cat "$PROMPT_FILE")"
fi
# Triggers can come from argv OR from the prompt file contents
# (the bridge passes the prompt via --prompt-file by default).
TRIGGER_TEXT="$* ${PROMPT_TEXT:-}"
case "$TRIGGER_TEXT" in
  *fail*)
    echo "fake-muse: simulated failure" >&2
    exit 1
    ;;
esac
case "$TRIGGER_TEXT" in
  *interactive*)
    # Pretends to be the interactive `muse` TUI inside a tmux pane: prints a
    # prompt marker (so the pane/idle checks have something to find), echoes
    # anything typed into the pane back as "heard" lines (tmux send-keys
    # delivers pane input to our stdin), then idles until killed.
    echo "fake-muse TUI ready"
    echo "fake-muse argv: $*"
    echo "waiting for input"
    echo "❯"
    while IFS= read -r line; do
      echo "fake-muse heard: $line"
    done
    exit 0
    ;;
esac
case "$TRIGGER_TEXT" in
  *slow*)
    i=1
    while [ "$i" -le 30 ]; do
      echo "fake-muse: working... $i/30"
      sleep 1
      i=$((i + 1))
    done
    echo "fake-muse: slow job finished"
    exit 0
    ;;
esac
echo "fake-muse: step 1/3 reading workspace"
sleep 0.2
echo "fake-muse: step 2/3 editing files"
sleep 0.2
echo "fake-muse: step 3/3 done"
exit 0
