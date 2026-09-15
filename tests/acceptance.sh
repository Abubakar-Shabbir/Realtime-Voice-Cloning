#!/usr/bin/env bash
# Stage 1 acceptance checks A-K (recorded-phrase mode).
# Usage: acceptance.sh PHRASE.wav PLAYBACK_DIR
#   PHRASE.wav    raw phrase recorded from the physical mic
#   PLAYBACK_DIR  output dir of tests/playback_test.sh (converted.wav, rvc_mic_capture.wav)
# Run F/G/H while Chrome (mic test page or Google Meet) is using "RVC Virtual Microphone".
set -uo pipefail
ROOT="$HOME/rvc-realtime"
PY="$ROOT/venv/bin/python"
PHRASE="${1:?raw phrase wav}"
PB="${2:?playback dir}"
MIC_HW="alsa_input.pci-0000_00_1f.3.analog-stereo"
SPK_HW="alsa_output.pci-0000_00_1f.3.analog-stereo"
TMP="$(mktemp -d)"
declare -A RESULT

res() { RESULT[$1]="$2"; printf "%-2s %-8s %s\n" "$1" "$2" "$3"; }
metric() { grep -o "$2=[-0-9.]*" "$1" | head -1 | cut -d= -f2; }
level_db() { "$PY" -c "import soundfile as sf, numpy as np, sys; y,_=sf.read(sys.argv[1],dtype='float32'); y=y if y.ndim==1 else y.mean(1); print(round(20*np.log10(np.sqrt((y**2).mean())+1e-9),1))" "$1"; }

echo "=== Stage 1 acceptance  $(date '+%F %T')"

# A: physical mic captures audio
timeout --signal=INT 3 pw-record --target "$MIC_HW" --rate 48000 --channels 1 --format s16 "$TMP/a.wav" 2>/dev/null
a=$(level_db "$TMP/a.wav")
awk -v v="$a" 'BEGIN{exit !(v > -70)}' && res A PASS "physical mic captured audio (level ${a} dBFS)" || res A FAIL "physical mic silent (${a} dBFS)"

# B: RVC input came from the physical mic recording
b=$(level_db "$PHRASE")
awk -v v="$b" 'BEGIN{exit !(v > -50)}' && res B PASS "raw phrase from physical mic present (${b} dBFS): $PHRASE" || res B FAIL "raw phrase missing/silent"

# C + D: conversion produced audio that differs from the raw voice
if [ -s "$PB/converted.wav" ]; then
  "$PY" "$ROOT/tests/compare_audio.py" "$PHRASE" "$PB/converted.wav" > "$TMP/cd.txt" 2>/dev/null
  d=$(metric "$TMP/cd.txt" mfcc_distance); env=$(metric "$TMP/cd.txt" envelope_corr_peak)
  awk -v d="$d" 'BEGIN{exit !(d > 20)}' && res C PASS "converted timbre differs from raw (mfcc_distance=$d)" || res C FAIL "converted too similar to raw (mfcc_distance=$d)"
  awk -v e="$env" 'BEGIN{exit !(e > 0.5)}' && res D PASS "converted audio follows the spoken phrase (envelope_corr=$env)" || res D FAIL "converted audio does not follow phrase (envelope_corr=$env)"
else
  res C FAIL "no $PB/converted.wav"; res D FAIL "no converted audio"
fi

# E: what the virtual mic delivered == converted audio
if [ -s "$PB/rvc_mic_capture.wav" ] && [ -s "$PB/converted.wav" ]; then
  "$PY" "$ROOT/tests/compare_audio.py" "$PB/converted.wav" "$PB/rvc_mic_capture.wav" > "$TMP/e.txt" 2>/dev/null
  d=$(metric "$TMP/e.txt" mfcc_distance); env=$(metric "$TMP/e.txt" envelope_corr_peak)
  awk -v d="$d" -v e="$env" 'BEGIN{exit !(d < 5 && e > 0.8)}' && res E PASS "rvc_mic delivered the converted signal (mfcc_distance=$d, envelope_corr=$env)" || res E FAIL "rvc_mic capture != converted (mfcc_distance=$d, envelope_corr=$env)"
else
  res E FAIL "missing rvc_mic capture"
fi

# F/G/H: Chrome is recording from rvc_mic (not the built-in mic)
MIC_IDX=$(pactl list short sources | awk '$2=="rvc_mic"{print $1}')
pactl -f json list source-outputs > "$TMP/so.json" 2>/dev/null
chrome=$(python3 - "$TMP/so.json" "${MIC_IDX:--1}" <<'PY'
import json, sys
outs = json.load(open(sys.argv[1])); rvc = int(sys.argv[2])
on_rvc = sum(1 for o in outs if "chrom" in o["properties"].get("application.name", "").lower() and o["source"] == rvc)
on_other = sum(1 for o in outs if "chrom" in o["properties"].get("application.name", "").lower() and o["source"] != rvc)
print(on_rvc, on_other)
PY
)
read -r c_rvc c_other <<< "$chrome"
if [ -z "$MIC_IDX" ]; then
  res F FAIL "rvc_mic does not exist (run audio/setup_virtual_mic.sh)"
elif [ "${c_rvc:-0}" -gt 0 ]; then
  res F PASS "Chrome is capturing from RVC Virtual Microphone ($c_rvc stream)"
else
  res F MANUAL "open tests/mic_test.html or Meet with RVC Virtual Microphone selected, then re-run"
fi
res G MANUAL "Google Meet: Settings > Audio > Microphone shows/selects 'RVC Virtual Microphone' (observe)"
if [ "${c_rvc:-0}" -gt 0 ] && [ "${c_other:-0}" -eq 0 ] && [ "${RESULT[E]}" = PASS ]; then
  res H PASS "Chrome input is rvc_mic only, and rvc_mic carries the converted signal"
elif [ "${c_other:-0}" -gt 0 ]; then
  res H FAIL "Chrome also/instead captures another source ($c_other stream) - raw mic may be selected"
else
  res H MANUAL "needs Chrome capturing rvc_mic (see F)"
fi

# I: no feedback path into speakers
links=$(pw-link -l 2>/dev/null | grep -A1 -E "^(rvc_out|input.rvc_mic|rvc_mic)" | grep -c "$SPK_HW" || true)
[ "${links:-0}" -eq 0 ] && res I PASS "no links from RVC devices to the speakers" || res I FAIL "$links link(s) from RVC devices to speakers"

# J: physical devices remain defaults and unmuted
ds=$(pactl get-default-sink); dm=$(pactl get-default-source)
vs=$(wpctl get-volume @DEFAULT_AUDIO_SINK@); vm=$(wpctl get-volume @DEFAULT_AUDIO_SOURCE@)
if [ "$ds" = "$SPK_HW" ] && [ "$dm" = "$MIC_HW" ] && ! grep -q MUTED <<< "$vs$vm" && [ "${RESULT[A]}" = PASS ]; then
  res J PASS "defaults are built-in speakers/mic, unmuted (speaker ${vs#Volume: }, mic ${vm#Volume: })"
else
  res J FAIL "defaults changed or muted: sink=$ds source=$dm ($vs / $vm)"
fi

# K: documented reset + setup restores the virtual mic
if [ "${SKIP_K:-0}" = 1 ]; then
  res K SKIPPED "SKIP_K=1 (avoid dropping the mic during a call)"
else
  "$ROOT/audio/teardown_virtual_mic.sh" > /dev/null
  gone=$(pactl list short sources | grep -c rvc_mic || true)
  "$ROOT/audio/setup_virtual_mic.sh" > /dev/null
  name=$(pactl -f json list sources | python3 -c 'import json,sys; print(next((s["description"] for s in json.load(sys.stdin) if s["name"]=="rvc_mic"), ""))')
  [ "$gone" -eq 0 ] && [ "$name" = "RVC Virtual Microphone" ] && res K PASS "teardown removed it; setup recreated 'RVC Virtual Microphone'" || res K FAIL "reset/setup failed (gone=$gone name='$name')"
fi

rm -rf "$TMP"
echo "=== summary: $(for k in A B C D E F G H I J K; do printf "%s=%s " $k "${RESULT[$k]:-?}"; done)"
