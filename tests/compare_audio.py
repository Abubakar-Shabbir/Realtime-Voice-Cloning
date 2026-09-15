"""Compare a raw mic recording with a converted recording made at the same time.

Usage: venv/bin/python tests/compare_audio.py raw.wav converted.wav
"""
import sys

import librosa
import numpy as np

SR = 16000


def load(path):
    y, _ = librosa.load(path, sr=SR, mono=True)
    return y


def dbfs(x):
    return 20 * np.log10(max(np.sqrt(np.mean(x ** 2)), 1e-9))


def voiced_f0(y):
    f0 = librosa.yin(y, fmin=60, fmax=500, sr=SR, frame_length=1024)
    rms = librosa.feature.rms(y=y, frame_length=1024, hop_length=256)[0][: len(f0)]
    keep = rms > max(rms.max() * 0.1, 1e-4)
    return float(np.median(f0[: len(keep)][keep])) if keep.any() else float("nan")


def envelope(y):
    return librosa.feature.rms(y=y, frame_length=400, hop_length=160)[0]  # 10 ms hop


raw, conv = load(sys.argv[1]), load(sys.argv[2])
n = min(len(raw), len(conv))
raw, conv = raw[:n], conv[:n]

er, ec = envelope(raw), envelope(conv)
er, ec = (er - er.mean()) / (er.std() + 1e-9), (ec - ec.mean()) / (ec.std() + 1e-9)
max_lag = 200  # 2 s
corr = [np.mean(er[: len(er) - lag] * ec[lag:]) for lag in range(max_lag)]
lag = int(np.argmax(corr))

aligned_raw, aligned_conv = raw[: n - lag * 160], conv[lag * 160 :]
m_raw = librosa.feature.mfcc(y=aligned_raw, sr=SR, n_mfcc=20)[1:]
m_conv = librosa.feature.mfcc(y=aligned_conv, sr=SR, n_mfcc=20)[1:]
k = min(m_raw.shape[1], m_conv.shape[1])
mfcc_dist = float(np.mean(np.linalg.norm(m_raw[:, :k] - m_conv[:, :k], axis=0)))
sample_corr = float(np.corrcoef(aligned_raw[: len(aligned_conv)], aligned_conv[: len(aligned_raw)])[0, 1])

print(f"raw:       rms={dbfs(raw):6.1f} dBFS  median_f0={voiced_f0(raw):6.1f} Hz")
print(f"converted: rms={dbfs(conv):6.1f} dBFS  median_f0={voiced_f0(conv):6.1f} Hz")
print(f"envelope_corr_peak={max(corr):.2f}  lag={lag * 10} ms  (same speech timing if > 0.3)")
print(f"waveform_corr_after_alignment={sample_corr:.2f}  (near 1.0 would mean raw passthrough)")
print(f"mfcc_distance={mfcc_dist:.1f}  (0 = identical timbre)")
