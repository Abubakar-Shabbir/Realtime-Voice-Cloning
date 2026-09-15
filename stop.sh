#!/usr/bin/env bash
# Stops RVC GUI + router and removes the virtual microphone.
set -uo pipefail
ROOT="$HOME/rvc-realtime"
LOGS="$ROOT/logs"

for name in router gui; do
  f="$LOGS/$name.pid"
  if [ -f "$f" ]; then
    pid=$(cat "$f")
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null
      for _ in $(seq 10); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
      kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
      echo "stopped $name (pid $pid)"
    fi
    rm -f "$f"
  fi
done

"$ROOT/audio/teardown_virtual_mic.sh"
