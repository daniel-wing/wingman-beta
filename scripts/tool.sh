#!/usr/bin/env bash
# Runs one of Wingman's diagnostic tools through the installed app, so it gets
# Wingman's permissions (Accessibility, microphone, calendar…), and shows its
# output as it comes. `open --stdout /dev/stdout` fails with -10810 on macOS 26,
# even in Terminal, so the output goes through a temporary file. Ctrl-C stops
# the tool too.
#
#   scripts/tool.sh axdump chrome --inspector --seconds 60
#   scripts/tool.sh whosmic --watch 30
#   APP=~/Applications/Wingman.app scripts/tool.sh calendarcheck
set -euo pipefail
APP="${APP:-/Applications/Wingman.app}"
[[ $# -gt 0 ]] || { sed -n '2,10p' "$0"; exit 1; }

DIR="$(mktemp -d -t wingman-tool)"
TOOL="$APP/Contents/MacOS/Wingman $*"
TAIL=""
cleanup() {
  [[ -n "$TAIL" ]] && kill "$TAIL" 2>/dev/null || true
  rm -rf "$DIR"
}
trap cleanup EXIT
trap 'pkill -INT -f -x "$TOOL" 2>/dev/null || true; exit 130' INT TERM

# -g: don't take focus (a browser being measured stays in front); -n: a new
# instance, never the running app.
open -g -n -W --stdout "$DIR/out" --stderr "$DIR/err" "$APP" --args "$@" &
OPEN=$!
while [[ ! -e "$DIR/out" ]] && kill -0 "$OPEN" 2>/dev/null; do sleep 0.1; done
[[ -e "$DIR/out" ]] && { tail -n +1 -f "$DIR/out" & TAIL=$!; }
STATUS=0
wait "$OPEN" || STATUS=$?
sleep 0.3
[[ -s "$DIR/err" ]] && cat "$DIR/err" >&2
exit "$STATUS"
