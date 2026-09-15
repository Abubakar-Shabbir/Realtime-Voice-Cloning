#!/usr/bin/env bash
# Live progress display for scripts/run_kashif_pipeline.sh.
# Run in a separate terminal, on the same machine, while the pipeline is running:
#   bash scripts/monitor_kashif_training.sh
# Prints a line every time an epoch finishes: percentage done, elapsed time,
# average epoch time so far, and an ETA for the remaining epochs.
set -uo pipefail
EXP="${EXP:-kashif_test}"
EPOCHS="${EPOCHS:-25}"
LOG="$HOME/rvc-realtime/logs/${EXP}_train.log"

echo "Watching $LOG for '$EXP' ($EPOCHS epochs)... (Ctrl+C to stop watching; training keeps running)"
start=$(date +%s)

tail -n0 -F "$LOG" 2>/dev/null | while IFS= read -r line; do
  if [[ "$line" =~ Epoch:\ ([0-9]+)\ \[ ]]; then
    n="${BASH_REMATCH[1]}"
    now=$(date +%s)
    elapsed=$(( now - start ))
    pct=$(( 100 * n / EPOCHS ))
    avg=$(( n > 0 ? elapsed / n : 0 ))
    remaining=$(( avg * (EPOCHS - n) ))
    printf "epoch %d/%d (%d%%) | elapsed %dm%02ds | avg %dm%02ds/epoch | ETA ~%dm\n" \
      "$n" "$EPOCHS" "$pct" $((elapsed/60)) $((elapsed%60)) $((avg/60)) $((avg%60)) $((remaining/60))
    if [ "$n" -ge "$EPOCHS" ]; then
      echo "training epochs complete - index step runs next"
      break
    fi
  fi
done
