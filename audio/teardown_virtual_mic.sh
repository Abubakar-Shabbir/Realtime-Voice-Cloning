#!/usr/bin/env bash
# Removes rvc_mic and rvc_out. Safe to run repeatedly.
set -uo pipefail
STATE="$HOME/rvc-realtime/audio/.modules"

if [ -f "$STATE" ]; then
  tac "$STATE" | while read -r id; do
    [ -n "$id" ] && pactl unload-module "$id" 2>/dev/null
  done
  rm -f "$STATE"
fi

# Fallback: anything still loaded under our names (remap source first: higher id).
pactl list short modules \
  | awk '/source_name=rvc_mic|sink_name=rvc_out/ {print $1}' \
  | sort -rn | while read -r id; do pactl unload-module "$id"; done

if pactl list short sources | awk '{print $2}' | grep -qE '^rvc_(mic|out\.monitor)$'; then
  echo "WARNING: RVC devices still present"; exit 1
fi
echo "RVC virtual devices removed"
echo "default sink:   $(pactl get-default-sink)"
echo "default source: $(pactl get-default-source)"
