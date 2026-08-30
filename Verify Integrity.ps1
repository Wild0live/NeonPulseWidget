param([switch]$ReturnResult,[switch]$Quiet)

$ErrorActionPreference = 'Stop'

function Get-Sha256([string]$path) {
    $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '') }
        finally { $sha.Dispose() }
    } finally { $stream.Dispose() }
}

function Complete-Verification([bool]$passed,[string]$message) {
    if ($passed) {
        if (-not $Quiet) { Write-Host $message -ForegroundColor Green }
        if ($ReturnResult) { return $true }
        exit 0
    }
    [Console]::Error.WriteLine($message)
    if ($ReturnResult) { return $false }
    exit 1
}

try {
    $root = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $manifestPath = Join-Path $PSScriptRoot 'SHA256SUMS.txt'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'SHA256SUMS.txt is missing.' }

    $entries = New-Object 'Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($line in Get-Content -LiteralPath $manifestPath -Encoding UTF8) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith('#')) { continue }
        if ($line -notmatch '^([0-9A-Fa-f]{64}) \*(.+)$') { throw "Invalid checksum line: $line" }
        $relative = $Matches[2].Replace('/', [IO.Path]::DirectorySeparatorChar)
        if ([IO.Path]::IsPathRooted($relative)) { throw "Rooted paths are not permitted in the manifest: $relative" }
        $fullPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot $relative))
        if (-not $fullPath.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw "Manifest path escapes the widget folder: $relative" }
        if ($entries.ContainsKey($relative)) { throw "Duplicate manifest entry: $relative" }
        $entries.Add($relative, $Matches[1].ToUpperInvariant())
    }
    if ($entries.Count -eq 0) { throw 'The checksum manifest is empty.' }

    foreach ($entry in $entries.GetEnumerator()) {
        $path = Join-Path $PSScriptRoot $entry.Key
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required file is missing: $($entry.Key)" }
        $actual = Get-Sha256 $path
        if ($actual -ne $entry.Value) { throw "Checksum mismatch: $($entry.Key)" }
    }

    $executableExtensions = @(
        '.ps1','.psm1','.psd1','.cmd','.bat','.exe','.com','.scr','.msi','.msp',
        '.dll','.sys','.cpl','.ocx','.vbs','.vbe','.js','.jse','.wsf','.wsh',
        '.hta','.lnk','.url','.reg'
    )
    foreach ($file in Get-ChildItem -LiteralPath $PSScriptRoot -File) {
        if ($file.Extension.ToLowerInvariant() -notin $executableExtensions) { continue }
        if (-not $entries.ContainsKey($file.Name)) { throw "Unexpected executable or code file: $($file.Name)" }
    }
    Complete-Verification $true "NeonPulse integrity verified: $($entries.Count) files match SHA256SUMS.txt."
} catch {
    Complete-Verification $false ("NeonPulse integrity verification failed: {0}" -f $_.Exception.Message)
}
