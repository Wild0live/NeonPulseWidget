# NeonPulseWidget

NeonPulseWidget is a resizable Rainmeter-inspired Windows desktop monitor built
with Windows PowerShell 5.1 and WPF. It runs as a normal user, makes no network
requests, and needs no installer or .NET SDK.

## Compatibility

- Windows 10 or Windows 11, x64
- Windows PowerShell 5.1
- Multi-monitor and mixed-resolution displays
- CPU, GPU, memory, fixed/removable drives, Ethernet/Wi-Fi, and Windows Core
  Audio devices exposed through standard Windows APIs

The normal widget works without administrator access. CPU temperature is an
optional hardware-specific feature; see [Optional CPU temperature](#optional-cpu-temperature).

## Quick start

1. Download the ZIP from the latest GitHub Release rather than the automatically
   generated repository source archive.
2. Extract the complete ZIP to a writable folder. Do not run individual files
   directly from inside the archive.
3. Double-click `Run Widget.cmd`.

The launcher verifies every distributed executable and dependency against
`SHA256SUMS.txt` before starting. Settings are stored per user under
`%LOCALAPPDATA%\NeonPulseWidget`; nothing is written into the repository.

To verify manually:

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File ".\Verify Integrity.ps1"
```

## What it monitors

- CPU load, clock, and optional temperature
- Dedicated GPU memory and NVIDIA temperature when supported
- RAM load and used capacity
- Selected-drive activity, capacity, and read/write rate
- Network download and upload rate with dynamic KB/s or MB/s units
- Default audio-output device, volume, mute state, and device switching
- Default microphone, input gain, mute state, live signal, and device switching
- Four customizable world clocks with dates and flags

GPU performance counters are filtered to the LUID of the detected display
adapter so data from integrated and discrete GPUs is not combined. On NVIDIA
systems, the widget uses only the installed `%SystemRoot%\System32\nvidia-smi.exe`
after validating its Authenticode signer. NVIDIA reports exact dedicated-memory
capacity; other vendors use Windows' reported capacity and safely show `N/A` when
a temperature source is unavailable.

## Controls

- Drag the widget background to move it.
- Drag the lower-right corner to resize the complete interface uniformly.
- Use the upper-right controls to minimize to the notification area, toggle
  compact/restored size, or maximize on the current screen.
- Right-click the widget or tray icon for visibility, always-on-top, fit-to-screen,
  startup, opacity, and exit controls.
- Use the opacity slider from 0% through 100%. If the widget is fully transparent,
  restore it through its notification-area icon.
- Ctrl+click the CPU card to open Task Manager's Performance view.
- Ctrl+click the drive card to select another available drive.
- Ctrl+click a clock to select another city and time zone.
- Click an audio or microphone icon to mute/unmute it.
- Click an audio or microphone name to cycle through active devices.
- Use the horizontal cyan and lime sliders beneath the device rows to adjust
  output volume and microphone gain.

## Optional CPU temperature

Windows has no universal unprivileged CPU-temperature API. The default launcher
therefore displays `NO SENSOR` when no approved provider is running.

Users who want CPU temperature can install the official signed PawnIO package:

```powershell
winget install --id namazso.PawnIO --exact
```

Then run `Run Widget with CPU Temperature.cmd` and approve the UAC prompt. Only
the small read-only sensor helper is elevated; the WPF widget remains a normal
user process. PawnIO is not bundled, installed, updated, or downloaded by this
project.

Kernel drivers and elevated hardware access always increase attack surface. Use
the ordinary launcher if minimum privilege is more important than CPU temperature.

## Reproducing and validating a release

A clean clone can validate its dependencies and build a deterministic release:

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File ".\tools\Test-Repository.ps1"
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File ".\tools\Build-Release.ps1"
```

The first command parses all PowerShell sources, verifies the release manifest,
checks every DLL against `dependencies.lock.json`, rejects committed user-specific
paths, and confirms that two builds produce identical ZIP hashes. The second
creates `dist\NeonPulseWidget.zip` with stable file ordering and timestamps.

See [BUILDING.md](BUILDING.md) for clean-clone instructions and hardware-dependent
behavior.

## Security and privacy

- No telemetry, web requests, downloading logic, encoded commands, or remote
  control functionality
- Normal operation runs without administrator privileges
- Hash verification before both normal and optional elevated launch paths
- Bundled DLL versions, source locations, licenses, and hashes recorded in
  `dependencies.lock.json`
- Optional NVIDIA utility accepted only from System32 with a valid Microsoft
  hardware-publisher or NVIDIA signature
- Per-user configuration contains preferences only and is never committed

Read [SECURITY.md](SECURITY.md), `SECURITY.txt`, and `SECURITY-AUDIT.txt` before
redistributing the package or enabling optional sensor access.

## Third-party components

The optional sensor helper uses a hash-pinned build of LibreHardwareMonitor from
commit [`adf717d75a17f107629f63755f0e08b992e43ca9`](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/tree/adf717d75a17f107629f63755f0e08b992e43ca9),
licensed under MPL 2.0. Microsoft compatibility libraries are MIT licensed.
Complete notices are in `THIRD-PARTY-NOTICES.txt` and
`LICENSE-LibreHardwareMonitor.txt`.

## Uninstall

Disable `Start with Windows` from the widget menu, exit through the tray icon,
delete the extracted widget directory, and optionally remove
`%LOCALAPPDATA%\NeonPulseWidget` to erase saved preferences.
