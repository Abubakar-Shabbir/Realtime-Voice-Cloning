@echo off
rem Launches the live RVC voice-conversion GUI with GPU acceleration (DirectML).
rem Speak into your mic; converted audio is routed to "CABLE Input (VB-Audio Virtual Cable)".
rem In your call app (Zoom/Discord/etc), select "CABLE Output (VB-Audio Virtual Cable)" as the microphone.
set "SCRIPT_DIR=%~dp0"
cd /d "%SCRIPT_DIR%rvc"
"%SCRIPT_DIR%venv\Scripts\python.exe" realtime_gui.py --dml
pause
