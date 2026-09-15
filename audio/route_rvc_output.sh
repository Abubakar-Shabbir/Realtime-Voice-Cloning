#!/usr/bin/env bash
# Moves the RVC GUI's playback stream (python process) into rvc_out.
# Usage: route_rvc_output.sh [target_sink]   (default rvc_out; pass the speaker sink to monitor)
set -euo pipefail
TARGET="${1:-rvc_out}"
ids=$(pactl -f json list sink-inputs | python3 -c '
import sys, json
for s in json.load(sys.stdin):
    p = s.get("properties", {})
    if p.get("application.process.binary", "").startswith("python"):
        print(s["index"])
')
if [ -z "$ids" ]; then
  echo "No RVC playback stream found (click Start in the RVC window first)"; exit 1
fi
for id in $ids; do
  pactl move-sink-input "$id" "$TARGET"
  echo "moved sink-input $id -> $TARGET"
done
