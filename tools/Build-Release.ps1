param(
    [string]$OutputPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist\NeonPulseWidget.zip')
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5) {
    throw 'Deterministic releases must be built with Windows PowerShell 5.1 (powershell.exe), not pwsh.'
}
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$verifyPath = Join-Path $repoRoot 'Verify Integrity.ps1'

$verified = & $verifyPath -ReturnResult -Quiet
if (-not $verified) { throw 'Release integrity verification failed.' }

$manifestPath = Join-Path $repoRoot 'SHA256SUMS.txt'
$releaseFiles = New-Object 'Collections.Generic.List[string]'
foreach ($line in Get-Content -LiteralPath $manifestPath -Encoding UTF8) {
    if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith('#')) { continue }
    if ($line -notmatch '^[0-9A-Fa-f]{64} \*(.+)$') { throw "Invalid manifest line: $line" }
    $releaseFiles.Add($Matches[1])
}
$releaseFiles.Add('SHA256SUMS.txt')
$releaseFiles.Add('RELEASE-FINGERPRINT.txt')

$fullOutput = [IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Parent $fullOutput
if (-not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory | Out-Null
}
$temporaryOutput = "$fullOutput.partial"
if (Test-Path -LiteralPath $temporaryOutput) { Remove-Item -LiteralPath $temporaryOutput -Force }

Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$fileStream = [IO.File]::Open($temporaryOutput, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
    $archive = [IO.Compression.ZipArchive]::new($fileStream, [IO.Compression.ZipArchiveMode]::Create, $false)
    try {
        $fixedTimestamp = [DateTimeOffset]::new(2000, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
        foreach ($relativePath in @($releaseFiles | Sort-Object -Unique)) {
            $sourcePath = [IO.Path]::GetFullPath((Join-Path $repoRoot $relativePath))
            if (-not $sourcePath.StartsWith($repoRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Release path escapes the repository: $relativePath"
            }
            if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw "Release file is missing: $relativePath" }
            $entryName = $relativePath.Replace([IO.Path]::DirectorySeparatorChar, '/')
            # Store entries without runtime-dependent Deflate output.
            $entry = $archive.CreateEntry($entryName, [IO.Compression.CompressionLevel]::NoCompression)
            $entry.LastWriteTime = $fixedTimestamp
            $input = [IO.File]::Open($sourcePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            try {
                $output = $entry.Open()
                try { $input.CopyTo($output) } finally { $output.Dispose() }
            } finally { $input.Dispose() }
        }
    } finally { $archive.Dispose() }
} finally { $fileStream.Dispose() }

Move-Item -LiteralPath $temporaryOutput -Destination $fullOutput -Force
$hash = (Get-FileHash -LiteralPath $fullOutput -Algorithm SHA256).Hash
[pscustomobject]@{ Path = $fullOutput; SHA256 = $hash; Files = $releaseFiles.Count }
