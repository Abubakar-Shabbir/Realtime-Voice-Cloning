# Watches rvc/assets/weights/ for new <Exp>_eN_sM.pth checkpoints while training runs,
# and converts a fixed reference clip with each one as soon as it appears, so training
# quality can be reviewed epoch by epoch instead of only at the end.
param(
    [string]$Exp = "kashif_test",
    [string]$F0 = "rmvpe",
    [int]$Epochs = 25
)
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
$Root = (Get-Location).Path
$R = Join-Path $Root "rvc"
$PY = Join-Path $Root "venv\Scripts\python.exe"
$Checks = Join-Path $Root "tests\out\${Exp}_epoch_checks"
$Ref = Join-Path $Root "tests\out\${Exp}_ref_phrase.wav"
$Log = Join-Path $Root "logs\${Exp}_epoch_checks.log"
New-Item -ItemType Directory -Force -Path $Checks | Out-Null

$done = 0
while ($done -lt $Epochs) {
    $weightFiles = Get-ChildItem "$R\assets\weights\${Exp}_e*.pth" -ErrorAction SilentlyContinue
    foreach ($f in $weightFiles) {
        $base = $f.BaseName
        $out = Join-Path $Checks "$base.wav"
        if (-not (Test-Path $out)) {
            Push-Location $R
            & $PY -m infer.cli --model "assets/weights/$base.pth" --input $Ref --output $out --f0-method $F0 --index-rate 0 --format wav --overwrite *>> $Log
            Pop-Location
            "$(Get-Date -Format 'HH:mm:ss') checked $base -> tests\out\${Exp}_epoch_checks\$base.wav" | Add-Content $Log
        }
    }
    $done = (Get-ChildItem $Checks -Filter "${Exp}_e*.wav" -ErrorAction SilentlyContinue | Measure-Object).Count
    Start-Sleep -Seconds 15
}
"$(Get-Date -Format 'HH:mm:ss') all $Epochs epoch checks done" | Add-Content $Log
