$ErrorActionPreference='Stop'
$diagnosticDirectory=Join-Path $env:LOCALAPPDATA 'NeonPulseWidget'
$diagnosticPath=Join-Path $diagnosticDirectory 'sensor-helper-error.txt'
trap{
    try{[void][IO.Directory]::CreateDirectory($diagnosticDirectory);[IO.File]::WriteAllText($diagnosticPath,$_.Exception.ToString(),[Text.UTF8Encoding]::new($false))}catch{}
    exit 1
}
if(Test-Path -LiteralPath $diagnosticPath){Remove-Item -LiteralPath $diagnosticPath -Force -ErrorAction SilentlyContinue}

$verified=& (Join-Path $PSScriptRoot 'Verify Integrity.ps1') -ReturnResult -Quiet
if(-not $verified){throw 'Release integrity verification failed; the sensor helper was not started.'}

$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$principal=New-Object Security.Principal.WindowsPrincipal($identity)
if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'The PawnIO sensor helper requires administrator access.'}

$expectedHashes=@{
    'LibreHardwareMonitorLib.dll'='F61C3A1B2FBC23B8A628711082BB571DBA22EB849283FA4B9FB0215B4FA0F6F9'
    'System.Memory.dll'='D5E8E4866F9CFA66F7765660F84B210198893E55335487AFE5EBDA342C0E913D'
    'System.Runtime.CompilerServices.Unsafe.dll'='08CBD7278B66F1E68425A82D4B97181A4130D93E3DD91831407ABA7212CCDACF'
    'System.Buffers.dll'='2D78D770C9CB997199154AE8C018B9F1D1EFBC86729F7264DDE6DBAD2A12CAC3'
    'System.Numerics.Vectors.dll'='20C2FA81B8C70D651099D762954F285FD4F942E63B2D7217C145DAB8D4B2F4C9'
}

function Get-Sha256([string]$path){
    $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{$sha=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','')}finally{$sha.Dispose()}}finally{$stream.Dispose()}
}

foreach($entry in $expectedHashes.GetEnumerator()){
    $path=Join-Path $PSScriptRoot $entry.Key
    if(-not(Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Sha256 $path) -ne $entry.Value){throw "Sensor component integrity failure: $($entry.Key)"}
}

$createdNew=$false
$mutex=New-Object Threading.Mutex($true,'NeonPulseWidget.TemperatureHelper',[ref]$createdNew)
if(-not $createdNew){$mutex.Dispose();return}

$configDir=Join-Path $env:LOCALAPPDATA 'NeonPulseWidget'
$cachePath=Join-Path $configDir 'cpu-sensor.json'
$temporaryPath=Join-Path $configDir ('cpu-sensor.'+$PID+'.tmp')
$backupPath=Join-Path $configDir ('cpu-sensor.'+$PID+'.bak')
$heartbeatPath=Join-Path $configDir 'sensor-heartbeat.txt'
[void][IO.Directory]::CreateDirectory($configDir)

function Publish-SensorSample([string]$json){
    [IO.File]::WriteAllText($temporaryPath,$json,[Text.UTF8Encoding]::new($false))
    for($attempt=0;$attempt -lt 8;$attempt++){
        try{
            if(Test-Path -LiteralPath $cachePath){
                [IO.File]::Replace($temporaryPath,$cachePath,$backupPath,$true)
                if(Test-Path -LiteralPath $backupPath){Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue}
            }else{[IO.File]::Move($temporaryPath,$cachePath)}
            return
        }catch [IO.IOException]{
            if($attempt -ge 7){throw}
            Start-Sleep -Milliseconds ([math]::Min(400,25*[math]::Pow(2,$attempt)))
            if(-not(Test-Path -LiteralPath $temporaryPath)){[IO.File]::WriteAllText($temporaryPath,$json,[Text.UTF8Encoding]::new($false))}
        }
    }
}

$computer=$null
try{
    foreach($name in @('System.Buffers.dll','System.Runtime.CompilerServices.Unsafe.dll','System.Numerics.Vectors.dll','System.Memory.dll','LibreHardwareMonitorLib.dll')){
        [Reflection.Assembly]::Load([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot $name)))|Out-Null
    }
    $computer=New-Object LibreHardwareMonitor.Hardware.Computer
    $computer.IsCpuEnabled=$true
    $computer.Open()
    $started=[DateTime]::UtcNow
    $heartbeatSeen=$false
    while($true){
        $temperature=0.0;$packagePower=0.0
        foreach($hardware in $computer.Hardware){
            if($hardware.HardwareType.ToString() -ne 'Cpu'){continue}
            $hardware.Update()
            foreach($sub in $hardware.SubHardware){$sub.Update()}
            $sensors=@($hardware.Sensors)+@($hardware.SubHardware|ForEach-Object Sensors)
            $temp=$sensors|Where-Object{$_.SensorType.ToString() -eq 'Temperature' -and $_.Value -gt 0 -and $_.Value -lt 110 -and $_.Name -match 'Tctl|Tdie|Package|Core Average'}|Select-Object -First 1
            if(-not $temp){$temp=$sensors|Where-Object{$_.SensorType.ToString() -eq 'Temperature' -and $_.Value -gt 0 -and $_.Value -lt 110}|Select-Object -First 1}
            $power=$sensors|Where-Object{$_.SensorType.ToString() -eq 'Power' -and $_.Value -gt 0 -and $_.Value -lt 300 -and $_.Name -match '^Package$|CPU Package'}|Select-Object -First 1
            if($temp){$temperature=[double]$temp.Value};if($power){$packagePower=[double]$power.Value}
        }
        if($temperature -gt 0){
            $json=[ordered]@{Provider='PawnIO/LibreHardwareMonitor';TimestampUtc=[DateTime]::UtcNow.ToString('o');CpuTemperatureC=[math]::Round($temperature,1);CpuPackagePowerW=[math]::Round($packagePower,1);SourceCommit='adf717d75a17f107629f63755f0e08b992e43ca9'}|ConvertTo-Json -Compress
            Publish-SensorSample $json
        }
        if(Test-Path -LiteralPath $heartbeatPath){
            $age=([DateTime]::UtcNow-(Get-Item -LiteralPath $heartbeatPath).LastWriteTimeUtc).TotalSeconds
            if($age -le 15){$heartbeatSeen=$true}elseif($heartbeatSeen){break}
        }elseif($heartbeatSeen){break}
        if(-not $heartbeatSeen -and ([DateTime]::UtcNow-$started).TotalSeconds -gt 30){break}
        Start-Sleep -Seconds 1
    }
}finally{
    if($computer){try{$computer.Close()}catch{}}
    if(Test-Path -LiteralPath $temporaryPath){Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue}
    if(Test-Path -LiteralPath $backupPath){Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue}
    $mutex.ReleaseMutex();$mutex.Dispose()
}
