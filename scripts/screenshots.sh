#!/bin/bash
# Regenerates the README screenshots in docs/images from Lintel's demo mode (made-up sessions, music
# and usage — nothing from your machine). Needs a running Lintel; uses the built-in display for notch shots.
set -e
cd "$(dirname "$0")/.."
S=scripts/simulate.sh
OUT=docs/images
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; $S debug display-follow >/dev/null; $S debug theme-system >/dev/null; $S debug usage-cost >/dev/null; $S debug usage-hover-off >/dev/null' EXIT

d() { $S debug "$@" >/dev/null; }

# Rect "(x, y, w, h)" from `debug state` → "x y w h"
rect() { $S debug state | python3 -c "import json,sys,re;print(' '.join(re.findall(r'-?[0-9.]+', json.load(sys.stdin)['$1'])))"; }

# shot <name> <dark|light> <setup commands…>: open the card the setup describes, snapshot, crop, compose.
shot() {
  local name=$1 style=$2; shift 2
  for attempt in 1 2 3 4 5; do
    for c in "$@"; do d $c; done
    sleep 1.2
    if $S debug state | grep -q '"expanded" : "Optional'; then break; fi
  done
  d snapshot-clear; sleep 0.8
  read -r cx cy cw ch <<<"$(rect cardRect)"
  read -r ax ay aw ah <<<"$(rect agentRect)"
  read -r mx my mw mh <<<"$(rect musicRect)"
  python3 - "$cx" "$cy" "$cw" "$ch" "$ax" "$aw" "$mx" "$mw" > "$TMP/crop" <<'PY'
import sys
cx,cy,cw,ch,ax,aw,mx,mw=map(float,sys.argv[1:])
left=min(cx, ax if aw>0 else cx, mx if mw>0 else cx)-56
right=max(cx+cw, ax+aw if aw>0 else 0, mx+mw if mw>0 else 0)+56
print(f"{left} 0 {right-left} {cy+ch+56}")
PY
  read -r x y w h < "$TMP/crop"
  cp "$TMPDIR/lintel-snapshot.png" "$TMP/$name.png"
  swift scripts/compose-shot.swift "$TMP/$name.png" "$OUT/$name.png" $x $y $w $h "$style"
  echo "  $OUT/$name.png"
  d collapse; sleep 0.4
}

demo() { d demo; sleep 0.6; }

echo "External display (capsules)…"
d display-main
for theme in light dark; do
  d theme-$theme
  [ $theme = light ] && { demo; shot agents-light light agents; demo; shot music-light light music; }
  demo; shot permission-$theme $theme demo-permission
  mode=$([ $theme = light ] && echo usage-tokens || echo usage-cost)
  demo; shot usage-$theme $theme usage usage-range-30d $mode usage-hover-6
done
d theme-light
demo; shot question-light light demo-question
demo; shot detail-light light agents select-demo-1

echo "Built-in display (notch)…"
d display-builtIn
d theme-dark
demo; shot notch-agents dark agents
demo; shot notch-music dark music
