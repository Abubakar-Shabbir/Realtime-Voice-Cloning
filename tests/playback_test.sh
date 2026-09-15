#!/usr/bin/env bash
# Convert a recording with RVC, play it into the virtual mic, capture rvc_mic, and compare.
# Usage: playback_test.sh MODEL.pth INPUT.wav [OUT_DIR]
#   KEEP_MIC=1  leave the virtual mic loaded afterwards (for browser / Meet tests)
#   INDEX=path  optional .index file (index rate 0.5 when set)
set -euo pipefail
ROOT="$HOME/rvc-realtime"
MODEL="$(realpath "${1:?model .pth}")"
INPUT="$(realpath "${2:?input wav}")"
OUT="$(realpath -m "${3:-$ROOT/tests/out/playback}")"
PY="$ROOT/venv/bin/python"
mkdir -p "$OUT"

echo "=== 1/4 offline RVC conversion (CPU)  $(date +%T)"
INDEX_ARGS=(--index-rate 0)
[ -n "${INDEX:-}" ] && INDEX_ARGS=(--index "$(realpath "$INDEX")" --index-rate 0.5)
t0=$(date +%s)
(cd "$ROOT/rvc" && RVC_CUDA_GRAPH=0 "$PY" -m infer.cli --model "$MODEL" --input "$INPUT" \
  --output "$OUT/converted.wav" --f0-method rmvpe "${INDEX_ARGS[@]}" --protect 0.33 \
  --rms-mix-rate 1.0 --format wav --overwrite)
test -s "$OUT/converted.wav" || { echo "CONVERSION FAILED: no converted.wav"; exit 1; }
echo "converted in $(( $(date +%s) - t0 ))s -> $OUT/converted.wav"

echo "=== 2/4 virtual microphone"
"$ROOT/audio/setup_virtual_mic.sh" | tail -2

echo "=== 3/4 play converted audio into rvc_out, record rvc_mic"
rm -f "$OUT/rvc_mic_capture.wav"
pw-record --target rvc_mic --rate 48000 --channels 1 --format s16 "$OUT/rvc_mic_capture.wav" &
REC=$!
sleep 0.7
pw-play --target rvc_out "$OUT/converted.wav"
sleep 0.5
kill -INT "$REC"; wait "$REC" 2>/dev/null || true
test -s "$OUT/rvc_mic_capture.wav" || { echo "CAPTURE FAILED"; exit 1; }

echo "=== 4/4 objective comparison"
echo "--- converted file vs what the virtual mic delivered (expect: high waveform corr, low mfcc distance)"
"$PY" "$ROOT/tests/compare_audio.py" "$OUT/converted.wav" "$OUT/rvc_mic_capture.wav"
echo "--- your raw recording vs what the virtual mic delivered (expect: same timing, different timbre)"
"$PY" "$ROOT/tests/compare_audio.py" "$INPUT" "$OUT/rvc_mic_capture.wav"

if [ "${KEEP_MIC:-0}" != "1" ]; then
  "$ROOT/audio/teardown_virtual_mic.sh" | head -1
else
  echo "virtual mic left loaded (KEEP_MIC=1)"
fi
