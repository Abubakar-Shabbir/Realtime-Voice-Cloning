#!/usr/bin/env bash
# Usage: record_voice.sh SECONDS OUTFILE.wav
set -euo pipefail
SECS="${1:?seconds}"; OUT="${2:?outfile.wav}"
MIC="alsa_input.pci-0000_00_1f.3.analog-stereo"
mkdir -p "$(dirname "$OUT")"
echo "Recording ${SECS}s from $MIC -> $OUT"
timeout --signal=INT "$SECS" pw-record --target "$MIC" --rate 48000 --channels 1 --format s16 "$OUT" || true
python3 - "$OUT" <<'PY'
import sys, wave, array, math
w = wave.open(sys.argv[1]); n = w.getnframes(); sr = w.getframerate()
a = array.array("h", w.readframes(n))
if not a:
    sys.exit("EMPTY RECORDING")
peak = max(abs(x) for x in a)
rms = math.sqrt(sum(x * x for x in a) / len(a))
db = lambda v: 20 * math.log10(max(v, 1) / 32768)
win = sr // 10
wins = [a[i:i + win] for i in range(0, len(a) - win, win)]
silent = sum(1 for s in wins if math.sqrt(sum(x * x for x in s) / len(s)) < 328) / max(len(wins), 1)
clip = sum(1 for x in a if abs(x) >= 32000) / len(a)
print(f"duration={n/sr:.1f}s rate={sr} rms={db(rms):.1f}dBFS peak={db(peak):.1f}dBFS silent_windows={silent:.0%} clipped={clip:.3%}")
PY
