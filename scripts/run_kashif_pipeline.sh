#!/usr/bin/env bash
# Unattended Stage 2 (Kashif) pipeline: prep -> train -> per-epoch conversion check -> index.
# Safe to re-run after ANY interruption (power loss, reboot, closed terminal, Ctrl+C):
# - prep is skipped if it already produced a filelist.
# - train auto-resumes from the last epoch checkpoint written to rvc/logs/$EXP/ (upstream
#   train.train loads the latest G_*.pth/D_*.pth there on startup) - at most the
#   in-progress epoch (a few minutes) is ever lost.
# - the per-epoch watcher skips any epoch it already converted, so restarting doesn't
#   redo finished work.
#
# Usage (run from the project root on the Ubuntu box, not from here):
#   nohup bash scripts/run_kashif_pipeline.sh > logs/kashif_pipeline_stdout.log 2>&1 &
#   disown
# then close the terminal / walk away. To resume after a crash or reboot, run the exact
# same command again.
set -uo pipefail   # no -e: one failed inference check must not kill the watcher loop

EXP="${EXP:-kashif_test}"
DATA_NAME="${DATA_NAME:-kashif}"
F0="${F0:-rmvpe}"
EPOCHS="${EPOCHS:-25}"
ROOT="$HOME/rvc-realtime"
R="$ROOT/rvc"
PY="$ROOT/venv/bin/python"
LOGS="$ROOT/logs"
CHECKS="$ROOT/tests/out/${EXP}_epoch_checks"
REF="$ROOT/tests/out/${EXP}_ref_phrase.wav"
SRC="$ROOT/dataset/$DATA_NAME/${DATA_NAME}_source.wav"
mkdir -p "$LOGS" "$CHECKS" "$ROOT/tests/out"

echo "$(date +%T) pipeline launched (EXP=$EXP DATA_NAME=$DATA_NAME F0=$F0 EPOCHS=$EPOCHS)" >> "$LOGS/${EXP}_pipeline.log"

# 0. warn (don't block) if not on AC / a sleep target could suspend the machine mid-run
if command -v on_ac_power >/dev/null 2>&1 && ! on_ac_power; then
  echo "$(date +%T) WARNING: running on battery - plug in AC before leaving this unattended" >> "$LOGS/${EXP}_pipeline.log"
fi

# 1. one-time short reference phrase (15s, starting 60s in) for progressive listening
if [ ! -f "$REF" ]; then
  ffmpeg -y -v error -ss 60 -t 15 -i "$SRC" "$REF"
  echo "$(date +%T) reference phrase created: $REF" >> "$LOGS/${EXP}_pipeline.log"
fi

# 2. prep - skipped automatically if a filelist already exists (i.e. already ran)
if [ ! -f "$R/logs/$EXP/filelist.txt" ]; then
  EXP="$EXP" DATA_NAME="$DATA_NAME" F0="$F0" bash "$ROOT/scripts/train_test_model.sh" prep \
    >> "$LOGS/${EXP}_prep.log" 2>&1
  echo "$(date +%T) prep done" >> "$LOGS/${EXP}_pipeline.log"
else
  echo "$(date +%T) prep already done, skipping" >> "$LOGS/${EXP}_pipeline.log"
fi

# 3. background watcher: converts the reference phrase with every new epoch checkpoint
#    as soon as it appears, so quality-over-epochs can be listened to progressively.
watcher() {
  while true; do
    for f in "$R/assets/weights/${EXP}_e"*.pth; do
      [ -e "$f" ] || continue
      base=$(basename "$f" .pth)
      out="$CHECKS/${base}.wav"
      if [ ! -f "$out" ]; then
        (cd "$R" && "$PY" -m infer.cli --model "assets/weights/${base}.pth" \
          --input "$REF" --output "$out" --f0-method "$F0" --index-rate 0 \
          --format wav --overwrite) >> "$LOGS/${EXP}_epoch_checks.log" 2>&1
        echo "$(date +%T) checked $base -> tests/out/${EXP}_epoch_checks/${base}.wav" >> "$LOGS/${EXP}_pipeline.log"
      fi
    done
    pgrep -f "train\.train -e $EXP " >/dev/null || break
    sleep 20
  done
}
watcher &
WATCHER_PID=$!

# 4. train - auto-resumes from the last saved epoch if this is a restart after interruption
EXP="$EXP" EPOCHS="$EPOCHS" bash "$ROOT/scripts/train_test_model.sh" train \
  >> "$LOGS/${EXP}_train.log" 2>&1
echo "$(date +%T) train step exited" >> "$LOGS/${EXP}_pipeline.log"

wait "$WATCHER_PID" 2>/dev/null
# catch the final epoch's checkpoint (watcher may exit one poll cycle before it appears)
for f in "$R/assets/weights/${EXP}_e"*.pth; do
  [ -e "$f" ] || continue
  base=$(basename "$f" .pth)
  out="$CHECKS/${base}.wav"
  if [ ! -f "$out" ]; then
    (cd "$R" && "$PY" -m infer.cli --model "assets/weights/${base}.pth" \
      --input "$REF" --output "$out" --f0-method "$F0" --index-rate 0 \
      --format wav --overwrite) >> "$LOGS/${EXP}_epoch_checks.log" 2>&1
  fi
done

# 5. index
EXP="$EXP" bash "$ROOT/scripts/train_test_model.sh" index >> "$LOGS/${EXP}_index.log" 2>&1

echo "$(date +%T) PIPELINE_DONE" >> "$LOGS/${EXP}_pipeline.log"
