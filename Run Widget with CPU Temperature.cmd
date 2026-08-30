@echo off
setlocal
set "NEON_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
"%NEON_PS%" -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0Verify Integrity.ps1"
if errorlevel 1 (
  echo NeonPulse integrity verification failed. Nothing was started.
  pause
  exit /b 1
)
"%NEON_PS%" -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0Start Temperature Helper.ps1"
if errorlevel 1 (
  echo The optional CPU temperature helper could not be started.
  pause
  exit /b 1
)
"%NEON_PS%" -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File "%~dp0Start Widget.ps1"
