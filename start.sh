#!/usr/bin/env bash
# Starts: virtual mic -> RVC realtime GUI -> keeps RVC output routed into the virtual mic.
set -euo pipefail
ROOT="$HOME/rvc-realtime"
LOGS="$ROOT/logs"
mkdir -p "$LOGS"

if [ -f "$LOGS/gui.pid" ] && kill -0 "$(cat "$LOGS/gui.pid")" 2>/dev/null; then
  echo "RVC is already running (pid $(cat "$LOGS/gui.pid")). Run ./stop.sh first."; exit 1
fi

echo "== 1/3 virtual microphone"
"$ROOT/audio/setup_virtual_mic.sh"

echo "== 2/3 RVC realtime GUI"
cd "$ROOT/rvc"
nohup "$ROOT/venv/bin/python" realtime_gui.py > "$LOGS/gui.log" 2>&1 &
GUI_PID=$!
echo "$GUI_PID" > "$LOGS/gui.pid"

echo "== 3/3 output router"
# Every new RVC playback stream (each Start click) is moved into rvc_out, never the speakers.
(
  while kill -0 "$GUI_PID" 2>/dev/null; do
    RVC_SINK=$(pactl list short sinks | awk '$2 == "rvc_out" {print $1}')
    [ -n "$RVC_SINK" ] || { sleep 1; continue; }
    pactl -f json list sink-inputs 2>/dev/null | python3 -c '
import sys, json
pid, rvc_sink = sys.argv[1], int(sys.argv[2])
for s in json.load(sys.stdin):
    p = s.get("properties", {})
    if p.get("application.process.id") == pid and s.get("sink") != rvc_sink:
        print(s["index"])
' "$GUI_PID" "$RVC_SINK" | while read -r id; do
      pactl move-sink-input "$id" rvc_out 2>/dev/null && echo "$(date +%T) routed RVC stream $id -> rvc_out" >> "$LOGS/router.log"
    done
    sleep 1
  done
) &
echo $! > "$LOGS/router.pid"

cat <<EOF

RVC window is opening (first load takes ~20-40 s on this CPU).
  1. Check the model path and devices (input/output: pipewire), then click the Start button.
  2. In Chrome / Google Meet choose microphone: "RVC Virtual Microphone".
  3. Use headphones if you want to monitor; RVC itself never plays to the speakers.

Logs: $LOGS/gui.log   Stop everything: $ROOT/stop.sh
EOF
