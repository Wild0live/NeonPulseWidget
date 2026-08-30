# Building and verifying NeonPulseWidget

## Requirements

- Windows 10 or Windows 11, x64
- Windows PowerShell 5.1
- Git configured to honor the repository's `.gitattributes`

No SDK is required to run the checked-in release. The five DLL dependencies are
checked in because the optional CPU sensor helper must work on a clean Windows
machine without compiling code. Their exact versions, source locations, licenses,
and SHA-256 hashes are recorded in `dependencies.lock.json`.

## Verify a clean clone

```powershell
git clone <repository-url> NeonPulseWidget
cd NeonPulseWidget
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\tools\Test-Repository.ps1
```

The test performs these checks:

1. Parses every PowerShell file without executing the widget UI.
2. Verifies the packaged files against `SHA256SUMS.txt`.
3. Verifies every bundled DLL against `dependencies.lock.json`.
4. Rejects committed absolute Windows user-profile paths.
5. Builds the release twice and requires identical ZIP hashes.

## Build a release ZIP

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\tools\Build-Release.ps1
```

The output is `dist\NeonPulseWidget.zip`. Files are stored without runtime-specific
compression and are added in a stable order with a fixed ZIP timestamp. The
canonical builder intentionally requires the built-in Windows PowerShell 5.1;
using one runtime avoids ZIP metadata differences between .NET Framework and
modern .NET.

## Hardware-dependent behavior

The widget is designed to degrade safely when a sensor is unavailable:

- Core CPU, RAM, disk, network, and audio metrics use Windows APIs.
- GPU dedicated-memory counters use the detected Windows adapter LUID.
- NVIDIA temperature and exact memory capacity use a signed System32
  `nvidia-smi.exe` when available. Other GPU vendors may show `N/A` temperature.
- CPU temperature is optional because Windows has no universal unprivileged CPU
  temperature API. It requires the separately installed signed PawnIO package and
  explicit elevation of the read-only helper.

Run the ordinary launcher first. Hardware-specific optional features must never
prevent the widget from starting.
