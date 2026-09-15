"""Write the Linux preset for realtime_gui.py (rvc/configs/config.json).

Usage (from anywhere):
  venv/bin/python scripts/write_gui_config.py PTH [--index PATH] [--f0 fcpe] [--block 0.5]
      [--extra 1.0] [--crossfade 0.05] [--index-rate 0.0] [--rms-mix 0.0] [--threshold -50] [--pitch 0]
"""
import argparse
import json
from pathlib import Path

RVC = Path.home() / "rvc-realtime" / "rvc"

p = argparse.ArgumentParser()
p.add_argument("pth")
p.add_argument("--index", default="")
p.add_argument("--f0", default="fcpe", choices=["pm", "rmvpe", "fcpe"])
p.add_argument("--block", type=float, default=0.5)
p.add_argument("--extra", type=float, default=1.0)
p.add_argument("--crossfade", type=float, default=0.05)
p.add_argument("--index-rate", type=float, default=0.0)
p.add_argument("--rms-mix", type=float, default=0.0)
p.add_argument("--threshold", type=float, default=-50)
p.add_argument("--pitch", type=float, default=0)
a = p.parse_args()

cfg = {
    "pth_path": a.pth,
    "index_path": a.index,
    "sg_hostapi": "ALSA",
    "sg_wasapi_exclusive": False,
    "sg_input_device": "pipewire",
    "sg_output_device": "pipewire",
    "sr_type": "sr_model",
    "threhold": a.threshold,
    "pitch": a.pitch,
    "formant": 0.0,
    "rms_mix_rate": a.rms_mix,
    "index_rate": a.index_rate,
    "block_time": a.block,
    "crossfade_length": a.crossfade,
    "extra_time": a.extra,
    "f0method": a.f0,
    "I_noise_reduce": False,
    "O_noise_reduce": False,
}
out = RVC / "configs" / "config.json"
out.write_text(json.dumps(cfg, indent=2) + "\n", encoding="utf8")
print(f"wrote {out}\n{json.dumps(cfg, indent=2)}")
