$ErrorActionPreference='Stop'
$verified=& (Join-Path $PSScriptRoot 'Verify Integrity.ps1') -ReturnResult -Quiet
if(-not $verified){throw 'Release integrity verification failed; the sensor helper was not started.'}
$driver=Get-CimInstance Win32_SystemDriver -Filter "Name='PawnIO'" -ErrorAction SilentlyContinue
if(-not $driver){throw 'PawnIO is not installed. Install the signed namazso.PawnIO package first.'}
$powerShellPath=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$helperPath=Join-Path $PSScriptRoot 'Temperature Helper.ps1'
$arguments='-NoLogo -NoProfile -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File "{0}"' -f $helperPath
Start-Process -FilePath $powerShellPath -ArgumentList $arguments -WorkingDirectory $PSScriptRoot -WindowStyle Hidden -Verb RunAs
