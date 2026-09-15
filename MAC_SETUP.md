# Mac setup guide

This repo was built and tested on Windows (CPU-only). The goal of running it on a Mac
is to compare speed — see `README.md` / `CLAUDE.md` for the full background: on the
Windows test machine, live real-time conversion misses its timing budget on ~15% of
audio chunks even at the best settings found. A Mac (especially Apple Silicon) may
handle this better.

## 1. Prerequisites

```bash
brew install python@3.12 ffmpeg git-lfs
git lfs install
```

## 2. Clone (with the model files)

```bash
git clone https://github.com/Abubakar-Shabbir/Realtime-Voice-Cloning.git
cd Realtime-Voice-Cloning
git lfs pull   # only needed if the clone didn't pull LFS files automatically
```

## 3. Python environment

```bash
python3.12 -m venv venv
source venv/bin/activate
pip install --extra-index-url https://download.pytorch.org/whl/cpu -r requirements-cpu-local.txt
```

## 4. Try it — offline conversion (the reliable path)

```bash
cd rvc
../venv/bin/python -m infer.cli \
  --model assets/weights/kashif_test_e21_s651.pth \
  --input /path/to/any/short/recording.wav \
  --output ../out.wav \
  --f0-method rmvpe --index-rate 0 --format wav --overwrite
```
Swap `kashif_test_e21_s651.pth` for any other included epoch to compare quality.
Listen to `out.wav` — this path has no chunking/real-time constraint, so it's always
clean regardless of hardware speed.

## 5. Speed comparison (the actual point of testing on Mac)

```bash
../venv/bin/python ../tests/offline_benchmark.py \
  assets/weights/kashif_test_e21_s651.pth /path/to/recording.wav ../bench_out.wav pm 1.0 0.1
```
`pm 1.0 0.1` matches the best settings found on Windows (F0 method, block_time, extra_time)
so the comparison is apples-to-apples. It prints how long a 1.0s block takes to process —
compare against the Windows numbers: mean ~0.9s, worst-case up to ~1.5-2.0s (i.e. it
sometimes took *longer than the audio itself*, which is what caused the live cutting).
If the Mac number stays consistently under 1.0s, live mode should actually be usable there.

## 6. Live mode (optional, only if the speed test looks promising)

`rvc/realtime_gui.py` needs a virtual audio device to feed a call, same idea as
VB-CABLE on Windows — on Mac, use **BlackHole** (`brew install blackhole-2ch`),
then set it as the output device in the GUI and as the mic in Meet/Zoom/etc.
Device names in `rvc/configs/config.json` (`sg_input_device`, `sg_output_device`,
`sg_hostapi`) are machine-specific — they'll need to be re-set to whatever this
Mac's `sounddevice` reports, they won't match the Windows config as-is.

## Notes
- Only Kashif's voice model is included here — that's the specific consent scope
  this repo was shared under. Don't retrain or extend it to other people's voices
  without their own separate consent.
- `torch-directml` / DirectML is Windows-only and is skipped automatically on Mac
  by `requirements-cpu-local.txt` (already handled by platform markers).
