"""Per-stage CPU timing of rtrvc.RVC.infer (HuBERT / f0 / generator) across thread and block settings.

Run from ~/rvc-realtime/rvc:
  ../venv/bin/python ../tests/profile_rvc.py PTH IN.wav
"""
import os
import sys
import time
from collections import defaultdict

pth, inp = sys.argv[1:3]
sys.path.insert(0, os.getcwd())
sys.argv = sys.argv[:1]

import librosa
import numpy as np
import torch
import torchaudio.transforms as tat

from configs.config import Config
from infer import rtrvc

acc = defaultdict(float)


def timed(name, fn):
    def wrapper(*a, **k):
        t = time.perf_counter()
        try:
            return fn(*a, **k)
        finally:
            acc[name] += time.perf_counter() - t
    return wrapper


rtrvc.extract_hubert_features = timed("hubert", rtrvc.extract_hubert_features)
rvc = rtrvc.RVC(0, 0.0, pth, "", 0.0, Config(), None)
rvc.get_f0 = timed("f0", rvc.get_f0)
rvc.net_g.infer = timed("generator", rvc.net_g.infer)

sr = rvc.tgt_sr
zc = sr // 100
y, _ = librosa.load(inp, sr=sr, mono=True)
resampler = tat.Resample(orig_freq=sr, new_freq=16000, dtype=torch.float32)


def run(threads, block_time, extra_time, f0method="pm", n_blocks=12):
    torch.set_num_threads(threads)
    block = int(round(block_time * sr / zc)) * zc
    crossfade = int(round(0.05 * sr / zc)) * zc
    sola_buf = min(crossfade, 4 * zc)
    extra = int(round(extra_time * sr / zc)) * zc
    total = extra + crossfade + zc + block
    skip_head, ret_len = extra // zc, (block + sola_buf + zc) // zc
    b16 = 160 * block // zc
    wav, wav16 = torch.zeros(total), torch.zeros(160 * total // zc)
    rows = []
    for i in range(n_blocks + 2):
        s = (i * block) % (len(y) - block)
        acc.clear()
        t = time.perf_counter()
        wav[:-block] = wav[block:].clone()
        wav[-block:] = torch.from_numpy(y[s : s + block])
        wav16[:-b16] = wav16[b16:].clone()
        wav16[-b16 - 160 :] = resampler(wav[-block - 2 * zc :])[160:]
        rvc.infer(wav16, b16, skip_head, ret_len, f0method)
        if i >= 2:
            rows.append((time.perf_counter() - t, acc["hubert"], acc["f0"], acc["generator"]))
    tot, hub, f0, gen = (np.median([r[j] for r in rows]) * 1000 for j in range(4))
    ratio = tot / (block_time * 1000)
    print(
        f"threads={threads} f0={f0method:5} block={block_time*1000:4.0f}ms extra={extra_time*1000:4.0f}ms | "
        f"total={tot:5.0f} hubert={hub:5.0f} f0={f0:4.0f} gen={gen:5.0f} other={tot-hub-f0-gen:4.0f} ms | "
        f"x_realtime={ratio:.2f} {'OK' if ratio < 0.9 else 'TOO SLOW'}",
        flush=True,
    )


if os.environ.get("PROFILE_SET") == "quick":
    for block_time, extra_time in ((0.5, 0.25), (1.0, 0.25)):
        run(2, block_time, extra_time)
else:
    for threads in (2, 4):
        run(threads, 0.5, 1.0)
    for block_time, extra_time in ((0.5, 0.25), (1.0, 0.25), (0.25, 0.25)):
        run(4, block_time, extra_time)
