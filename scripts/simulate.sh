#!/bin/sh
# Drives a running Lintel with fake Claude Code hook events (for UI development).
# Usage: scripts/simulate.sh <event> '<json>'   or   scripts/simulate.sh debug <agents|music|collapse|snapshot|select-ID>
H="$HOME/.lintel/token-header"
if [ "$1" = "debug" ]; then
  curl -s -m 5 -X POST -H @"$H" --data-binary '{}' "http://127.0.0.1:47821/debug/$2"
else
  curl -s -m "${MAX:-3}" -X POST -H @"$H" -H "X-Lintel-PPID: $$" --data-binary "$2" "http://127.0.0.1:47821/claude/$1"
fi
