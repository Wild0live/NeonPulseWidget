$ErrorActionPreference = 'Stop'
$verifyPath = Join-Path $PSScriptRoot 'Verify Integrity.ps1'
$widgetPath = Join-Path $PSScriptRoot 'NeonPulseWidget.ps1'
$powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

$verified = & $verifyPath -ReturnResult -Quiet
if (-not $verified) { throw 'NeonPulse integrity verification failed. The widget was not started.' }

$arguments = '-NoLogo -NoProfile -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File "{0}"' -f $widgetPath
Start-Process -FilePath $powerShellPath -ArgumentList $arguments -WorkingDirectory $PSScriptRoot -WindowStyle Hidden
