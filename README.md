# RVC voice conversion → PipeWire virtual microphone (Stage 1)

Project folder: **`/home/abubakar/rvc-realtime`** (same as `~/rvc-realtime`)

> **Important limitation (measured):** on this laptop (Intel i7-7600U, no GPU) RVC is
> **~1.25× slower than realtime** even on AC power with the Performance profile, and gets slower
> as the CPU heats up (reaches 93–95 °C and throttles). Live conversion during a call therefore
> stutters and falls behind. Stage 1 uses **recorded → converted → played into the virtual
> microphone** instead. The same project runs live on a faster PC / NVIDIA GPU.

## What is where

| Item | Path |
|---|---|
| Start / stop (virtual mic + RVC GUI) | `start.sh`, `stop.sh` |
| Virtual mic scripts | `audio/setup_virtual_mic.sh`, `audio/teardown_virtual_mic.sh`, `audio/route_rvc_output.sh` |
| Official RVC code | `rvc/` (RVC-Project/Retrieval-based-Voice-Conversion-WebUI, commit in `rvc_commit.txt`) |
| Python environment | `venv/` (Python 3.12.3, torch 2.4.1 CPU) — system Python untouched |
| Your trained voice models | `rvc/assets/weights/` |
| Voice index (optional) | `rvc/logs/abubakar_test/added_*.index` (+ link in `rvc/assets/indices/`) |
| Training recording (filtered) | `dataset/abubakar/abubakar_take2_hp90.wav` |
| Original recordings | `dataset/raw_takes/`, `dataset/partial_takes/` |
| Training working files | `rvc/logs/abubakar_test/` |
| Base models (official, MIT) | `rvc/assets/hubert_base/`, `rvc/assets/rmvpe/`, `rvc/assets/pretrained_v2/` |
| Tests / benchmarks | `tests/` |
| Logs | `logs/` |

## Virtual audio devices

| Name in apps | PipeWire name | Purpose |
|---|---|---|
| **RVC Virtual Microphone** | `rvc_mic` | **Select this in Chrome / Google Meet** |
| RVC Output (internal) | `rvc_out` | RVC (or a player) sends converted audio here; never reaches speakers |
| Monitor of RVC Output (internal) | `rvc_out.monitor` | Internal — do not select |

Created at runtime only (gone after reboot or `./stop.sh`). Your built-in mic and speakers stay the defaults.

## Use it: send converted voice into Google Meet (works on this laptop)

```bash
cd ~/rvc-realtime
./audio/setup_virtual_mic.sh                       # 1. create RVC Virtual Microphone
# 2. record a phrase (Ctrl+C to stop early)
./tests/record_voice.sh 15 ~/rvc-realtime/tests/out/my_phrase.wav
# 3. convert it with your model (CPU, roughly 2-4x the audio length)
cd rvc && ../venv/bin/python -m infer.cli --model assets/weights/MODEL_FILE.pth \
  --input ../tests/out/my_phrase.wav --output ../tests/out/my_phrase_rvc.wav \
  --f0-method rmvpe --index-rate 0 --overwrite && cd ..
# 4. In Google Meet: Settings → Audio → Microphone → "RVC Virtual Microphone"
# 5. play the converted phrase into the meeting
pw-play --target rvc_out tests/out/my_phrase_rvc.wav
```

One-command check that the virtual mic delivers the converted signal (not your raw mic):
`./tests/playback_test.sh rvc/assets/weights/MODEL_FILE.pth tests/out/my_phrase.wav`

## Live mode (GUI) — for faster hardware

```bash
./start.sh     # creates virtual mic, opens "RVC - GUI", routes RVC output into rvc_mic
./stop.sh      # closes GUI and removes the virtual mic
```

GUI preset (written by `scripts/write_gui_config.py` into `rvc/configs/config.json`):

| GUI field | Value | Why |
|---|---|---|
| Device type / Input / Output | ALSA / pipewire / pipewire | Mic comes from PipeWire; `start.sh` moves output into `rvc_out` |
| Sample rate | Use model sample rate (40 kHz) | |
| pitch detection algorithm | pm | cheapest on CPU |
| Sample length | 1.0 s | best measured CPU ratio |
| Extra inference time | 0.25 s | less HuBERT work |
| Fade length | 0.05 s | |
| Response threshold | −50 dB | ignore background noise |
| Noise reduction | off | saves CPU |

## Measured CPU performance (i7-7600U, AC + Performance)

| Setting | Time per chunk | vs realtime |
|---|---|---|
| 40k, 2 threads, 1.0 s chunk, 0.25 s context | 1237 ms | 1.24× too slow (best) |
| 40k, 2 threads, 0.5 s chunk, 0.25 s context | 650 ms | 1.30× too slow |
| 32k model, same settings | 670 / 1268 ms | no gain |
| 4 threads | slower than 2 | hyper-threads don't help |
| On battery (Balanced) | ~1.6× slower again | |

~80% of the time is the voice generator (synthesis). Details: `logs/profile_*.log`, `logs/benchmark.log`.

## Model provenance

- Voice data: Abubakar's own voice, recorded 2026-09-14 (5 min 20 s, built-in mic, 90 Hz high-pass).
  Recording SNR is only ~15 dB (room noise) → expect a noisy/rough result; re-record in a quiet room for quality.
- Base weights: `lj1995/VoiceConversionWebUI` (MIT) — HuBERT base, RMVPE, `pretrained_v2/f0G40k.pth` + `f0D40k.pth`
  (pretrained on the VCTK dataset, CC-BY 4.0).
- Model: RVC v2, 40 kHz, pitch-guided. Training details: _filled in after training_.

## Retrain

```bash
F0=rmvpe bash scripts/train_test_model.sh prep     # slice, pitch, HuBERT features
EPOCHS=30 bash scripts/train_test_model.sh train   # saves a usable model every epoch
bash scripts/train_test_model.sh index             # optional .index
```

## Troubleshooting

| Problem | Fix |
|---|---|
| Meet/Chrome doesn't list "RVC Virtual Microphone" | `./audio/setup_virtual_mic.sh`, then reload the Meet tab |
| Silence in Meet | Check `pactl list short sources \| grep rvc_mic`; play with `pw-play --target rvc_out file.wav` |
| Raw voice heard instead of converted | Meet is using the built-in mic — re-select "RVC Virtual Microphone" |
| Live GUI stutters / delay grows | Expected on this CPU (see limitation above) |
| `No module named 'infer'` / circular import in training | Run training via `scripts/train_test_model.sh` (uses `python -m`) |
| Laptop very hot / slow | Use AC power, `powerprofilesctl set performance`, hard raised surface |

## Undo / reset

```bash
./stop.sh                                   # GUI + router + virtual devices
./audio/teardown_virtual_mic.sh             # only the virtual devices
powerprofilesctl set balanced               # original power profile (was: balanced)
wpctl set-volume @DEFAULT_AUDIO_SOURCE@ 0.45   # original mic volume
```
System packages added: `ffmpeg`, `pulseaudio-utils`, `libportaudio2`. Everything else lives in this folder;
deleting `~/rvc-realtime` removes the project completely.
