"""Analyze audio files for RVC training suitability.

Usage: venv/bin/python tests/analyze_dataset.py FILE_OR_FOLDER [...]
Decodes any ffmpeg-readable audio, prints per-file measurements, flags with timestamps,
a verdict, and recommended fixes.
"""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

import librosa
import numpy as np
import soundfile as sf

AUDIO_EXT = {".wav", ".flac", ".mp3", ".m4a", ".aac", ".ogg", ".opus", ".wma", ".webm", ".mp4", ".mkv", ".mov", ".amr", ".3gp"}
HOP_S = 0.05


def ts(sec):
    return f"{int(sec // 60)}:{sec % 60:04.1f}"


def probe(path):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-print_format", "json", "-show_format", "-show_streams", str(path)],
        capture_output=True, text=True,
    )
    info = json.loads(out.stdout or "{}")
    a = next((s for s in info.get("streams", []) if s.get("codec_type") == "audio"), None)
    return info.get("format", {}), a


def decode(path, sr):
    with tempfile.NamedTemporaryFile(suffix=".wav") as tmp:
        subprocess.run(
            ["ffmpeg", "-v", "error", "-y", "-i", str(path), "-vn", "-ac", "1", "-ar", str(sr), "-c:a", "pcm_f32le", tmp.name],
            check=True,
        )
        y, _ = sf.read(tmp.name, dtype="float32")
    return y


def runs(mask, min_len):
    m = np.concatenate([[False], np.asarray(mask, dtype=bool), [False]])
    d = np.flatnonzero(m[1:] != m[:-1])
    starts, ends = d[::2], d[1::2]
    keep = (ends - starts) >= min_len
    return list(zip(starts[keep], ends[keep]))


def merge(events, gap):
    out = []
    for s, e in events:
        if out and s - out[-1][1] < gap:
            out[-1][1] = e
        else:
            out.append([s, e])
    return out


def analyze(path):
    fmt, st = probe(path)
    if st is None:
        print(f"\n### {path}\n  no audio stream - skipped")
        return None
    sr_native = int(st.get("sample_rate", 0) or 0)
    codec = st.get("codec_name", "?")
    ch = st.get("channels", "?")
    bits = st.get("bits_per_raw_sample") or st.get("bits_per_sample") or "-"
    br = int(fmt.get("bit_rate", 0) or 0) // 1000
    lossy = codec not in ("pcm_s16le", "pcm_s24le", "pcm_s32le", "pcm_f32le", "pcm_f64le", "flac", "alac", "pcm_u8")

    sr = max(sr_native, 16000) if sr_native else 44100
    y = decode(path, sr)
    dur = len(y) / sr
    flags, fixes = [], []

    print(f"\n### {path}")
    print(f"  format: {codec}, {sr_native} Hz, {ch} ch, bits={bits}, bitrate={br} kbps, duration={ts(dur)}")

    a = np.abs(y)
    peak = float(a.max()) if len(y) else 0.0
    overshoot = int((a > 1.0).sum())
    peak_events = merge(runs(a >= 0.999, 1), int(0.02 * sr))
    flat = (a[1:] > 0.95) & (np.abs(np.diff(y)) < 1e-4)
    flat_events = merge(runs(flat, 3), int(0.02 * sr))
    dc = float(y.mean())

    hop = int(HOP_S * sr)
    rms = librosa.feature.rms(y=y, frame_length=hop, hop_length=hop, center=False)[0]
    db = 20 * np.log10(np.maximum(rms, 1e-9))
    p5, p50, p95 = np.percentile(db, [5, 50, 95])
    thr = max(p95 - 25, p5 + 10)
    speech = db > thr
    speech_s = speech.sum() * HOP_S
    noise_floor = float(np.percentile(db[~speech], 50)) if (~speech).any() else float(p5)
    speech_lvl = float(np.percentile(db[speech], 50)) if speech.any() else float(p50)
    snr = speech_lvl - noise_floor

    sil_runs = runs(~speech, int(2.0 / HOP_S))
    long_sil = sum(e - s for s, e in sil_runs) * HOP_S
    cont_runs = runs(speech, int(25.0 / HOP_S))

    n_fft = 4096
    S = np.abs(librosa.stft(y, n_fft=n_fft, hop_length=hop, center=False)) ** 2
    k = min(S.shape[1], len(speech))
    f = librosa.fft_frequencies(sr=sr, n_fft=n_fft)
    band = lambda M, lo, hi: M[(f >= lo) & (f < hi)].sum() + 1e-12
    quiet = S[:, :k][:, ~speech[:k]] if (~speech[:k]).any() else S[:, :k]
    loud = S[:, :k][:, speech[:k]] if speech[:k].any() else S[:, :k]
    hum = 10 * np.log10((band(quiet, 47, 53) + band(quiet, 97, 103) + band(quiet, 147, 153)) / band(quiet, 200, 4000))
    rumble = 10 * np.log10(band(quiet, 20, 90) / band(quiet, 200, 4000))
    spec = 10 * np.log10(loud.mean(1) + 1e-20)
    rel = spec - spec[(f >= 500) & (f < 1500)].mean()
    cutoff = float(f[rel > -70].max())

    seg = int(30 / HOP_S)
    seg_lvls = [np.percentile(db[i:i + seg][speech[i:i + seg]], 50) for i in range(0, len(db), seg) if speech[i:i + seg].sum() > 20]
    lvl_spread = float(np.ptp(seg_lvls)) if len(seg_lvls) > 1 else 0.0

    y16 = librosa.resample(y, orig_sr=sr, target_sr=16000) if sr != 16000 else y
    f0 = librosa.yin(y16, fmin=60, fmax=500, sr=16000, frame_length=1024, hop_length=320)
    e16 = librosa.feature.rms(y=y16, frame_length=1024, hop_length=320)[0][: len(f0)]
    voiced = f0[: len(e16)][e16 > 10 ** (thr / 20)]
    f_med = float(np.median(voiced)) if len(voiced) else float("nan")
    f_lo, f_hi = (np.percentile(voiced, [10, 90]) if len(voiced) else (np.nan, np.nan))

    print(f"  level:  peak={20*np.log10(max(peak,1e-9)):+.1f} dBFS, speech median={speech_lvl:.1f} dBFS, DC={dc:+.4f}")
    print(f"  peaks:  {len(peak_events)} events at/above full scale ({overshoot} samples >1.0), flat-topped (true clipping) events: {len(flat_events)}")
    print(f"  noise:  floor={noise_floor:.1f} dBFS, SNR~{snr:.1f} dB, hum(50Hz family)={hum:.1f} dB, low rumble(<90Hz)={rumble:.1f} dB")
    print(f"  speech: {speech_s/60:.1f} min of {dur/60:.1f} min ({speech.mean():.0%}), silences>2s total {long_sil:.0f}s in {len(sil_runs)} gaps")
    print(f"  tone:   high-frequency cutoff ~{cutoff/1000:.1f} kHz, pitch median={f_med:.0f} Hz (p10 {f_lo:.0f} - p90 {f_hi:.0f}), level spread across 30s blocks={lvl_spread:.1f} dB")

    score = 0
    if sr_native and sr_native < 32000:
        flags.append(f"BAD  sample rate {sr_native} Hz (<32 kHz): limits quality"); score += 2
        fixes.append("Use a 44.1/48 kHz source if one exists (upsampling does not add detail)")
    if lossy:
        if br and br < 64:
            flags.append(f"BAD  lossy {codec} at only {br} kbps"); score += 2
        else:
            flags.append(f"WARN lossy {codec} {br} kbps (acceptable for voice)"); score += 1
        fixes.append("Prefer an uncompressed/lossless original if available; otherwise convert to WAV for training (automatic)")
    if cutoff < 11000:
        flags.append(f"WARN high-frequency cutoff ~{cutoff/1000:.1f} kHz: phone/low-bitrate source"); score += 1
    if len(flat_events) > 3:
        flags.append(f"BAD  true clipping: {len(flat_events)} flat-topped events, at " + ", ".join(ts(s / sr) for s, _ in flat_events[:8])); score += 2
        fixes.append("Clipping cannot be repaired well: cut those sections or re-record with lower input gain")
    elif flat_events:
        flags.append(f"WARN {len(flat_events)} flat-topped (clipped) moments at " + ", ".join(ts(s / sr) for s, _ in flat_events)); score += 1
        fixes.append("Listen at the clipped timestamps; cut them if distorted")
    if overshoot:
        flags.append(f"INFO {len(peak_events)} short peaks above full scale (decoder overshoot, no flat tops) at " + ", ".join(ts(s / sr) for s, _ in peak_events[:8]))
        fixes.append("Lower gain ~2 dB when exporting to 16-bit WAV so those peaks don't hard-clip (automatic)")
    if peak < 10 ** (-12 / 20):
        flags.append(f"WARN quiet: peak {20*np.log10(max(peak,1e-9)):.1f} dBFS"); score += 1
        fixes.append("Normalize level (peak about -3 dBFS) - automatic")
    if snr < 20:
        flags.append(f"BAD  noisy: SNR ~{snr:.0f} dB (want >30)"); score += 2
        fixes.append("Noise reduction in an editor (Audacity: Effect > Noise Removal, profile from a silent part, 6-12 dB) or re-record in a quieter room")
    elif snr < 30:
        flags.append(f"WARN some background noise: SNR ~{snr:.0f} dB"); score += 1
        fixes.append("Optional light noise reduction (Audacity Noise Removal ~6 dB); avoid strong settings - artifacts are learned too")
    if hum > -10:
        flags.append(f"WARN mains hum ({hum:.0f} dB)"); score += 1
        fixes.append("Remove hum: high-pass 80-90 Hz + notch 50/100/150 Hz - automatic")
    if rumble > 0:
        flags.append(f"WARN low-frequency rumble ({rumble:.0f} dB)"); score += 1
        fixes.append("High-pass filter at 80-90 Hz - automatic")
    if abs(dc) > 0.005:
        flags.append(f"WARN DC offset {dc:+.3f}"); fixes.append("DC offset removal - automatic")
    if speech_s < 5 * 60:
        flags.append(f"{'BAD ' if speech_s < 3*60 else 'WARN'} only {speech_s/60:.1f} min of speech (ideal 10-30 min, minimum ~5)"); score += 2 if speech_s < 3 * 60 else 1
        fixes.append("Add more clean recordings of the same voice (same mic/room) to reach 10+ minutes of speech")
    elif speech_s < 10 * 60:
        flags.append(f"INFO {speech_s/60:.1f} min of speech: enough for a first model; 10-15+ min improves quality")
    if long_sil > 0.25 * dur:
        flags.append(f"WARN {long_sil:.0f}s of long silences"); fixes.append("Trim silences - automatic (the RVC slicer also removes most)")
    if lvl_spread > 10:
        flags.append(f"WARN loudness varies {lvl_spread:.0f} dB between parts"); score += 1
        fixes.append("Even out loudness per segment - automatic; check whether mic/room changed")
    if cont_runs:
        flags.append("CHECK continuous sound without pauses >25s at " + ", ".join(f"{ts(s*HOP_S)}-{ts(e*HOP_S)}" for s, e in cont_runs[:5]) + " (possible music/TV/noise - listen)")
    if len(voiced) and f_hi / max(f_lo, 1) > 2.6:
        flags.append(f"CHECK very wide pitch range {f_lo:.0f}-{f_hi:.0f} Hz: possible second speaker, singing or shouting - listen")
    if isinstance(ch, int) and ch > 1:
        fixes.append("Convert stereo to mono - automatic")

    verdict = "GOOD to train" if score == 0 else "USABLE (minor fixes)" if score <= 2 else "USABLE after fixes" if score <= 4 else "POOR - fix heavily or re-record"
    print("  flags:" if flags else "  flags: none")
    for x in flags:
        print(f"    - {x}")
    print(f"  verdict: {verdict} (issue score {score})")
    if fixes:
        print("  fixes:")
        for x in dict.fromkeys(fixes):
            print(f"    * {x}")
    print("  always listen for: other voices, music/TV, laughter, echo - not reliably detectable by measurement")
    return {"speech_s": speech_s, "dur": dur, "score": score, "snr": snr, "sr": sr_native, "f0": f_med}


def main():
    files = []
    for arg in sys.argv[1:]:
        p = Path(arg)
        files += sorted(q for q in p.rglob("*") if q.suffix.lower() in AUDIO_EXT) if p.is_dir() else [p]
    if not files:
        sys.exit("no audio files found")
    results = [r for r in (analyze(f) for f in files) if r]
    if len(results) > 1:
        tot = sum(r["speech_s"] for r in results)
        pitches = ", ".join("%.0f" % r["f0"] for r in results)
        print(f"\n### TOTAL: {len(results)} files, {sum(r['dur'] for r in results)/60:.1f} min audio, {tot/60:.1f} min speech")
        print(f"    sample rates: {sorted({r['sr'] for r in results})}, SNR range {min(r['snr'] for r in results):.0f}-{max(r['snr'] for r in results):.0f} dB, median pitch per file: {pitches} Hz")


if __name__ == "__main__":
    main()
