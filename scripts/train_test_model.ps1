# Windows PowerShell equivalent of scripts/train_test_model.sh (upstream RVC training,
# run natively on this machine instead of the Linux box).
# Usage: .\scripts\train_test_model.ps1 -Stage prep|train|index [-Exp NAME] [-DataName NAME] [-F0 rmvpe|pm] [-Epochs N]
param(
    [Parameter(Mandatory=$true)][ValidateSet("prep","train","index")][string]$Stage,
    [string]$Exp = "kashif_test",
    [string]$DataName = "kashif",
    [string]$F0 = "rmvpe",
    [int]$Epochs = 25,
    [int]$NP = 4
)

$ErrorActionPreference = "Stop"
$Root = (Get-Location).Path
$R = Join-Path $Root "rvc"
$PY = Join-Path $Root "venv\Scripts\python.exe"
$Data = Join-Path $Root "dataset\$DataName"
$Logs = Join-Path $Root "logs"
New-Item -ItemType Directory -Force -Path $Logs, "$R\logs\$Exp", "$R\assets\weights", "$R\assets\indices" | Out-Null

Set-Location $R
$env:PYTHONPATH = $R
$env:RVC_CUDA_GRAPH = "0"

function Stage-Log($msg) { Write-Output ""; Write-Output "=== $msg  $(Get-Date -Format 'HH:mm:ss')" }

switch ($Stage) {
    "prep" {
        Stage-Log "preprocess (slice + resample)"
        & $PY -m train.preprocess "$Data" 40000 $NP "$R\logs\$Exp" False 3.7
        if ($LASTEXITCODE -ne 0) { throw "preprocess failed ($LASTEXITCODE)" }
        Write-Output ("gt_wavs=" + (Get-ChildItem "$R\logs\$Exp\0_gt_wavs" -Filter *.wav | Measure-Object).Count)

        Stage-Log "f0 extraction ($F0, cpu)"
        & $PY -m train.dataset.extract_f0 cpu "$R\logs\$Exp" $NP $F0
        if ($LASTEXITCODE -ne 0) { throw "extract_f0 failed ($LASTEXITCODE)" }
        Write-Output ("f0=" + (Get-ChildItem "$R\logs\$Exp\2a_f0" | Measure-Object).Count)

        Stage-Log "hubert features (cpu)"
        & $PY -m train.dataset.extract_hubert_feature cpu 1 0 "$R\logs\$Exp" v2 False
        if ($LASTEXITCODE -ne 0) { throw "extract_hubert_feature failed ($LASTEXITCODE)" }
        Write-Output ("features=" + (Get-ChildItem "$R\logs\$Exp\3_feature768" | Measure-Object).Count)

        Stage-Log "filelist + config"
        & $PY "$Root\scripts\make_filelist.py" $Exp
        if ($LASTEXITCODE -ne 0) { throw "make_filelist failed ($LASTEXITCODE)" }
    }
    "train" {
        Stage-Log "train ($Epochs epochs, cpu, save weights every epoch)"
        & $PY -m train.train -e $Exp -sr 40k -f0 1 -bs 4 -te $Epochs -se 1 `
            -pg assets/pretrained_v2/f0G40k.pth -pd assets/pretrained_v2/f0D40k.pth `
            -l 1 -c 0 -sw 1 -v v2
        if ($LASTEXITCODE -ne 0) { throw "train failed ($LASTEXITCODE)" }
    }
    "index" {
        Stage-Log "faiss index"
        & $PY -m train.train_index $Exp v2 assets/indices $NP single
        if ($LASTEXITCODE -ne 0) { throw "train_index failed ($LASTEXITCODE)" }
    }
}
Stage-Log "done"
