#!/bin/bash
# Drives a running Lintel with fake Claude Code hook events (for UI development).
# Usage: scripts/simulate.sh <event> '<json>'   or   scripts/simulate.sh debug <agents|music|collapse|snapshot|select-ID>
# The token goes through a file descriptor, never the command line (so it doesn't show up in ps).
TOKEN_HEADER() { printf 'X-Lintel-Token: %s\n' "$(cat "$HOME/.lintel/token")"; }
if [ "$1" = "debug" ]; then
  curl -s -m 5 -X POST -H @<(TOKEN_HEADER) --data-binary '{}' "http://127.0.0.1:47821/debug/$2"
else
  curl -s -m "${MAX:-3}" -X POST -H @<(TOKEN_HEADER) -H "X-Lintel-PPID: $$" --data-binary "$2" "http://127.0.0.1:47821/claude/$1"
fi
