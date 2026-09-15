# Offline (record -> convert -> play) Meet test - the proven-clean path, since live
# streaming conversion hits a hard CPU ceiling on this machine (~15% chunk deadline
# misses even at the best-tuned block_time). This has zero chunking/SOLA, so no
# real-time glitching - same clean quality as every offline infer.cli test so far.
#
# Usage: .\scripts\offline_meet_test.ps1 -Seconds 10 -Model kashif_test_e8_s248.pth -F0 rmvpe
param(
    [int]$Seconds = 10,
    [string]$Model = "kashif_test_e8_s248.pth",
    [string]$F0 = "rmvpe"
)
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
$reg = [char]0x00AE
$micDevice = "Microphone Array (Intel$reg Smart Sound Technology for Digital Microphones)"
$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$raw = "tests\out\offline_${ts}_raw.wav"
$conv = "tests\out\offline_${ts}_converted.wav"
$root = (Get-Location).Path

Write-Output "Recording $Seconds s - speak now..."
ffmpeg -y -v warning -f dshow -i "audio=$micDevice" -t $Seconds -ac 1 -ar 44100 $raw

if (-not (Test-Path $raw)) {
    Write-Output "ERROR: recording failed, no raw file produced"
    exit 1
}

Write-Output "Converting with $Model ($F0)..."
Push-Location rvc
& "$root\venv\Scripts\python.exe" -m infer.cli --model "assets/weights/$Model" --input "$root\$raw" --output "$root\$conv" `
  --f0-method $F0 --index-rate 0 --format wav --overwrite
Pop-Location

if (-not (Test-Path $conv)) {
    Write-Output "ERROR: conversion failed, no converted file produced"
    exit 1
}

Write-Output "Playing converted audio into CABLE Input (Meet should hear this as its mic)..."
& "$root\venv\Scripts\python.exe" -c "
import sounddevice as sd, soundfile as sf
data, sr = sf.read(r'$root\$conv', dtype='float32')
dev = next(d['index'] for d in sd.query_devices() if 'CABLE Input' in d['name'] and d['hostapi']==0)
sd.play(data, sr, device=dev)
sd.wait()
print('done - played to CABLE Input device', dev)
"
Write-Output "raw: $raw"
Write-Output "converted: $conv"
