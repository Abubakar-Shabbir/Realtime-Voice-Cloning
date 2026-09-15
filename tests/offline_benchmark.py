"""Feed a WAV through rtrvc.RVC exactly in realtime-GUI-sized blocks; report CPU timing.

Run from ~/rvc-realtime/rvc:
  ../venv/bin/python ../tests/offline_benchmark.py PTH IN.wav OUT.wav [f0method] [block_time] [extra_time] [index]
"""
import os
import sys
import time

args = sys.argv[1:]
pth, inp, out = args[0:3]
f0method = args[3] if len(args) > 3 else "fcpe"
block_time = float(args[4]) if len(args) > 4 else 0.5
extra_time = float(args[5]) if len(args) > 5 else 1.0
index = args[6] if len(args) > 6 else ""
crossfade_time = 0.05

sys.path.insert(0, os.getcwd())  # repo modules (configs, infer) live in the rvc/ working dir
sys.argv = sys.argv[:1]  # configs.config parses sys.argv with webui-only flags

import librosa
import numpy as np
import soundfile as sf
import torch
import torchaudio.transforms as tat

from configs.config import Config
from infer import rtrvc

config = Config()
rvc = rtrvc.RVC(0, 0.0, pth, index, 0.3 if index else 0.0, config, None)
sr = rvc.tgt_sr
zc = sr // 100
block_frame = int(round(block_time * sr / zc)) * zc
crossfade_frame = int(round(crossfade_time * sr / zc)) * zc
sola_buffer_frame = min(crossfade_frame, 4 * zc)
sola_search_frame = zc
extra_frame = int(round(extra_time * sr / zc)) * zc
total = extra_frame + crossfade_frame + sola_search_frame + block_frame
skip_head = extra_frame // zc
return_length = (block_frame + sola_buffer_frame + sola_search_frame) // zc
block_frame_16k = 160 * block_frame // zc
resampler = tat.Resample(orig_freq=sr, new_freq=16000, dtype=torch.float32)

y, _ = librosa.load(inp, sr=sr, mono=True)
input_wav = torch.zeros(total)
input_wav_res = torch.zeros(160 * total // zc)
outs, times = [], []

for start in range(0, len(y) - block_frame, block_frame):
    t0 = time.perf_counter()
    input_wav[:-block_frame] = input_wav[block_frame:].clone()
    input_wav[-block_frame:] = torch.from_numpy(y[start : start + block_frame])
    input_wav_res[:-block_frame_16k] = input_wav_res[block_frame_16k:].clone()
    input_wav_res[-block_frame_16k - 160 :] = resampler(input_wav[-block_frame - 2 * zc :])[160:]
    infer_wav = rvc.infer(input_wav_res, block_frame_16k, skip_head, return_length, f0method)
    times.append(time.perf_counter() - t0)
    # No SOLA alignment here: small block-edge clicks are expected offline.
    outs.append(infer_wav[:block_frame].float().cpu().numpy())

sf.write(out, np.concatenate(outs), sr)
t = np.array(times[2:] if len(times) > 4 else times) * 1000
print(
    f"f0={f0method} block={block_time*1000:.0f}ms extra={extra_time*1000:.0f}ms sr={sr} "
    f"threads={torch.get_num_threads()} blocks={len(times)} "
    f"infer_median={np.median(t):.0f}ms infer_p90={np.percentile(t, 90):.0f}ms "
    f"realtime_ok={np.percentile(t, 90) < block_time * 1000 * 0.9}"
)
