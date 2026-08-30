$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))

$parseErrors = @()
Get-ChildItem -LiteralPath $repoRoot -Filter '*.ps1' -File -Recurse |
    Where-Object { $_.FullName -notlike "*$([IO.Path]::DirectorySeparatorChar).git$([IO.Path]::DirectorySeparatorChar)*" } |
    ForEach-Object {
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
        if ($errors) { $parseErrors += $errors }
    }
if ($parseErrors.Count) { throw "PowerShell parsing failed: $($parseErrors[0].Message)" }

$verified = & (Join-Path $repoRoot 'Verify Integrity.ps1') -ReturnResult -Quiet
if (-not $verified) { throw 'Package integrity verification failed.' }

$lock = Get-Content -LiteralPath (Join-Path $repoRoot 'dependencies.lock.json') -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($dependency in $lock.dependencies) {
    $path = Join-Path $repoRoot $dependency.file
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Locked dependency is missing: $($dependency.file)" }
    $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    if ($actual -ne $dependency.sha256) { throw "Locked dependency hash mismatch: $($dependency.file)" }
}

$machinePathPattern = 'C:' + '\\Users\\' + '[^\\]+'
$machinePathMatches = @(Get-ChildItem -LiteralPath $repoRoot -File -Recurse |
    Where-Object { $_.Extension -in @('.ps1','.cmd','.txt','.md','.json','.yml','.yaml') } |
    Select-String -Pattern $machinePathPattern -ErrorAction Stop)
if ($machinePathMatches.Count) { throw "Machine-specific user path found: $($machinePathMatches[0].Path):$($machinePathMatches[0].LineNumber)" }

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('NeonPulseWidget-Test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $first = & (Join-Path $PSScriptRoot 'Build-Release.ps1') -OutputPath (Join-Path $testRoot 'first.zip')
    $second = & (Join-Path $PSScriptRoot 'Build-Release.ps1') -OutputPath (Join-Path $testRoot 'second.zip')
    if ($first.SHA256 -ne $second.SHA256) { throw 'Release build is not deterministic.' }
    $extracted = Join-Path $testRoot 'extracted'
    Expand-Archive -LiteralPath $first.Path -DestinationPath $extracted
    $extractedVerified = & (Join-Path $extracted 'Verify Integrity.ps1') -ReturnResult -Quiet
    if (-not $extractedVerified) { throw 'The extracted release failed standalone integrity verification.' }
    Write-Host "Repository verification passed. Deterministic release SHA256: $($first.SHA256)" -ForegroundColor Green
} finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
