#!/usr/bin/env bash
# Usage: train_test_model.sh prep|train|index
#   EXP (default abubakar_test), EPOCHS (default 30), F0 (rmvpe|pm, default rmvpe)
#   DATA_NAME (default abubakar) selects dataset/<DATA_NAME>/ as the prep source
set -euo pipefail
EXP="${EXP:-abubakar_test}"
EPOCHS="${EPOCHS:-30}"
F0="${F0:-rmvpe}"
DATA_NAME="${DATA_NAME:-abubakar}"
ROOT="$HOME/rvc-realtime"
R="$ROOT/rvc"
PY="$ROOT/venv/bin/python"
DATA="$ROOT/dataset/$DATA_NAME"
NP=4

cd "$R"
if [ -f .env ]; then set -a; . ./.env; set +a; fi
# Run upstream scripts as modules (-m) from the repo root: launched as files, rvc/train/ is
# searched first and rvc/train/train.py shadows the `train` package (circular import).
export PYTHONPATH="$R${PYTHONPATH:+:$PYTHONPATH}"
export RVC_CUDA_GRAPH=0
mkdir -p "logs/$EXP" assets/weights assets/indices

stage() { echo; echo "=== $1  $(date +%T)"; }

case "${1:?prep|train|index}" in
  prep)
    stage "preprocess (slice + resample)"
    "$PY" -m train.preprocess "$DATA" 40000 "$NP" "$R/logs/$EXP" False 3.7
    echo "gt_wavs=$(ls "logs/$EXP/0_gt_wavs" | wc -l) 16k_wavs=$(ls "logs/$EXP/1_16k_wavs" | wc -l)"

    stage "f0 extraction ($F0, cpu)"
    "$PY" -m train.dataset.extract_f0 cpu "$R/logs/$EXP" "$NP" "$F0"
    echo "f0=$(ls "logs/$EXP/2a_f0" | wc -l) f0nsf=$(ls "logs/$EXP/2b-f0nsf" | wc -l)"

    stage "hubert features (cpu)"
    "$PY" -m train.dataset.extract_hubert_feature cpu 1 0 "$R/logs/$EXP" v2 False
    echo "features=$(ls "logs/$EXP/3_feature768" | wc -l)"

    stage "filelist + config"
    "$PY" "$ROOT/scripts/make_filelist.py" "$EXP"
    ;;
  train)
    stage "train ($EPOCHS epochs, cpu, save weights every epoch)"
    "$PY" -m train.train -e "$EXP" -sr 40k -f0 1 -bs 4 -te "$EPOCHS" -se 1 \
      -pg assets/pretrained_v2/f0G40k.pth -pd assets/pretrained_v2/f0D40k.pth \
      -l 1 -c 0 -sw 1 -v v2
    ;;
  index)
    stage "faiss index"
    "$PY" -m train.train_index "$EXP" v2 "${outside_index_root:-assets/indices}" "$NP" single
    ;;
esac
stage "done"
