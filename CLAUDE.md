# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

Linux (Ubuntu 24.04, PipeWire 1.0.5) voice-conversion pipeline: physical mic → RVC → PipeWire virtual microphone ("RVC Virtual Microphone") → Chrome / Google Meet. Built on the official RVC-Project WebUI repo, CPU-only (Intel i7-7600U, no GPU). `README.md` is the user-facing guide (paths, commands, troubleshooting, undo); keep it in sync when behavior changes.

**Hard constraint:** live RVC on this laptop is ≥1.24× slower than realtime even on AC + Performance profile (generator ≈80% of inference time; 32k model and 4 threads don't help; CPU throttles at 93–98 °C). The working mode is therefore *record → offline convert (`infer.cli`) → `pw-play --target rvc_out`*. The live GUI path exists for faster hardware.

**Stage gating:** Stage 1 = pipeline proof with Abubakar's own voice (model `abubakar_test_e8_s112.pth`). Stage 2 = a model of another speaker ("Kashif", files like `New_K_Audio/`). Analyzing Stage 2 audio is allowed; do **not** convert/preprocess/train it until the user explicitly starts Stage 2 (requires the speaker's consent).

## Layout (non-obvious parts)

- `rvc/` — upstream clone (pinned commit in `rvc_commit.txt`). Treat as vendored; wrapper code lives outside it.
- `venv/` — Python 3.12 venv (torch 2.4.1+cpu) from `requirements-cpu-local.txt` (upstream `requirments_cpu_py312.txt` with the PKU/NJU mirror lines removed). System Python is untouched.
- `scripts/`, `audio/`, `tests/`, `start.sh`, `stop.sh` — project code. `dataset/` recordings, `logs/` all run logs, `tests/out/` generated audio.

## Commands

Always use `~/rvc-realtime/venv/bin/python`. Upstream modules must run **from `rvc/`**.

```bash
# virtual mic (idempotent; module IDs kept in audio/.modules)
audio/setup_virtual_mic.sh          audio/teardown_virtual_mic.sh
./start.sh                          ./stop.sh          # live GUI + router (+ virtual mic)

# record from the built-in mic (prints duration/RMS/peak/silence/clipping)
tests/record_voice.sh SECONDS OUT.wav

# offline conversion (from rvc/)
../venv/bin/python -m infer.cli --model assets/weights/abubakar_test_e8_s112.pth \
  --input IN.wav --output OUT.wav --f0-method rmvpe --index-rate 0 --format wav --overwrite

# end-to-end proof: convert → play into rvc_out → capture rvc_mic → compare (KEEP_MIC=1, INDEX=path optional)
tests/playback_test.sh MODEL.pth INPUT.wav [OUT_DIR]
tests/acceptance.sh PHRASE.wav PLAYBACK_DIR        # checks A–K; F/H need Chrome capturing rvc_mic; SKIP_K=1 during calls
venv/bin/python tests/compare_audio.py A.wav B.wav  # envelope corr / lag / waveform corr / MFCC distance
venv/bin/python tests/analyze_dataset.py FILE_OR_DIR  # training-suitability report

# training (EXP, EPOCHS, F0 env vars); saves assets/weights/<EXP>_e<N>_s<step>.pth every epoch
F0=rmvpe bash scripts/train_test_model.sh prep
EPOCHS=8 bash scripts/train_test_model.sh train
bash scripts/train_test_model.sh index

# CPU speed (from rvc/): block-level realtime benchmark and per-stage profiler
../venv/bin/python ../tests/offline_benchmark.py PTH IN.wav OUT.wav [f0] [block_s] [extra_s]
PROFILE_SET=quick ../venv/bin/python ../tests/profile_rvc.py PTH IN.wav

# GUI preset → rvc/configs/config.json (upstream Windows sample backed up as config.upstream-sample.json)
venv/bin/python scripts/write_gui_config.py PTH --f0 pm --block 1.0 --extra 0.25 --threshold -50
```

Browser mic test page: serve `tests/` with `venv/bin/python -m http.server 8765 --bind 127.0.0.1` (getUserMedia needs localhost) and open `http://localhost:8765/mic_test.html`.

## Architecture

**Audio routing.** `setup_virtual_mic.sh` loads pipewire-pulse `module-null-sink` `rvc_out` ("RVC Output (internal)") and `module-remap-source` `rvc_mic` over `rvc_out.monitor`, then restores the default sink/source if they moved. Apps select `rvc_mic`; anything played into `rvc_out` appears there and never reaches the speakers. Devices are runtime-only (gone after reboot/teardown).

**Live GUI.** `rvc/realtime_gui.py` (FreeSimpleGUI/tkinter, `sounddevice` duplex stream) uses ALSA device `pipewire` for both input and output — PortAudio can't open the hardware directly while PipeWire owns it, and the ALSA pipewire plugin's `NODE` applies to capture *and* playback, so per-direction targeting is impossible. `start.sh` therefore runs a router loop that moves any sink-input owned by the GUI PID into `rvc_out` (each Start click creates a new stream that would otherwise land on the speakers → feedback).

**Training data flow** (`scripts/train_test_model.sh`, all under `rvc/logs/<EXP>/`): `train.preprocess` slices `dataset/abubakar/` (40 kHz, 3.7 s, slicer threshold −42 dB) → `0_gt_wavs`, `1_16k_wavs` → `train.dataset.extract_f0` (cpu, rmvpe) → `2a_f0`, `2b-f0nsf` → `train.dataset.extract_hubert_feature` → `3_feature768` → `scripts/make_filelist.py` writes `filelist.txt` (+2 lines from `rvc/logs/mute/`, extracted from upstream `mute.zip`) and `config.json` copied from `configs/v1/40k.json` (upstream uses v1 config for all 40k models) → `train.train` fine-tunes from `assets/pretrained_v2/f0G40k.pth`/`f0D40k.pth` (full checkpoints `G_2333333.pth`/`D_2333333.pth`, ~1.3 GB, in the exp dir) → `train.train_index` → `added_IVF*.index` (symlinked into `assets/indices/`).

## Gotchas discovered in this environment

- **Run upstream scripts as modules** (`python -m train.preprocess`, `-m infer.cli`) from `rvc/`. Launching `train/*.py` as files puts `rvc/train/` first on `sys.path`, so `rvc/train/train.py` shadows the `train` package (circular import) and `infer` isn't importable.
- **`configs/config.py` parses `sys.argv` at import** with webui flags; standalone scripts must reset `sys.argv = sys.argv[:1]` before importing it and add `os.getcwd()` to `sys.path` (see `tests/offline_benchmark.py`).
- `rvc/assets/weights/` and `assets/indices/` don't exist in a fresh clone; `train/process_ckpt.py` swallows the save error and prints a traceback instead of raising.
- pipewire-pulse module args cut values at the first space: descriptions need nested quotes, e.g. `"sink_properties=\"device.description='RVC Output (internal)'\""`.
- Verify by outputs, not exit codes: pipelines (`| tee`, `| grep`) and upstream try/except have produced exit 0 on total failure. Check files, sizes, log lines, audio metrics.
- `pkill -f`/`pgrep -f` patterns match the Bash tool's own command text; use `pgrep -x`, PIDs, or the `[x]yz` bracket trick.
- Upstream realtime inference logs its per-stage timings only through an unconfigured logger — use `tests/profile_rvc.py` for breakdowns.
- Training on this CPU: ~5 min/epoch for 52 slices (14 steps/epoch), worker RSS ≈7 GB; memory was tight with Chrome/VS Code open. Use AC power + `powerprofilesctl set performance`; original profile was `balanced` (restore after work). Original built-in mic volume was 0.45.
- The built-in mic is quiet and noisy (training take SNR ≈15 dB, 90 Hz high-pass applied). `compare_audio.py` timbre distance: raw vs Abubakar model ≈47–57, raw vs generic pretrain ≈90, virtual-mic capture vs converted file ≈1.
- Benchmark-only inference files built from the pretrains live in `tests/bench_models/` — never put them in `assets/weights/` (the GUI and CLI list that folder as voice models).
