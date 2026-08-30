param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$script:WidgetDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -LiteralPath $script:WidgetDir

Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class NeonNative {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct DISPLAY_DEVICE {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceString;
        public uint StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceKey;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct LUID { public uint LowPart; public int HighPart; }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct D3DKMT_OPENADAPTERFROMGDIDISPLAYNAME {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string DeviceName;
        public uint hAdapter;
        public LUID AdapterLuid;
        public uint VidPnSourceId;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct D3DKMT_CLOSEADAPTER { public uint hAdapter; }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Auto)]
    public class MEMORYSTATUSEX {
        public uint dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
        public uint dwMemoryLoad;
        public ulong ullTotalPhys, ullAvailPhys, ullTotalPageFile, ullAvailPageFile;
        public ulong ullTotalVirtual, ullAvailVirtual, ullAvailExtendedVirtual;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Auto, SetLastError=true)]
    public static extern bool GlobalMemoryStatusEx([In, Out] MEMORYSTATUSEX value);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool ReleaseCapture();
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr handle);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr handle);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr handle, int command);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern bool EnumDisplayDevices(string device, uint deviceNumber, ref DISPLAY_DEVICE displayDevice, uint flags);
    [DllImport("gdi32.dll")]
    public static extern int D3DKMTOpenAdapterFromGdiDisplayName(ref D3DKMT_OPENADAPTERFROMGDIDISPLAYNAME openAdapter);
    [DllImport("gdi32.dll")]
    public static extern int D3DKMTCloseAdapter(ref D3DKMT_CLOSEADAPTER closeAdapter);
    [DllImport("user32.dll", CharSet=CharSet.Auto)]
    public static extern IntPtr SendMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    public static string GetDisplayAdapterLuid(string targetName) {
        for (uint index = 0; index < 32; index++) {
            DISPLAY_DEVICE device = new DISPLAY_DEVICE();
            device.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
            if (!EnumDisplayDevices(null, index, ref device, 0)) break;
            if (String.IsNullOrWhiteSpace(device.DeviceName) || String.IsNullOrWhiteSpace(device.DeviceString)) continue;
            if (!String.Equals(device.DeviceString.Trim(), targetName == null ? "" : targetName.Trim(), StringComparison.OrdinalIgnoreCase)) continue;
            D3DKMT_OPENADAPTERFROMGDIDISPLAYNAME opened = new D3DKMT_OPENADAPTERFROMGDIDISPLAYNAME();
            opened.DeviceName = device.DeviceName;
            if (D3DKMTOpenAdapterFromGdiDisplayName(ref opened) != 0) continue;
            try {
                return String.Format("luid_0x{0:X8}_0x{1:X8}", unchecked((uint)opened.AdapterLuid.HighPart), opened.AdapterLuid.LowPart);
            } finally {
                D3DKMT_CLOSEADAPTER close = new D3DKMT_CLOSEADAPTER();
                close.hAdapter = opened.hAdapter;
                D3DKMTCloseAdapter(ref close);
            }
        }
        return null;
    }
}
'@

Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public sealed class NeonAudioSnapshot {
    public bool Available { get; set; }
    public bool Muted { get; set; }
    public int Volume { get; set; }
    public string Name { get; set; }
}

public sealed class NeonAudioDevice {
    public string Id { get; set; }
    public string Name { get; set; }
    public bool IsDefault { get; set; }
}

public static class NeonAudio {
    public static string LastError = "";
    enum EDataFlow { Render, Capture, All }
    enum ERole { Console, Multimedia, Communications }
    enum AudioClientShareMode { Shared, Exclusive }

    static readonly object MeterSync = new object();
    static IMMDevice meterDevice;
    static object meterAudioClientObject;
    static IAudioClient meterAudioClient;
    static object meterCaptureObject;
    static IAudioCaptureClient meterCaptureClient;
    static object meterInformationObject;
    static IAudioMeterInformation meterInformation;
    static string meterDeviceId = "";

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    class MMDeviceEnumeratorComObject { }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator {
        int EnumAudioEndpoints(EDataFlow dataFlow, uint stateMask, out IMMDeviceCollection devices);
        int GetDefaultAudioEndpoint(EDataFlow dataFlow, ERole role, out IMMDevice endpoint);
        int GetDevice(string id, out IMMDevice device);
        int RegisterEndpointNotificationCallback(IntPtr client);
        int UnregisterEndpointNotificationCallback(IntPtr client);
    }

    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceCollection {
        int GetCount(out uint count);
        int Item(uint index, out IMMDevice device);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice {
        int Activate(ref Guid iid, uint clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object instance);
        int OpenPropertyStore(uint access, out IPropertyStore properties);
        int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        int GetState(out uint state);
    }

    [StructLayout(LayoutKind.Sequential)]
    struct PROPERTYKEY { public Guid formatId; public uint propertyId; }

    [StructLayout(LayoutKind.Explicit)]
    struct PROPVARIANT {
        [FieldOffset(0)] public ushort type;
        [FieldOffset(8)] public IntPtr pointerValue;
    }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore {
        int GetCount(out uint count);
        int GetAt(uint index, out PROPERTYKEY key);
        int GetValue(ref PROPERTYKEY key, out PROPVARIANT value);
        int SetValue(ref PROPERTYKEY key, ref PROPVARIANT value);
        int Commit();
    }

    [DllImport("ole32.dll")]
    static extern int PropVariantClear(ref PROPVARIANT value);

    [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioEndpointVolume {
        int RegisterControlChangeNotify(IntPtr notify);
        int UnregisterControlChangeNotify(IntPtr notify);
        int GetChannelCount(out uint count);
        int SetMasterVolumeLevel(float level, ref Guid context);
        int SetMasterVolumeLevelScalar(float level, ref Guid context);
        int GetMasterVolumeLevel(out float level);
        int GetMasterVolumeLevelScalar(out float level);
        int SetChannelVolumeLevel(uint channel, float level, ref Guid context);
        int SetChannelVolumeLevelScalar(uint channel, float level, ref Guid context);
        int GetChannelVolumeLevel(uint channel, out float level);
        int GetChannelVolumeLevelScalar(uint channel, out float level);
        int SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, ref Guid context);
        int GetMute([MarshalAs(UnmanagedType.Bool)] out bool mute);
        int GetVolumeStepInfo(out uint step, out uint stepCount);
        int VolumeStepUp(ref Guid context);
        int VolumeStepDown(ref Guid context);
        int QueryHardwareSupport(out uint mask);
        int GetVolumeRange(out float min, out float max, out float increment);
    }

    [ComImport, Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioMeterInformation {
        int GetPeakValue(out float peak);
        int GetMeteringChannelCount(out int channelCount);
        int GetChannelsPeakValues(int channelCount, [Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex=0)] float[] peakValues);
        int QueryHardwareSupport(out int hardwareSupportMask);
    }

    [ComImport, Guid("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioClient {
        int Initialize(AudioClientShareMode shareMode, uint streamFlags, long bufferDuration, long periodicity, IntPtr format, ref Guid sessionGuid);
        int GetBufferSize(out uint bufferFrames);
        int GetStreamLatency(out long latency);
        int GetCurrentPadding(out uint paddingFrames);
        int IsFormatSupported(AudioClientShareMode shareMode, IntPtr format, out IntPtr closestMatch);
        int GetMixFormat(out IntPtr format);
        int GetDevicePeriod(out long defaultPeriod, out long minimumPeriod);
        int Start();
        int Stop();
        int Reset();
        int SetEventHandle(IntPtr eventHandle);
        int GetService(ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object service);
    }

    [ComImport, Guid("C8ADBD64-E71E-48A0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioCaptureClient {
        int GetBuffer(out IntPtr data, out uint frames, out uint flags, out ulong devicePosition, out ulong qpcPosition);
        int ReleaseBuffer(uint frames);
        int GetNextPacketSize(out uint frames);
    }

    [ComImport, Guid("870AF99C-171D-4F9E-AF0D-E63DF40C2BC9")]
    class PolicyConfigClient { }

    [ComImport, Guid("F8679F50-850A-41CF-9C72-430F290290C8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPolicyConfig {
        int GetMixFormat([MarshalAs(UnmanagedType.LPWStr)] string deviceId, out IntPtr format);
        int GetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string deviceId, int defaultFormat, out IntPtr format);
        int ResetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string deviceId);
        int SetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string deviceId, IntPtr endpointFormat, IntPtr mixFormat);
        int GetProcessingPeriod([MarshalAs(UnmanagedType.LPWStr)] string deviceId, int defaultPeriod, out long period, out long minimumPeriod);
        int SetProcessingPeriod([MarshalAs(UnmanagedType.LPWStr)] string deviceId, IntPtr period);
        int GetShareMode([MarshalAs(UnmanagedType.LPWStr)] string deviceId, out IntPtr mode);
        int SetShareMode([MarshalAs(UnmanagedType.LPWStr)] string deviceId, IntPtr mode);
        int GetPropertyValue([MarshalAs(UnmanagedType.LPWStr)] string deviceId, ref PROPERTYKEY key, out PROPVARIANT value);
        int SetPropertyValue([MarshalAs(UnmanagedType.LPWStr)] string deviceId, ref PROPERTYKEY key, ref PROPVARIANT value);
        int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string deviceId, ERole role);
        int SetEndpointVisibility([MarshalAs(UnmanagedType.LPWStr)] string deviceId, int visible);
    }

    static string GetFriendlyName(IMMDevice device) {
        IPropertyStore store = null;
        PROPVARIANT value = new PROPVARIANT();
        try {
            if (device.OpenPropertyStore(0, out store) != 0 || store == null) return "Default device";
            PROPERTYKEY key = new PROPERTYKEY { formatId = new Guid("A45C254E-DF1C-4EFD-8020-67D146A850E0"), propertyId = 14 };
            if (store.GetValue(ref key, out value) != 0 || value.pointerValue == IntPtr.Zero) return "Default device";
            return Marshal.PtrToStringUni(value.pointerValue) ?? "Default device";
        } catch { return "Default device"; }
        finally {
            if (value.pointerValue != IntPtr.Zero) PropVariantClear(ref value);
            if (store != null && Marshal.IsComObject(store)) Marshal.ReleaseComObject(store);
        }
    }

    static string GetDeviceId(IMMDevice device) {
        string id;
        return device != null && device.GetId(out id) == 0 ? id : "";
    }

    public static NeonAudioDevice[] GetDevices(bool capture) {
        IMMDeviceEnumerator enumerator = null;
        IMMDeviceCollection collection = null;
        IMMDevice defaultDevice = null;
        var result = new List<NeonAudioDevice>();
        try {
            LastError = "";
            enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
            string defaultId = "";
            if (enumerator.GetDefaultAudioEndpoint(capture ? EDataFlow.Capture : EDataFlow.Render, ERole.Multimedia, out defaultDevice) == 0)
                defaultId = GetDeviceId(defaultDevice);
            if (enumerator.EnumAudioEndpoints(capture ? EDataFlow.Capture : EDataFlow.Render, 1, out collection) != 0 || collection == null)
                return result.ToArray();
            uint count;
            if (collection.GetCount(out count) != 0) return result.ToArray();
            for (uint index = 0; index < count; index++) {
                IMMDevice device = null;
                try {
                    if (collection.Item(index, out device) != 0 || device == null) continue;
                    string id = GetDeviceId(device);
                    result.Add(new NeonAudioDevice { Id = id, Name = GetFriendlyName(device), IsDefault = String.Equals(id, defaultId, StringComparison.OrdinalIgnoreCase) });
                } finally {
                    if (device != null && Marshal.IsComObject(device)) Marshal.ReleaseComObject(device);
                }
            }
            return result.ToArray();
        } catch (Exception ex) { LastError = ex.ToString(); return result.ToArray(); }
        finally {
            if (defaultDevice != null && Marshal.IsComObject(defaultDevice)) Marshal.ReleaseComObject(defaultDevice);
            if (collection != null && Marshal.IsComObject(collection)) Marshal.ReleaseComObject(collection);
            if (enumerator != null && Marshal.IsComObject(enumerator)) Marshal.ReleaseComObject(enumerator);
        }
    }

    public static NeonAudioSnapshot CycleDefault(bool capture) {
        NeonAudioDevice[] devices = GetDevices(capture);
        if (devices.Length < 2) return GetDefault(capture);
        int current = Array.FindIndex(devices, d => d.IsDefault);
        int next = current < 0 ? 0 : (current + 1) % devices.Length;
        IPolicyConfig policy = null;
        try {
            policy = (IPolicyConfig)(new PolicyConfigClient());
            policy.SetDefaultEndpoint(devices[next].Id, ERole.Console);
            policy.SetDefaultEndpoint(devices[next].Id, ERole.Multimedia);
            policy.SetDefaultEndpoint(devices[next].Id, ERole.Communications);
        } catch (Exception ex) { LastError = ex.ToString(); return GetDefault(capture); }
        finally { if (policy != null && Marshal.IsComObject(policy)) Marshal.ReleaseComObject(policy); }
        NeonAudioSnapshot switched = GetDefault(capture);
        for (int attempt = 0; attempt < 8 && !String.Equals(switched.Name, devices[next].Name, StringComparison.OrdinalIgnoreCase); attempt++) {
            System.Threading.Thread.Sleep(35);
            switched = GetDefault(capture);
        }
        return switched;
    }

    public static NeonAudioSnapshot GetDefault(bool capture) {
        IMMDeviceEnumerator enumerator = null;
        IMMDevice device = null;
        object endpointObject = null;
        try {
            enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
            int hr = enumerator.GetDefaultAudioEndpoint(capture ? EDataFlow.Capture : EDataFlow.Render, ERole.Multimedia, out device);
            if (hr != 0 || device == null) return new NeonAudioSnapshot();
            Guid iid = typeof(IAudioEndpointVolume).GUID;
            hr = device.Activate(ref iid, 23, IntPtr.Zero, out endpointObject);
            if (hr != 0 || endpointObject == null) return new NeonAudioSnapshot();
            IAudioEndpointVolume endpoint = (IAudioEndpointVolume)endpointObject;
            float scalar; bool muted;
            if (endpoint.GetMasterVolumeLevelScalar(out scalar) != 0) scalar = 0;
            if (endpoint.GetMute(out muted) != 0) muted = false;
            return new NeonAudioSnapshot { Available = true, Muted = muted, Volume = (int)Math.Round(Math.Max(0, Math.Min(1, scalar)) * 100), Name = GetFriendlyName(device) };
        } catch { return new NeonAudioSnapshot(); }
        finally {
            if (endpointObject != null && Marshal.IsComObject(endpointObject)) Marshal.ReleaseComObject(endpointObject);
            if (device != null && Marshal.IsComObject(device)) Marshal.ReleaseComObject(device);
            if (enumerator != null && Marshal.IsComObject(enumerator)) Marshal.ReleaseComObject(enumerator);
        }
    }

    static void ClosePeakMeterInternal() {
        try { if (meterAudioClient != null) meterAudioClient.Stop(); } catch { }
        if (meterCaptureObject != null && Marshal.IsComObject(meterCaptureObject)) Marshal.ReleaseComObject(meterCaptureObject);
        if (meterInformationObject != null && Marshal.IsComObject(meterInformationObject)) Marshal.ReleaseComObject(meterInformationObject);
        if (meterAudioClientObject != null && Marshal.IsComObject(meterAudioClientObject)) Marshal.ReleaseComObject(meterAudioClientObject);
        if (meterDevice != null && Marshal.IsComObject(meterDevice)) Marshal.ReleaseComObject(meterDevice);
        meterCaptureObject = null; meterCaptureClient = null;
        meterInformationObject = null; meterInformation = null;
        meterAudioClientObject = null; meterAudioClient = null;
        meterDevice = null; meterDeviceId = "";
    }

    static bool EnsurePeakMeter(bool capture) {
        IMMDeviceEnumerator enumerator = null;
        IMMDevice nextDevice = null;
        object nextAudioClientObject = null;
        object nextCaptureObject = null;
        object nextMeterObject = null;
        try {
            enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
            if (enumerator.GetDefaultAudioEndpoint(capture ? EDataFlow.Capture : EDataFlow.Render, ERole.Multimedia, out nextDevice) != 0 || nextDevice == null) return false;
            string nextId = GetDeviceId(nextDevice);
            if (meterAudioClient != null && String.Equals(nextId, meterDeviceId, StringComparison.OrdinalIgnoreCase)) return true;
            ClosePeakMeterInternal();

            Guid audioClientIid = typeof(IAudioClient).GUID;
            if (nextDevice.Activate(ref audioClientIid, 23, IntPtr.Zero, out nextAudioClientObject) != 0 || nextAudioClientObject == null) return false;
            IAudioClient nextAudioClient = (IAudioClient)nextAudioClientObject;
            IntPtr format = IntPtr.Zero;
            try {
                if (nextAudioClient.GetMixFormat(out format) != 0 || format == IntPtr.Zero) return false;
                Guid session = Guid.Empty;
                if (nextAudioClient.Initialize(AudioClientShareMode.Shared, 0x00080000, 10000000, 0, format, ref session) != 0) return false;
            } finally { if (format != IntPtr.Zero) Marshal.FreeCoTaskMem(format); }

            Guid captureIid = typeof(IAudioCaptureClient).GUID;
            if (nextAudioClient.GetService(ref captureIid, out nextCaptureObject) != 0 || nextCaptureObject == null) return false;
            Guid meterIid = typeof(IAudioMeterInformation).GUID;
            if (nextDevice.Activate(ref meterIid, 23, IntPtr.Zero, out nextMeterObject) != 0 || nextMeterObject == null) return false;
            if (nextAudioClient.Start() != 0) return false;

            meterDevice = nextDevice; nextDevice = null;
            meterDeviceId = nextId;
            meterAudioClientObject = nextAudioClientObject; nextAudioClientObject = null;
            meterAudioClient = nextAudioClient;
            meterCaptureObject = nextCaptureObject; nextCaptureObject = null;
            meterCaptureClient = (IAudioCaptureClient)meterCaptureObject;
            meterInformationObject = nextMeterObject; nextMeterObject = null;
            meterInformation = (IAudioMeterInformation)meterInformationObject;
            return true;
        } catch { ClosePeakMeterInternal(); return false; }
        finally {
            if (nextMeterObject != null && Marshal.IsComObject(nextMeterObject)) Marshal.ReleaseComObject(nextMeterObject);
            if (nextCaptureObject != null && Marshal.IsComObject(nextCaptureObject)) Marshal.ReleaseComObject(nextCaptureObject);
            if (nextAudioClientObject != null && Marshal.IsComObject(nextAudioClientObject)) Marshal.ReleaseComObject(nextAudioClientObject);
            if (nextDevice != null && Marshal.IsComObject(nextDevice)) Marshal.ReleaseComObject(nextDevice);
            if (enumerator != null && Marshal.IsComObject(enumerator)) Marshal.ReleaseComObject(enumerator);
        }
    }

    public static int GetDefaultPeak(bool capture) {
        lock (MeterSync) {
            try {
                if (!EnsurePeakMeter(capture) || meterCaptureClient == null || meterInformation == null) return 0;
                uint packetFrames;
                while (meterCaptureClient.GetNextPacketSize(out packetFrames) == 0 && packetFrames > 0) {
                    IntPtr data; uint frames, flags; ulong devicePosition, qpcPosition;
                    if (meterCaptureClient.GetBuffer(out data, out frames, out flags, out devicePosition, out qpcPosition) != 0) break;
                    meterCaptureClient.ReleaseBuffer(frames);
                }
                float peak;
                if (meterInformation.GetPeakValue(out peak) != 0) return 0;
                return (int)Math.Round(Math.Max(0, Math.Min(1, peak)) * 100);
            } catch { ClosePeakMeterInternal(); return 0; }
        }
    }

    public static void ClosePeakMeter() { lock (MeterSync) { ClosePeakMeterInternal(); } }

    public static NeonAudioSnapshot ToggleDefaultMute(bool capture) {
        IMMDeviceEnumerator enumerator = null;
        IMMDevice device = null;
        object endpointObject = null;
        try {
            enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
            int hr = enumerator.GetDefaultAudioEndpoint(capture ? EDataFlow.Capture : EDataFlow.Render, ERole.Multimedia, out device);
            if (hr != 0 || device == null) return new NeonAudioSnapshot();
            Guid iid = typeof(IAudioEndpointVolume).GUID;
            hr = device.Activate(ref iid, 23, IntPtr.Zero, out endpointObject);
            if (hr != 0 || endpointObject == null) return new NeonAudioSnapshot();
            IAudioEndpointVolume endpoint = (IAudioEndpointVolume)endpointObject;
            float scalar; bool muted; Guid context = Guid.Empty;
            if (endpoint.GetMasterVolumeLevelScalar(out scalar) != 0) scalar = 0;
            if (endpoint.GetMute(out muted) != 0) muted = false;
            muted = !muted;
            endpoint.SetMute(muted, ref context);
            return new NeonAudioSnapshot { Available = true, Muted = muted, Volume = (int)Math.Round(Math.Max(0, Math.Min(1, scalar)) * 100), Name = GetFriendlyName(device) };
        } catch { return new NeonAudioSnapshot(); }
        finally {
            if (endpointObject != null && Marshal.IsComObject(endpointObject)) Marshal.ReleaseComObject(endpointObject);
            if (device != null && Marshal.IsComObject(device)) Marshal.ReleaseComObject(device);
            if (enumerator != null && Marshal.IsComObject(enumerator)) Marshal.ReleaseComObject(enumerator);
        }
    }

    public static NeonAudioSnapshot SetDefaultVolume(bool capture, int volume) {
        IMMDeviceEnumerator enumerator = null;
        IMMDevice device = null;
        object endpointObject = null;
        try {
            enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
            int hr = enumerator.GetDefaultAudioEndpoint(capture ? EDataFlow.Capture : EDataFlow.Render, ERole.Multimedia, out device);
            if (hr != 0 || device == null) return new NeonAudioSnapshot();
            Guid iid = typeof(IAudioEndpointVolume).GUID;
            hr = device.Activate(ref iid, 23, IntPtr.Zero, out endpointObject);
            if (hr != 0 || endpointObject == null) return new NeonAudioSnapshot();
            IAudioEndpointVolume endpoint = (IAudioEndpointVolume)endpointObject;
            Guid context = Guid.Empty;
            float scalar = Math.Max(0, Math.Min(100, volume)) / 100f;
            endpoint.SetMasterVolumeLevelScalar(scalar, ref context);
            bool muted;
            if (endpoint.GetMute(out muted) != 0) muted = false;
            return new NeonAudioSnapshot { Available = true, Muted = muted, Volume = (int)Math.Round(scalar * 100), Name = GetFriendlyName(device) };
        } catch { return new NeonAudioSnapshot(); }
        finally {
            if (endpointObject != null && Marshal.IsComObject(endpointObject)) Marshal.ReleaseComObject(endpointObject);
            if (device != null && Marshal.IsComObject(device)) Marshal.ReleaseComObject(device);
            if (enumerator != null && Marshal.IsComObject(enumerator)) Marshal.ReleaseComObject(enumerator);
        }
    }
}
'@

[NeonNative]::SetProcessDPIAware() | Out-Null

$script:AppName = 'NeonPulse Widget'
$script:ConfigDir = Join-Path $env:LOCALAPPDATA 'NeonPulseWidget'
$script:ConfigFile = Join-Path $script:ConfigDir 'settings.json'
$script:SensorCacheFile = Join-Path $script:ConfigDir 'cpu-sensor.json'
$script:SensorHeartbeatFile = Join-Path $script:ConfigDir 'sensor-heartbeat.txt'
$script:SensorTaskName = 'NeonPulse CPU Temperature Helper'
$script:SensorTaskRunner = Join-Path $env:SystemRoot 'System32\schtasks.exe'
$script:LastSensorRecoveryAttempt = [DateTime]::MinValue
$script:SensorRecoveryStatus = 'Idle'
[void][IO.Directory]::CreateDirectory($script:ConfigDir)
$script:InstallPath = $MyInvocation.MyCommand.Path
$script:SelectedDrive='C:'
if(Test-Path -LiteralPath $script:ConfigFile){
    try{
        $earlyConfig=Get-Content -LiteralPath $script:ConfigFile -Raw|ConvertFrom-Json
        if($earlyConfig.DriveLetter -match '^[A-Za-z]:$'){$script:SelectedDrive=$earlyConfig.DriveLetter.ToUpperInvariant()}
    }catch{}
}
$showSignalCreated = $false
$showSignalName = if($SelfTest){"NeonPulseWidget.ShowSignal.SelfTest.$PID"}else{'NeonPulseWidget.ShowSignal'}
$mutexName = if($SelfTest){"NeonPulseWidget.SingleInstance.SelfTest.$PID"}else{'NeonPulseWidget.SingleInstance'}
$script:ShowSignal = New-Object Threading.EventWaitHandle($false,[Threading.EventResetMode]::AutoReset,$showSignalName,[ref]$showSignalCreated)
$createdNew = $false
$script:Mutex = New-Object Threading.Mutex($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) {
    $script:ShowSignal.Set()|Out-Null
    $script:ShowSignal.Dispose()
    $script:Mutex.Dispose()
    return
}

function Get-HardwareInfo {
    $cpu = 'CPU'
    $gpu = 'GPU'
    $gpuFullName = 'GPU'
    $gpuRam = 0L
    $memory = 'SYSTEM MEMORY'
    $systemDisk = 'SYSTEM DRIVE'
    try { $cpu = (Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1).Name.Trim() -replace '(?i)\s+with Radeon Graphics.*$','' } catch {}
    try {
        $video = Get-CimInstance Win32_VideoController -ErrorAction Stop |
            Where-Object { $_.Name -notmatch 'Remote|Basic Display' } |
            Sort-Object AdapterRAM -Descending | Select-Object -First 1
        if ($video) { $gpuFullName = $video.Name.Trim(); $gpu = ($gpuFullName -replace '(?i)GeForce\s+',''); $gpuRam = [int64]$video.AdapterRAM }
    } catch {}
    try {
        $modules = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop)
        if ($modules.Count -gt 0) {
            $maker = ($modules[0].Manufacturer -replace '^0x[0-9A-F]+$','').Trim()
            if (-not $maker) { $maker = 'MEMORY' }
            $maker = ($maker -replace '(?i)\s+Inc\.?$','' -replace '\s+','')
            $total = [math]::Round((($modules | Measure-Object Capacity -Sum).Sum) / 1GB)
            $speed = ($modules | Measure-Object ConfiguredClockSpeed -Maximum).Maximum
            $typeCode = [int]$modules[0].SMBIOSMemoryType
            $type = if ($typeCode -eq 26) { 'DDR4' } elseif ($typeCode -eq 34) { 'DDR5' } else { 'RAM' }
            $memory = if ($speed) { "$maker $type ${total}GB | $speed MT/s" } else { "$maker $type ${total}GB" }
        }
    } catch {}
    try {
        $logical = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
        $partition = Get-CimAssociatedInstance -InputObject $logical -Association Win32_LogicalDiskToPartition -ErrorAction Stop | Select-Object -First 1
        $physical = Get-CimAssociatedInstance -InputObject $partition -Association Win32_DiskDriveToDiskPartition -ErrorAction Stop | Select-Object -First 1
        if ($physical.Model) { $systemDisk = $physical.Model.Trim() }
    } catch {}
    [pscustomobject]@{ Cpu = $cpu; Gpu = $gpu; GpuFullName = $gpuFullName; GpuRam = $gpuRam; Memory = $memory; SystemDisk = $systemDisk }
}

function Get-MemorySample {
    $m = New-Object NeonNative+MEMORYSTATUSEX
    if (-not [NeonNative]::GlobalMemoryStatusEx($m)) { return $null }
    [pscustomobject]@{
        Percent = [double]$m.dwMemoryLoad
        UsedGB = [math]::Round(($m.ullTotalPhys - $m.ullAvailPhys) / 1GB, 1)
        TotalGB = [math]::Round($m.ullTotalPhys / 1GB, 1)
    }
}

function New-CounterSafe([string]$category, [string]$counter, [string]$instance) {
    try {
        $c = New-Object System.Diagnostics.PerformanceCounter($category, $counter, $instance, $true)
        $null = $c.NextValue()
        return $c
    } catch { return $null }
}

function Get-DriveDescriptor([string]$driveLetter) {
    $id=($driveLetter.Trim().TrimEnd('\')).ToUpperInvariant()
    if($id -notmatch '^[A-Z]:$'){return $null}
    try{$logical=Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$id'" -ErrorAction Stop}catch{return $null}
    if($logical.DriveType -notin @(2,3) -or -not $logical.Size){return $null}
    $model=''
    try{
        $partition=Get-CimAssociatedInstance -InputObject $logical -Association Win32_LogicalDiskToPartition -ErrorAction Stop|Select-Object -First 1
        $physical=Get-CimAssociatedInstance -InputObject $partition -Association Win32_DiskDriveToDiskPartition -ErrorAction Stop|Select-Object -First 1
        if($physical.Model){$model=$physical.Model.Trim()}
    }catch{}
    $volume=if($logical.VolumeName){$logical.VolumeName.Trim()}else{'LOCAL DISK'}
    $subtitle=if($model){$model}else{$volume}
    [pscustomobject]@{Id=$id;Title="$id DISK";Subtitle=$subtitle;Volume=$volume;Size=[int64]$logical.Size;FreeSpace=[int64]$logical.FreeSpace}
}

function Get-AvailableDriveDescriptors {
    $result=@()
    try{
        foreach($logical in @(Get-CimInstance Win32_LogicalDisk -ErrorAction Stop|Where-Object {$_.DriveType -in @(2,3) -and $_.Size}|Sort-Object DeviceID)){
            $descriptor=Get-DriveDescriptor $logical.DeviceID
            if($descriptor){$result+=$descriptor}
        }
    }catch{}
    return $result
}

if(-not (Get-DriveDescriptor $script:SelectedDrive)){$script:SelectedDrive='C:'}
$script:SelectedDriveDescriptor=Get-DriveDescriptor $script:SelectedDrive

function Initialize-DiskCounters([string]$driveLetter) {
    foreach($counter in @($script:DiskActiveCounter,$script:DiskReadCounter,$script:DiskWriteCounter)){if($counter){try{$counter.Dispose()}catch{}}}
    $script:DiskActiveCounter=New-CounterSafe 'LogicalDisk' '% Disk Time' $driveLetter
    $script:DiskReadCounter=New-CounterSafe 'LogicalDisk' 'Disk Read Bytes/sec' $driveLetter
    $script:DiskWriteCounter=New-CounterSafe 'LogicalDisk' 'Disk Write Bytes/sec' $driveLetter
}

$script:Hardware = Get-HardwareInfo
$script:CpuCounter = New-CounterSafe 'Processor Information' '% Processor Utility' '_Total'
if(-not $script:CpuCounter){$script:CpuCounter = New-CounterSafe 'Processor' '% Processor Time' '_Total'}
$script:CpuFreqCounter = New-CounterSafe 'Processor Information' 'Processor Frequency' '_Total'
$script:CpuPerformanceCounter = New-CounterSafe 'Processor Information' '% Processor Performance' '_Total'
$script:DiskActiveCounter = $null
$script:DiskReadCounter = $null
$script:DiskWriteCounter = $null
Initialize-DiskCounters $script:SelectedDrive
$script:GpuCounters = @()
$script:GpuMemoryCounters = @()
$script:GpuSharedMemoryCounters = @()
$script:GpuLuidPrefix = $null
try { $script:GpuLuidPrefix = [NeonNative]::GetDisplayAdapterLuid($script:Hardware.GpuFullName) } catch {}
$gpuMemoryInstances = @()
try { $gpuMemoryInstances = @((New-Object System.Diagnostics.PerformanceCounterCategory('GPU Adapter Memory')).GetInstanceNames()) } catch {}
if (-not $script:GpuLuidPrefix -and $gpuMemoryInstances.Count -eq 1 -and $gpuMemoryInstances[0] -match '^(luid_0x[0-9A-Fa-f]+_0x[0-9A-Fa-f]+)_phys_') {
    $script:GpuLuidPrefix = $Matches[1]
}
$script:NvidiaSmiPath = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
$script:NvidiaSmiTrusted = $false
$script:NvidiaProcess = $null
$script:NvidiaOutputTask = $null
$script:NvidiaErrorTask = $null
$script:NvidiaLastStart = [DateTime]::MinValue
$script:NvidiaProcessStarted = [DateTime]::MinValue
$script:NvidiaLastSuccess = [DateTime]::MinValue
$script:NvidiaTemperature = 0.0
$script:NvidiaDedicatedLimitGB = 0.0
$script:NvidiaSensorStatus = 'nvidia-smi.exe not found'
try {
    if(Test-Path -LiteralPath $script:NvidiaSmiPath -PathType Leaf){
        $securityModulePath=Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Security\Microsoft.PowerShell.Security.psd1'
        Import-Module -Name $securityModulePath -ErrorAction Stop
        $signature=Microsoft.PowerShell.Security\Get-AuthenticodeSignature -LiteralPath $script:NvidiaSmiPath
        $subject=if($signature.SignerCertificate){$signature.SignerCertificate.Subject}else{''}
        $script:NvidiaSmiTrusted=($signature.Status -eq 'Valid' -and $subject -match 'Microsoft Windows Hardware Compatibility Publisher|NVIDIA Corporation')
        if($script:NvidiaSmiTrusted){$script:NvidiaSensorStatus='Pending'}else{$script:NvidiaSensorStatus=('Signature rejected: {0}' -f $signature.Status)}
    }
}catch{$script:NvidiaSensorStatus=('Signature check error: {0}' -f $_.Exception.GetType().Name)}
try {
    $cat = New-Object System.Diagnostics.PerformanceCounterCategory('GPU Engine')
    foreach ($instance in $cat.GetInstanceNames()) {
        if ($script:GpuLuidPrefix -and $instance -like "*_$($script:GpuLuidPrefix)_*" -and $instance -match 'engtype_(3D|Graphics|Compute)') {
            $c = New-CounterSafe 'GPU Engine' 'Utilization Percentage' $instance
            if ($c) { $script:GpuCounters += $c }
        }
    }
} catch {}

function Update-NvidiaSensor {
    if(-not $script:NvidiaSmiTrusted){return}
    try {
        if ($script:NvidiaProcess) {
            if ($script:NvidiaProcess.HasExited) {
                $output = if($script:NvidiaOutputTask){$script:NvidiaOutputTask.GetAwaiter().GetResult()}else{''}
                $targetName=$script:Hardware.GpuFullName.Trim()
                $found=$false
                foreach($line in @($output -split "`r?`n")){
                    $match=[regex]::Match($line,'^\s*(.+?)\s*,\s*([0-9]{1,3})\s*,\s*([0-9]+(?:\.[0-9]+)?)\s*$')
                    if($match.Success -and $match.Groups[1].Value.Trim() -eq $targetName){
                        $temperature=[double]$match.Groups[2].Value
                        $dedicatedLimitGB=[double]$match.Groups[3].Value/1024.0
                        if($temperature -gt 0 -and $temperature -lt 120){
                            $script:NvidiaTemperature=$temperature
                            if($dedicatedLimitGB -gt 0){$script:NvidiaDedicatedLimitGB=[math]::Round($dedicatedLimitGB,1)}
                            $script:NvidiaLastSuccess=[DateTime]::UtcNow
                            $script:NvidiaSensorStatus='Available'
                            $found=$true
                            break
                        }
                    }
                }
                if(-not $found -and $script:NvidiaTemperature -le 0){$script:NvidiaSensorStatus='No matching NVIDIA sensor'}
                $script:NvidiaProcess.Dispose(); $script:NvidiaProcess = $null
                $script:NvidiaOutputTask = $null; $script:NvidiaErrorTask = $null
            } elseif (([DateTime]::UtcNow-$script:NvidiaProcessStarted).TotalSeconds -gt 4) {
                try{$script:NvidiaProcess.Kill()}catch{}
                try{$script:NvidiaProcess.Dispose()}catch{}
                $script:NvidiaProcess=$null
                $script:NvidiaOutputTask=$null
                $script:NvidiaErrorTask=$null
                if($script:NvidiaTemperature -le 0){$script:NvidiaSensorStatus='Polling timeout'}
            }
        }
        if (-not $script:NvidiaProcess -and ([DateTime]::UtcNow - $script:NvidiaLastStart).TotalSeconds -ge 5) {
            $startInfo = New-Object Diagnostics.ProcessStartInfo
            $startInfo.FileName = $script:NvidiaSmiPath
            $startInfo.Arguments = '--query-gpu=name,temperature.gpu,memory.total --format=csv,noheader,nounits'
            $startInfo.WorkingDirectory = Split-Path -Parent $script:NvidiaSmiPath
            $startInfo.UseShellExecute = $false; $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardOutput = $true; $startInfo.RedirectStandardError = $true
            $process = New-Object Diagnostics.Process; $process.StartInfo = $startInfo
            if ($process.Start()) {
                $script:NvidiaProcess = $process
                $script:NvidiaOutputTask = $process.StandardOutput.ReadToEndAsync()
                $script:NvidiaErrorTask = $process.StandardError.ReadToEndAsync()
                $script:NvidiaLastStart = [DateTime]::UtcNow
                $script:NvidiaProcessStarted = $script:NvidiaLastStart
            }
        }
    } catch {
        if ($script:NvidiaProcess) { try { $script:NvidiaProcess.Dispose() } catch {}; $script:NvidiaProcess = $null }
        $script:NvidiaOutputTask=$null
        $script:NvidiaErrorTask=$null
        if($script:NvidiaTemperature -le 0){$script:NvidiaSensorStatus=('Polling error: {0}' -f $_.Exception.GetType().Name)}
    }
}

function Request-CpuSensorRecovery {
    if($SelfTest){return}
    $now=[DateTime]::UtcNow
    if(($now-$script:LastSensorRecoveryAttempt).TotalSeconds -lt 15){return}
    $script:LastSensorRecoveryAttempt=$now
    if(-not(Test-Path -LiteralPath $script:SensorTaskRunner -PathType Leaf)){$script:SensorRecoveryStatus='Windows Task Scheduler is unavailable';return}
    try{
        $startInfo=New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName=$script:SensorTaskRunner
        $startInfo.Arguments=('/Run /TN "{0}"' -f $script:SensorTaskName)
        $startInfo.WorkingDirectory=Split-Path -Parent $script:SensorTaskRunner
        $startInfo.UseShellExecute=$false;$startInfo.CreateNoWindow=$true;$startInfo.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
        $process=New-Object Diagnostics.Process;$process.StartInfo=$startInfo
        if(-not $process.Start()){$script:SensorRecoveryStatus='Unable to start the protected sensor task';return}
        try{
            if($process.WaitForExit(1500)){
                if($process.ExitCode -eq 0){$script:SensorRecoveryStatus='Starting protected sensor helper'}else{$script:SensorRecoveryStatus=('Protected sensor task returned {0}' -f $process.ExitCode)}
            }else{$script:SensorRecoveryStatus='Protected sensor task request is pending'}
        }finally{$process.Dispose()}
    }catch{$script:SensorRecoveryStatus=('Sensor recovery error: {0}' -f $_.Exception.GetType().Name)}
}

function Get-ExternalCpuSensorSample {
    try {
        if(-not (Test-Path -LiteralPath $script:SensorCacheFile -PathType Leaf)){Request-CpuSensorRecovery;return $null}
        $share=[IO.FileShare]([int][IO.FileShare]::ReadWrite -bor [int][IO.FileShare]::Delete)
        $stream=[IO.FileStream]::new($script:SensorCacheFile,[IO.FileMode]::Open,[IO.FileAccess]::Read,$share)
        try{$reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$true);try{$raw=$reader.ReadToEnd()}finally{$reader.Dispose()}}finally{if($stream){$stream.Dispose()}}
        $sample=$raw|ConvertFrom-Json
        if($sample.Provider -ne 'PawnIO/LibreHardwareMonitor'){Request-CpuSensorRecovery;return $null}
        $timestamp=[DateTime]::Parse([string]$sample.TimestampUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AdjustToUniversal)
        if(([DateTime]::UtcNow-$timestamp.ToUniversalTime()).TotalSeconds -gt 5){Request-CpuSensorRecovery;return $null}
        $temperature=[double]$sample.CpuTemperatureC
        $power=[double]$sample.CpuPackagePowerW
        if($temperature -le 0 -or $temperature -ge 110){Request-CpuSensorRecovery;return $null}
        $script:SensorRecoveryStatus='Available'
        [pscustomobject]@{Temperature=$temperature;Power=if($power -gt 0 -and $power -lt 300){$power}else{0.0};Provider=[string]$sample.Provider}
    }catch{Request-CpuSensorRecovery;return $null}
}

function Get-HardwareSensorSample {
    Update-NvidiaSensor
    $cpu=Get-ExternalCpuSensorSample
    [pscustomobject]@{ CpuTemp=if($cpu){$cpu.Temperature}else{0.0}; GpuTemp=$script:NvidiaTemperature; CpuPower=if($cpu){$cpu.Power}else{0.0}; CpuProvider=if($cpu){$cpu.Provider}else{'Unavailable'} }
}

Update-NvidiaSensor
try {
    foreach ($instance in $gpuMemoryInstances) {
        if ($script:GpuLuidPrefix -and $instance -like "$($script:GpuLuidPrefix)_phys_*") {
            $c = New-CounterSafe 'GPU Adapter Memory' 'Dedicated Usage' $instance
            if ($c) { $script:GpuMemoryCounters += $c }
            $shared = New-CounterSafe 'GPU Adapter Memory' 'Shared Usage' $instance
            if ($shared) { $script:GpuSharedMemoryCounters += $shared }
        }
    }
} catch {}

function Get-GpuSample {
    $usage = 0.0
    $valid = $false
    foreach ($c in $script:GpuCounters) {
        try { $usage += [double]$c.NextValue(); $valid = $true } catch {}
    }
    $dedicated = 0.0
    $dedicatedValid = $false
    foreach ($c in $script:GpuMemoryCounters) {
        try { $dedicated += [double]$c.NextValue(); $dedicatedValid = $true } catch {}
    }
    $shared = 0.0
    $sharedValid = $false
    foreach ($c in $script:GpuSharedMemoryCounters) {
        try { $shared += [double]$c.NextValue(); $sharedValid = $true } catch {}
    }
    [pscustomobject]@{
        Available = $valid
        Percent = [math]::Min(100, [math]::Max(0, $usage))
        UsedGB = [math]::Round($dedicated / 1GB, 1)
        DedicatedAvailable = $dedicatedValid
        SharedUsedGB = [math]::Round($shared / 1GB, 1)
        SharedAvailable = $sharedValid
    }
}

function Get-NetworkSample {
    $rx = 0L; $tx = 0L
    try {
        foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($nic.OperationalStatus -eq 'Up' -and $nic.NetworkInterfaceType -notin @('Loopback','Tunnel')) {
                if($nic.GetIPProperties().UnicastAddresses.Count -eq 0){continue}
                $s = $nic.GetIPv4Statistics(); $rx += $s.BytesReceived; $tx += $s.BytesSent
            }
        }
    } catch {}
    [pscustomobject]@{ Rx = $rx; Tx = $tx }
}

function Get-NetworkTechnology {
    try {
        $active=@([System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()|Where-Object{$_.OperationalStatus -eq 'Up' -and $_.NetworkInterfaceType -notin @('Loopback','Tunnel')})
        if($active|Where-Object{$_.NetworkInterfaceType -eq 'Wireless80211'}){return 'WI-FI'}
        if($active|Where-Object{$_.NetworkInterfaceType -match 'Ethernet'}){return 'LAN'}
    }catch{}
    return 'NET'
}
$script:NetworkTechnology=Get-NetworkTechnology

function Get-AudioDeviceLabel([string]$name,[bool]$capture) {
    if ([string]::IsNullOrWhiteSpace($name)) { return $(if($capture){'NO INPUT DEVICE'}else{'NO OUTPUT DEVICE'}) }
    $label=$name.Trim()
    if ($capture -and $label -match '^(?i)Microphone\s*\((.+)\)\s*$') {
        $label=$Matches[1]
    } elseif (-not $capture -and $label -match '^(.+?)\s*\(') {
        $label=$Matches[1]
    }
    return $label.ToUpperInvariant()
}

if ($SelfTest) {
    for($attempt=0;$attempt -lt 30 -and $script:NvidiaSensorStatus -eq 'Pending';$attempt++){
        Update-NvidiaSensor
        if($script:NvidiaSensorStatus -eq 'Pending'){Start-Sleep -Milliseconds 100}
    }
    $mem = Get-MemorySample
    $gpu = Get-GpuSample
    $sensors = Get-HardwareSensorSample
    $drive = New-Object IO.DriveInfo($script:SelectedDrive)
    [pscustomobject]@{
        CpuName = $script:Hardware.Cpu
        GpuName = $script:Hardware.Gpu
        GpuAdapterLuid = $script:GpuLuidPrefix
        MemoryPercent = $mem.Percent
        SystemDriveGB = [math]::Round($drive.TotalSize / 1GB, 1)
        GpuCountersFound = $script:GpuCounters.Count
        GpuMemoryCountersFound = $script:GpuMemoryCounters.Count
        GpuSharedMemoryCountersFound = $script:GpuSharedMemoryCounters.Count
        GpuPercent = $gpu.Percent
        GpuVramUsedGB = $gpu.UsedGB
        GpuDedicatedMemoryAvailable = $gpu.DedicatedAvailable
        GpuDedicatedLimitGB = $script:NvidiaDedicatedLimitGB
        GpuSharedUsedGB = $gpu.SharedUsedGB
        CpuTemperatureC = $sensors.CpuTemp
        CpuTemperatureStatus = $sensors.CpuProvider
        GpuTemperatureC = $sensors.GpuTemp
        GpuTemperatureStatus = $script:NvidiaSensorStatus
        CpuPackagePowerW = $sensors.CpuPower
        NetworkInterfaces = ([Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | Where-Object OperationalStatus -eq Up).Count
    } | Format-List
    return
}

function Brush([string]$hex) { New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($hex)) }
$Cyan = Brush '#00EAF2'; $Blue = Brush '#009BFF'; $Lime = Brush '#C8F000'; $White = Brush '#F5F7FA'
$Muted = Brush '#AEB6BF'; $Panel = Brush '#A8080B0E'; $DarkCyan = Brush '#163B4D'; $OutlineBrush = Brush '#009EA8'; $WarningRed = Brush '#FFFF384F'

function New-NeonPulseTrayIcon {
    $bitmap=New-Object Drawing.Bitmap(32,32)
    $graphics=[Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode=[Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([Drawing.Color]::Transparent)
    $graphics.FillEllipse((New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(255,3,12,16))),2,2,28,28)
    $cyanPen=New-Object Drawing.Pen([Drawing.Color]::FromArgb(255,0,234,242),4)
    $cyanPen.StartCap=[Drawing.Drawing2D.LineCap]::Round;$cyanPen.EndCap=[Drawing.Drawing2D.LineCap]::Round
    $graphics.DrawArc($cyanPen,5,5,22,22,135,270)
    $limePen=New-Object Drawing.Pen([Drawing.Color]::FromArgb(255,200,240,0),3)
    $limePen.StartCap=[Drawing.Drawing2D.LineCap]::Round;$limePen.EndCap=[Drawing.Drawing2D.LineCap]::Round
    $graphics.DrawLine($limePen,16,17,23,10)
    $graphics.FillEllipse((New-Object Drawing.SolidBrush([Drawing.Color]::White)),13,14,6,6)
    $handle=$bitmap.GetHicon()
    $icon=[Drawing.Icon]::FromHandle($handle).Clone()
    [NeonNative]::DestroyIcon($handle)|Out-Null
    $cyanPen.Dispose();$limePen.Dispose();$graphics.Dispose();$bitmap.Dispose()
    return $icon
}

function New-PanelGradient {
    $brush = New-Object Windows.Media.LinearGradientBrush
    $brush.StartPoint='0,0';$brush.EndPoint='1,1'
    $brush.GradientStops.Add((New-Object Windows.Media.GradientStop((([Windows.Media.ColorConverter]::ConvertFromString('#F20B161D'))),0)))
    $brush.GradientStops.Add((New-Object Windows.Media.GradientStop((([Windows.Media.ColorConverter]::ConvertFromString('#FA020608'))),1)))
    return $brush
}

function New-Text([string]$text, [double]$size, $color, [string]$weight = 'Normal') {
    $t = New-Object Windows.Controls.TextBlock
    $t.Text = $text; $t.FontFamily = 'Segoe UI'; $t.FontSize = $size; $t.Foreground = $color
    $t.FontWeight = $weight; $t.HorizontalAlignment = 'Center'; $t.VerticalAlignment = 'Center'
    $t.TextAlignment = 'Center'
    return $t
}

function New-NeonSlider([string]$accentHex) {
    $xaml=@"
<Slider xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Minimum="0" Maximum="100" Value="0" Width="190" Height="20" Orientation="Horizontal" IsDirectionReversed="False" IsMoveToPointEnabled="True" Focusable="False">
  <Slider.Template>
    <ControlTemplate TargetType="{x:Type Slider}">
      <Grid VerticalAlignment="Center" Height="18">
        <Border Height="6" Margin="10,0" CornerRadius="3" Background="#FF102A34" BorderBrush="#804D7581" BorderThickness="1" VerticalAlignment="Center"/>
        <Track x:Name="PART_Track" Height="16" Margin="10,0" Orientation="Horizontal" IsDirectionReversed="False" VerticalAlignment="Center">
          <Track.DecreaseRepeatButton>
            <RepeatButton Command="Slider.DecreaseLarge" IsTabStop="False">
              <RepeatButton.Template><ControlTemplate TargetType="{x:Type RepeatButton}"><Border Height="6" CornerRadius="3" Background="$accentHex" VerticalAlignment="Center"/></ControlTemplate></RepeatButton.Template>
            </RepeatButton>
          </Track.DecreaseRepeatButton>
          <Track.Thumb>
            <Thumb Width="16" Height="16">
              <Thumb.Template><ControlTemplate TargetType="{x:Type Thumb}"><Border CornerRadius="8" Background="#FF07161E" BorderBrush="$accentHex" BorderThickness="2" Padding="3"><Ellipse Fill="$accentHex" Opacity="0.9"/></Border></ControlTemplate></Thumb.Template>
            </Thumb>
          </Track.Thumb>
          <Track.IncreaseRepeatButton>
            <RepeatButton Command="Slider.IncreaseLarge" IsTabStop="False">
              <RepeatButton.Template><ControlTemplate TargetType="{x:Type RepeatButton}"><Border Background="Transparent"/></ControlTemplate></RepeatButton.Template>
            </RepeatButton>
          </Track.IncreaseRepeatButton>
        </Track>
      </Grid>
    </ControlTemplate>
  </Slider.Template>
</Slider>
"@
    return [Windows.Markup.XamlReader]::Parse($xaml)
}

function New-VectorIcon([string]$kind, $accent, [double]$size=29) {
    $badge=New-Object Windows.Controls.Border;$badge.Width=$size;$badge.Height=$size;$badge.CornerRadius=7
    $badge.Background=Brush '#E50A2028';$badge.BorderBrush=Brush '#7042DDE7';$badge.BorderThickness=1
    $canvas=New-Object Windows.Controls.Canvas;$canvas.Width=20;$canvas.Height=20;$canvas.HorizontalAlignment='Center';$canvas.VerticalAlignment='Center'
    $addLine={param($x1,$y1,$x2,$y2,$thickness=1.5)
        $s=New-Object Windows.Shapes.Line;$s.X1=$x1;$s.Y1=$y1;$s.X2=$x2;$s.Y2=$y2;$s.Stroke=$accent;$s.StrokeThickness=$thickness;$s.StrokeStartLineCap='Round';$s.StrokeEndLineCap='Round';$canvas.Children.Add($s)|Out-Null
    }
    $addRect={param($x,$y,$w,$h,$radius=1.5,$fill=$null)
        $s=New-Object Windows.Shapes.Rectangle;$s.Width=$w;$s.Height=$h;$s.RadiusX=$radius;$s.RadiusY=$radius;$s.Stroke=$accent;$s.StrokeThickness=1.4;if($fill){$s.Fill=$fill};[Windows.Controls.Canvas]::SetLeft($s,$x);[Windows.Controls.Canvas]::SetTop($s,$y);$canvas.Children.Add($s)|Out-Null
    }
    $addEllipse={param($x,$y,$w,$h,$fill=$null)
        $s=New-Object Windows.Shapes.Ellipse;$s.Width=$w;$s.Height=$h;$s.Stroke=$accent;$s.StrokeThickness=1.4;if($fill){$s.Fill=$fill};[Windows.Controls.Canvas]::SetLeft($s,$x);[Windows.Controls.Canvas]::SetTop($s,$y);$canvas.Children.Add($s)|Out-Null
    }
    switch($kind.ToUpper()) {
        'CPU' {
            & $addRect 5 5 10 10 2
            & $addRect 8 8 4 4 1 (Brush '#5539F5FF')
            foreach($p in @(7,10,13)){& $addLine 2 $p 5 $p 1.2;& $addLine 15 $p 18 $p 1.2;& $addLine $p 2 $p 5 1.2;& $addLine $p 15 $p 18 1.2}
        }
        'GPU' {
            & $addRect 2 5 16 10 2
            & $addEllipse 5 7 6 6
            & $addLine 8 7.5 8 12.5 1;& $addLine 5.5 10 10.5 10 1
            & $addLine 14 8 16 8 1.2;& $addLine 14 11 16 11 1.2;& $addLine 5 17 15 17 1.2
        }
        'RAM' {
            & $addRect 2 6 16 8 1.5
            foreach($x in @(4,7,10,13)){& $addRect $x 8 2 3 .4 (Brush '#5539F5FF');& $addLine ($x+1) 14 ($x+1) 17 1}
            & $addLine 2 4 5 4 1.2;& $addLine 15 4 18 4 1.2
        }
        'DISK' {
            & $addRect 3 2 14 16 3
            & $addEllipse 6 5 8 8
            & $addEllipse 9 8 2 2 (Brush '#AA00EAF2')
            & $addLine 12 12 15 15 1.3;& $addEllipse 5 15 1 1 (Brush '#FF00EAF2')
        }
        'TEMP' {
            & $addEllipse 6 13 8 6 (Brush '#4439F5FF');& $addRect 8 2 4 13 2
            & $addLine 10 6 10 15 2.2;& $addLine 13 5 16 5 1;& $addLine 13 9 15 9 1
        }
        'CLOCK' {
            & $addEllipse 2 2 16 16;& $addLine 10 5 10 10 1.6;& $addLine 10 10 14 12 1.6
            & $addEllipse 9 9 2 2 (Brush '#FF00EAF2')
        }
        'VRAM' {
            & $addRect 4 4 12 12 2;& $addRect 7 7 6 6 1 (Brush '#5539F5FF')
            foreach($p in @(6,10,14)){& $addLine 1 $p 4 $p 1.2;& $addLine 16 $p 19 $p 1.2}
        }
        'AUDIO' {
            $speaker=New-Object Windows.Shapes.Polygon;$speaker.Points=[Windows.Media.PointCollection]::Parse('2,8 6,8 11,4 11,16 6,12 2,12');$speaker.Fill=$accent;$canvas.Children.Add($speaker)|Out-Null
            $wave1=New-Object Windows.Shapes.Path;$wave1.Data=[Windows.Media.Geometry]::Parse('M13,7 A4,4 0 0 1 13,13');$wave1.Stroke=$accent;$wave1.StrokeThickness=1.6;$wave1.StrokeStartLineCap='Round';$canvas.Children.Add($wave1)|Out-Null
            $wave2=New-Object Windows.Shapes.Path;$wave2.Data=[Windows.Media.Geometry]::Parse('M15,4 A8,8 0 0 1 15,16');$wave2.Stroke=$accent;$wave2.StrokeThickness=1.6;$wave2.StrokeStartLineCap='Round';$canvas.Children.Add($wave2)|Out-Null
        }
        'MIC' {
            $capsule=New-Object Windows.Shapes.Rectangle;$capsule.Width=7;$capsule.Height=11;$capsule.RadiusX=3.5;$capsule.RadiusY=3.5;$capsule.Stroke=$accent;$capsule.StrokeThickness=1.6;[Windows.Controls.Canvas]::SetLeft($capsule,6.5);[Windows.Controls.Canvas]::SetTop($capsule,1);$canvas.Children.Add($capsule)|Out-Null
            $cup=New-Object Windows.Shapes.Path;$cup.Data=[Windows.Media.Geometry]::Parse('M4,9 A6,6 0 0 0 16,9');$cup.Stroke=$accent;$cup.StrokeThickness=1.6;$cup.StrokeStartLineCap='Round';$canvas.Children.Add($cup)|Out-Null
            & $addLine 10 15 10 18 1.6;& $addLine 7 18 13 18 1.6
        }
        'NETWORK' {
            & $addLine 6 3 6 16 1.8;& $addLine 3 13 6 16 1.8;& $addLine 9 13 6 16 1.8
            & $addLine 14 17 14 4 1.8;& $addLine 11 7 14 4 1.8;& $addLine 17 7 14 4 1.8
        }
        default { & $addEllipse 3 3 14 14 }
    }
    if($kind.ToUpper() -in @('AUDIO','MIC')){
        $muteSlash=New-Object Windows.Shapes.Line;$muteSlash.X1=3;$muteSlash.Y1=3;$muteSlash.X2=17;$muteSlash.Y2=17;$muteSlash.Stroke=$WarningRed;$muteSlash.StrokeThickness=2.6;$muteSlash.StrokeStartLineCap='Round';$muteSlash.StrokeEndLineCap='Round';$muteSlash.Visibility='Collapsed';$canvas.Children.Add($muteSlash)|Out-Null
        $badge.Tag=[pscustomobject]@{MuteSlash=$muteSlash}
    }
    $badge.Child=$canvas
    return $badge
}

function Set-DeviceIconState($icon,[string]$state,$normalAccent) {
    if($icon.Tag -and $icon.Tag.MuteSlash){$icon.Tag.MuteSlash.Visibility=if($state -eq 'Muted'){'Visible'}else{'Collapsed'}}
    if($state -eq 'Muted'){$icon.Opacity=1;$icon.BorderBrush=$WarningRed;$icon.Background=Brush '#55FF243D'}
    elseif($state -eq 'Offline'){$icon.Opacity=.4;$icon.BorderBrush=$Muted;$icon.Background=Brush '#CC0A1115'}
    else{$icon.Opacity=1;$icon.BorderBrush=$normalAccent;$icon.Background=Brush '#E50A2028'}
}

function New-TechnologyBadge([string]$kind,[double]$height=24) {
    $technology='Hardware';$accent=$Cyan;$iconType=$kind.ToUpper()
    switch($kind.ToUpper()){
        'CPU'{$technology=$script:Hardware.Cpu;if($technology -match '(?i)AMD|Ryzen'){$accent=Brush '#FFED1C24';$iconType='AMD'}else{$iconType='CPU'}}
        'CLOCK'{$technology=$script:Hardware.Cpu;if($technology -match '(?i)AMD|Ryzen'){$accent=Brush '#FFED1C24';$iconType='AMD'}else{$iconType='CPU'}}
        'GPU'{$technology=$script:Hardware.GpuFullName;if($technology -match '(?i)NVIDIA|GeForce'){$accent=Brush '#FF76B900';$iconType='NVIDIA'}elseif($technology -match '(?i)AMD|Radeon'){$accent=Brush '#FFED1C24';$iconType='AMD'}else{$iconType='GPU'}}
        'VRAM'{$technology=$script:Hardware.GpuFullName;if($technology -match '(?i)NVIDIA|GeForce'){$accent=Brush '#FF76B900';$iconType='NVIDIA'}elseif($technology -match '(?i)AMD|Radeon'){$accent=Brush '#FFED1C24';$iconType='AMD'}else{$iconType='GPU'}}
        'RAM'{$technology=$script:Hardware.Memory;$accent=Brush '#FFA78BFA';$iconType='DIMM'}
        'DISK'{$technology=$script:SelectedDriveDescriptor.Subtitle;$accent=Brush '#FFFF4D5E';$iconType=if($technology -match '(?i)NVMe'){'NVME'}else{'DISK'}}
        'NETWORK'{$technology=$script:NetworkTechnology;$accent=$Cyan;$iconType=$script:NetworkTechnology}
    }
    $badge=New-Object Windows.Controls.Border;$badge.Width=44;$badge.Height=$height;$badge.CornerRadius=5
    $badge.Background=Brush '#EF091820';$badge.BorderBrush=$accent;$badge.BorderThickness=1;$badge.ToolTip=$technology
    $body=New-Object Windows.Controls.Grid
    if($iconType -in @('AMD','NVIDIA')){
        $data=if($iconType -eq 'AMD'){
            'M18.324 9.137l1.559 1.56h2.556v2.557L24 14.814V9.137zM2 9.52l-2 4.96h1.309l.37-.982H3.9l.408.982h1.338L3.432 9.52zm4.209 0v4.955h1.238v-3.092l1.338 1.562h.188l1.338-1.556v3.091h1.238V9.52H10.47l-1.592 1.845L7.287 9.52zm6.283 0v4.96h2.057c1.979 0 2.88-1.046 2.88-2.472 0-1.36-.937-2.488-2.747-2.488zm1.237.91h.792c1.17 0 1.63.711 1.63 1.57 0 .728-.372 1.572-1.616 1.572h-.806zm-10.985.273l.791 1.932H2.008zm17.137.307l-1.604 1.603v2.25h2.246l1.604-1.607h-2.246z'
        }else{
            'M8.948 8.798v-1.43a6.7 6.7 0 0 1 .424-.018c3.922-.124 6.493 3.374 6.493 3.374s-2.774 3.851-5.75 3.851c-.398 0-.787-.062-1.158-.185v-4.346c1.528.185 1.837.857 2.747 2.385l2.04-1.714s-1.492-1.952-4-1.952a6.016 6.016 0 0 0-.796.035m0-4.735v2.138l.424-.027c5.45-.185 9.01 4.47 9.01 4.47s-4.08 4.964-8.33 4.964c-.37 0-.733-.035-1.095-.097v1.325c.3.035.61.062.91.062 3.957 0 6.82-2.023 9.593-4.408.459.371 2.34 1.263 2.73 1.652-2.633 2.208-8.772 3.984-12.253 3.984-.335 0-.653-.018-.971-.053v1.864H24V4.063zm0 10.326v1.131c-3.657-.654-4.673-4.46-4.673-4.46s1.758-1.944 4.673-2.262v1.237H8.94c-1.528-.186-2.73 1.245-2.73 1.245s.68 2.412 2.739 3.11M2.456 10.9s2.164-3.197 6.5-3.533V6.201C4.153 6.59 0 10.653 0 10.653s2.35 6.802 8.948 7.42v-1.237c-4.84-.6-6.492-5.936-6.492-5.936z'
        }
        $view=New-Object Windows.Controls.Viewbox;$view.Margin='6,4';$logo=New-Object Windows.Shapes.Path;$logo.Data=[Windows.Media.Geometry]::Parse($data);$logo.Fill=$accent;$logo.Stretch='Uniform';$view.Child=$logo;$body.Children.Add($view)|Out-Null
    }elseif($iconType -eq 'DIMM'){
        $c=New-Object Windows.Controls.Canvas;$c.Width=32;$c.Height=15;$c.HorizontalAlignment='Center';$c.VerticalAlignment='Center'
        $board=New-Object Windows.Shapes.Rectangle;$board.Width=30;$board.Height=10;$board.RadiusX=1.5;$board.RadiusY=1.5;$board.Stroke=$accent;$board.StrokeThickness=1.4;[Windows.Controls.Canvas]::SetLeft($board,1);[Windows.Controls.Canvas]::SetTop($board,1);$c.Children.Add($board)|Out-Null
        foreach($x in @(4,9,14,19,24)){$chip=New-Object Windows.Shapes.Rectangle;$chip.Width=4;$chip.Height=5;$chip.RadiusX=.6;$chip.RadiusY=.6;$chip.Fill=$accent;[Windows.Controls.Canvas]::SetLeft($chip,$x);[Windows.Controls.Canvas]::SetTop($chip,3);$c.Children.Add($chip)|Out-Null}
        foreach($x in @(3,7,11,17,21,25,29)){$pin=New-Object Windows.Shapes.Line;$pin.X1=$x;$pin.X2=$x;$pin.Y1=11;$pin.Y2=14;$pin.Stroke=Brush '#FFFFD45C';$pin.StrokeThickness=1;$c.Children.Add($pin)|Out-Null}
        $body.Children.Add($c)|Out-Null
    }elseif($iconType -eq 'NVME'){
        $c=New-Object Windows.Controls.Canvas;$c.Width=34;$c.Height=15;$c.HorizontalAlignment='Center';$c.VerticalAlignment='Center'
        $board=New-Object Windows.Shapes.Rectangle;$board.Width=31;$board.Height=11;$board.RadiusX=2;$board.RadiusY=2;$board.Stroke=$accent;$board.StrokeThickness=1.4;[Windows.Controls.Canvas]::SetLeft($board,1);[Windows.Controls.Canvas]::SetTop($board,2);$c.Children.Add($board)|Out-Null
        $hole=New-Object Windows.Shapes.Ellipse;$hole.Width=3;$hole.Height=3;$hole.Stroke=$accent;$hole.StrokeThickness=1;[Windows.Controls.Canvas]::SetLeft($hole,3);[Windows.Controls.Canvas]::SetTop($hole,6);$c.Children.Add($hole)|Out-Null
        foreach($x in @(9,15,21)){$chip=New-Object Windows.Shapes.Rectangle;$chip.Width=5;$chip.Height=6;$chip.RadiusX=.7;$chip.RadiusY=.7;$chip.Fill=$accent;[Windows.Controls.Canvas]::SetLeft($chip,$x);[Windows.Controls.Canvas]::SetTop($chip,4.5);$c.Children.Add($chip)|Out-Null}
        foreach($x in @(28,30,32)){$pin=New-Object Windows.Shapes.Line;$pin.X1=$x;$pin.X2=$x;$pin.Y1=4;$pin.Y2=11;$pin.Stroke=Brush '#FFFFD45C';$pin.StrokeThickness=1;$c.Children.Add($pin)|Out-Null}
        $body.Children.Add($c)|Out-Null
    }elseif($iconType -in @('CPU','GPU','DISK')){
        $label=New-Text $iconType 11 $accent 'Bold';$label.HorizontalAlignment='Center';$label.VerticalAlignment='Center';$body.Children.Add($label)|Out-Null
    }else{
        $view=New-Object Windows.Controls.Viewbox;$view.Margin='8,3';$icon=New-Object Windows.Shapes.Path
        if($iconType -eq 'WI-FI'){$icon.Data=[Windows.Media.Geometry]::Parse('M1,8 A16,16 0 0 1 31,8 M6,13 A11,11 0 0 1 26,13 M12,18 A5,5 0 0 1 20,18 M16,21 L16.1,21')}
        else{$icon.Data=[Windows.Media.Geometry]::Parse('M4,3 L28,3 L28,16 L22,16 L22,12 L10,12 L10,16 L4,16 Z M9,6 L9,10 M14,6 L14,10 M19,6 L19,10 M24,6 L24,10')}
        $icon.Stroke=$accent;$icon.StrokeThickness=2;$icon.StrokeStartLineCap='Round';$icon.StrokeEndLineCap='Round';$icon.Stretch='Uniform';$view.Child=$icon;$body.Children.Add($view)|Out-Null
    }
    $badge.Child=$body
    $glow=New-Object Windows.Media.Effects.DropShadowEffect;$glow.Color=$accent.Color;$glow.BlurRadius=5;$glow.ShadowDepth=0;$glow.Opacity=.28;$badge.Effect=$glow
    return $badge
}

function New-ArcGeometry([double]$percent) {
    $percent = [math]::Max(0.1, [math]::Min(100, $percent))
    $start = 135.0; $sweep = 270.0 * $percent / 100.0; $end = $start + $sweep
    $cx = 110.0; $cy = 137.0; $radiusX = 72.0; $radiusY = 72.0
    $p1 = New-Object Windows.Point(($cx + $radiusX * [math]::Cos($start * [math]::PI / 180)), ($cy + $radiusY * [math]::Sin($start * [math]::PI / 180)))
    $p2 = New-Object Windows.Point(($cx + $radiusX * [math]::Cos($end * [math]::PI / 180)), ($cy + $radiusY * [math]::Sin($end * [math]::PI / 180)))
    $fig = New-Object Windows.Media.PathFigure
    $fig.StartPoint = $p1; $fig.IsClosed = $false
    $arc = New-Object Windows.Media.ArcSegment
    $arc.Point = $p2; $arc.Size = New-Object Windows.Size($radiusX, $radiusY)
    $arc.SweepDirection = 'Clockwise'; $arc.IsLargeArc = ($sweep -gt 180)
    $fig.Segments.Add($arc)
    $geo = New-Object Windows.Media.PathGeometry
    $geo.Figures.Add($fig)
    return $geo
}

function New-HistoryGeometry($history,[double]$left,[double]$top,[double]$width,[double]$height,[bool]$filled) {
    $values=@($history)
    if($values.Count -eq 0){$values=@(0.0)}
    $points=New-Object Windows.Media.PointCollection
    for($i=0;$i -lt $values.Count;$i++){
        $x=$left+$width-(($values.Count-1-$i)*$width/59.0)
        $y=$top+$height-([math]::Max(0,[math]::Min(100,[double]$values[$i]))/100.0*$height)
        $points.Add((New-Object Windows.Point($x,$y)))
    }
    $figure=New-Object Windows.Media.PathFigure
    if($filled){
        $first=$points[0]
        $figure.StartPoint=New-Object Windows.Point($first.X,($top+$height))
        $segment=New-Object Windows.Media.PolyLineSegment
        foreach($point in $points){$segment.Points.Add($point)}
        $segment.Points.Add((New-Object Windows.Point($points[$points.Count-1].X,($top+$height))))
        $figure.Segments.Add($segment);$figure.IsClosed=$true
    }else{
        $figure.StartPoint=$points[0]
        $segment=New-Object Windows.Media.PolyLineSegment
        for($i=1;$i -lt $points.Count;$i++){$segment.Points.Add($points[$i])}
        $figure.Segments.Add($segment);$figure.IsClosed=$false
    }
    $geometry=New-Object Windows.Media.PathGeometry;$geometry.Figures.Add($figure)
    return $geometry
}

function Update-GaugeHistory($g,[double]$value) {
    $null=$g.History.Add([math]::Max(0,[math]::Min(100,$value)))
    if($g.History.Count -gt 60){$g.History.RemoveAt(0)}
    $g.GraphFill.Data=New-HistoryGeometry $g.History 14 216 192 55 $true
    $g.GraphLine.Data=New-HistoryGeometry $g.History 14 216 192 55 $false
}

function New-GaugeCard([string]$title, [string]$subtitle, [string]$footerLabel, [string]$iconKind) {
    $border = New-Object Windows.Controls.Border
    $border.CornerRadius = 13; $border.BorderThickness = 1; $border.BorderBrush = $OutlineBrush
    $border.Background = New-PanelGradient; $border.Margin = '5.5'; $border.Padding = '8,9,8,8'
    $canvas = New-Object Windows.Controls.Canvas
    $canvas.Width = 220; $canvas.Height = 338; $canvas.HorizontalAlignment = 'Center'; $canvas.VerticalAlignment = 'Top'
    $base = New-Object Windows.Shapes.Path
    $base.Data = New-ArcGeometry 100; $base.Stroke = $DarkCyan; $base.StrokeThickness = 16; $base.StrokeStartLineCap = 'Flat'; $base.StrokeEndLineCap = 'Flat'
    $canvas.Children.Add($base) | Out-Null
    for ($angle = 135; $angle -le 405; $angle += 9) {
        $rad = $angle * [math]::PI / 180
        $tick = New-Object Windows.Shapes.Line
        $tick.X1 = 110 + 63 * [math]::Cos($rad); $tick.Y1 = 137 + 63 * [math]::Sin($rad)
        $tick.X2 = 110 + 81 * [math]::Cos($rad); $tick.Y2 = 137 + 81 * [math]::Sin($rad)
        $tick.Stroke = $Blue; $tick.StrokeThickness = 1.25; $tick.Opacity = .62
        $canvas.Children.Add($tick) | Out-Null
    }
    $progress = New-Object Windows.Shapes.Path
    $progress.Data = New-ArcGeometry 1; $progress.Stroke = $Cyan; $progress.StrokeThickness = 16; $progress.StrokeStartLineCap = 'Flat'; $progress.StrokeEndLineCap = 'Round'
    $glow = New-Object Windows.Media.Effects.DropShadowEffect
    $glow.Color = [Windows.Media.ColorConverter]::ConvertFromString('#009CFF'); $glow.BlurRadius = 13; $glow.ShadowDepth = 0; $glow.Opacity = .8
    $progress.Effect = $glow
    $canvas.Children.Add($progress) | Out-Null
    $headerPlate = New-Object Windows.Controls.Border; $headerPlate.Width=216; $headerPlate.Height=46; $headerPlate.CornerRadius='7,7,3,3'; $headerPlate.Background=Brush '#FF07161E'; $headerPlate.BorderBrush=Brush '#9900DCE6'; $headerPlate.BorderThickness='0,0,0,1'
    [Windows.Controls.Canvas]::SetLeft($headerPlate,2); [Windows.Controls.Canvas]::SetTop($headerPlate,0); $canvas.Children.Add($headerPlate) | Out-Null
    $titleText = New-Text $title 19 $Cyan 'Bold'; $titleText.Width = $(if($iconKind -eq 'DISK'){96}else{160}); $titleText.Height = 25; $titleText.TextAlignment='Left'
    [Windows.Controls.Canvas]::SetLeft($titleText,11); [Windows.Controls.Canvas]::SetTop($titleText,1); $canvas.Children.Add($titleText) | Out-Null
    $subText = New-Text $subtitle.ToUpper() 11 (Brush '#C2D6DF') 'SemiBold'; $subText.Width = 198; $subText.Height = 18; $subText.TextWrapping = 'NoWrap'; $subText.TextTrimming='CharacterEllipsis'; $subText.TextAlignment='Left'
    [Windows.Controls.Canvas]::SetLeft($subText,11); [Windows.Controls.Canvas]::SetTop($subText,28); $canvas.Children.Add($subText) | Out-Null
    $headerMetric=$null
    if($iconKind -eq 'DISK'){
        $capacityBadge=New-Object Windows.Controls.Border;$capacityBadge.Width=98;$capacityBadge.Height=27;$capacityBadge.CornerRadius=6;$capacityBadge.Background=Brush '#FF10232B';$capacityBadge.BorderBrush=$Cyan;$capacityBadge.BorderThickness=1.25
        $headerMetric=New-Text '-- / --' 11 $Lime 'Bold';$headerMetric.TextWrapping='NoWrap';$headerMetric.ToolTip='Drive space used / total capacity';$capacityBadge.Child=$headerMetric
        [Windows.Controls.Canvas]::SetLeft($capacityBadge,108);[Windows.Controls.Canvas]::SetTop($capacityBadge,0);$canvas.Children.Add($capacityBadge)|Out-Null
    }else{
        $headerIcon=New-TechnologyBadge $iconKind 24;[Windows.Controls.Canvas]::SetLeft($headerIcon,163);[Windows.Controls.Canvas]::SetTop($headerIcon,2);$canvas.Children.Add($headerIcon)|Out-Null
    }
    $valueHost=New-Object Windows.Controls.Grid;$valueHost.Width=180;$valueHost.Height=58
    $valueRow=New-Object Windows.Controls.StackPanel;$valueRow.Orientation='Horizontal';$valueRow.Height=58;$valueRow.HorizontalAlignment='Center'
    $valueText = New-Text '0' 45 $White 'SemiBold';$valueText.Height=58;$valueText.VerticalAlignment='Center'
    $unitText = New-Text '%' 20 $Lime 'SemiBold';$unitText.Height=30;$unitText.VerticalAlignment='Bottom';$unitText.Margin='5,0,0,8'
    $valueRow.Children.Add($valueText)|Out-Null;$valueRow.Children.Add($unitText)|Out-Null;$valueHost.Children.Add($valueRow)|Out-Null
    [Windows.Controls.Canvas]::SetLeft($valueHost,20);[Windows.Controls.Canvas]::SetTop($valueHost,108);$canvas.Children.Add($valueHost)|Out-Null
    $centerDetailLabel=$null;$centerDetailValue=$null
    $divider = New-Object Windows.Shapes.Line;$divider.X1=14;$divider.X2=206;$divider.Y1=207;$divider.Y2=207;$divider.Stroke=$OutlineBrush;$divider.StrokeThickness=1;$canvas.Children.Add($divider)|Out-Null
    $graphBg=New-Object Windows.Shapes.Rectangle;$graphBg.Width=192;$graphBg.Height=55;$graphBg.Fill=Brush '#66051118';$graphBg.Stroke=Brush '#66446B78';$graphBg.StrokeThickness=.8;[Windows.Controls.Canvas]::SetLeft($graphBg,14);[Windows.Controls.Canvas]::SetTop($graphBg,216);$canvas.Children.Add($graphBg)|Out-Null
    foreach($offset in @(13.75,27.5,41.25)){$line=New-Object Windows.Shapes.Line;$line.X1=14;$line.X2=206;$line.Y1=216+$offset;$line.Y2=216+$offset;$line.Stroke=Brush '#334D7480';$line.StrokeThickness=.6;$canvas.Children.Add($line)|Out-Null}
    foreach($offset in @(48,96,144)){$line=New-Object Windows.Shapes.Line;$line.X1=14+$offset;$line.X2=14+$offset;$line.Y1=216;$line.Y2=271;$line.Stroke=Brush '#334D7480';$line.StrokeThickness=.6;$canvas.Children.Add($line)|Out-Null}
    $graphFill=New-Object Windows.Shapes.Path;$graphFill.Fill=Brush '#3A00DDEA';$graphFill.IsHitTestVisible=$false;$canvas.Children.Add($graphFill)|Out-Null
    $graphLine=New-Object Windows.Shapes.Path;$graphLine.Stroke=$Cyan;$graphLine.StrokeThickness=1.35;$graphLine.StrokeLineJoin='Round';$graphLine.IsHitTestVisible=$false;$canvas.Children.Add($graphLine)|Out-Null
    $historyLabel=New-Text '60 SEC HISTORY' 8 (Brush '#7696A3') 'SemiBold';$historyLabel.Width=90;$historyLabel.Height=12;$historyLabel.TextAlignment='Left';[Windows.Controls.Canvas]::SetLeft($historyLabel,14);[Windows.Controls.Canvas]::SetTop($historyLabel,272);$canvas.Children.Add($historyLabel)|Out-Null
    $nowLabel=New-Text 'NOW' 8 (Brush '#7696A3') 'SemiBold';$nowLabel.Width=35;$nowLabel.Height=12;$nowLabel.TextAlignment='Right';[Windows.Controls.Canvas]::SetLeft($nowLabel,171);[Windows.Controls.Canvas]::SetTop($nowLabel,272);$canvas.Children.Add($nowLabel)|Out-Null
    $footLabel = New-Text $footerLabel 16 $Lime 'SemiBold';$footLabel.Width=200;$footLabel.Height=22;[Windows.Controls.Canvas]::SetLeft($footLabel,10);[Windows.Controls.Canvas]::SetTop($footLabel,286);$canvas.Children.Add($footLabel)|Out-Null
    $footValue = New-Text '--' 27 $White 'SemiBold';$footValue.Width=210;$footValue.Height=38;[Windows.Controls.Canvas]::SetLeft($footValue,5);[Windows.Controls.Canvas]::SetTop($footValue,307);$canvas.Children.Add($footValue)|Out-Null
    $border.Child = $canvas
    $history=New-Object Collections.ArrayList
    $card=[pscustomobject]@{ Root=$border; Progress=$progress; Title=$titleText; Subtitle=$subText; Value=$valueText; Unit=$unitText; CenterDetailLabel=$centerDetailLabel; CenterDetailValue=$centerDetailValue; FooterLabel=$footLabel; FooterValue=$footValue; History=$history; GraphLine=$graphLine; GraphFill=$graphFill; HeaderMetric=$headerMetric }
    Update-GaugeHistory $card 0
    return $card
}

function New-StatBlock([string]$title, [string]$icon, [string]$value, [string]$unit, $accent) {
    $border = New-Object Windows.Controls.Border; $border.BorderThickness = '0,0,1,0'; $border.BorderBrush = $OutlineBrush; $border.Padding = '12,7'
    $stack = New-Object Windows.Controls.StackPanel
    $headRow=New-Object Windows.Controls.StackPanel;$headRow.Orientation='Horizontal';$headRow.HorizontalAlignment='Center'
    $headIcon=New-TechnologyBadge $icon 23;$headIcon.Margin='0,0,7,0'
    $head = New-Text $title 18 $accent 'SemiBold';$headRow.Children.Add($headIcon)|Out-Null;$headRow.Children.Add($head)|Out-Null;$stack.Children.Add($headRow) | Out-Null
    $row = New-Object Windows.Controls.StackPanel; $row.Orientation = 'Horizontal'; $row.HorizontalAlignment = 'Center'; $row.Margin = '0,8,0,0'
    $val = New-Text $value 39 $White 'SemiBold'; $val.HorizontalAlignment = 'Center'
    $u = New-Text $unit 16 $Muted 'SemiBold'; $u.VerticalAlignment = 'Bottom'; $u.Margin = '6,0,0,7'
    $row.Children.Add($val) | Out-Null; $row.Children.Add($u) | Out-Null; $stack.Children.Add($row) | Out-Null
    $border.Child = $stack
    [pscustomobject]@{ Root=$border; Value=$val; Unit=$u; Icon=$headIcon; Title=$head }
}

function New-NetworkBlock {
    $root=New-Object Windows.Controls.Grid
    $flatButtonTemplate=[Windows.Markup.XamlReader]::Parse('<ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" TargetType="{x:Type Button}"><Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border></ControlTemplate>')
    1..2|ForEach-Object{$col=New-Object Windows.Controls.ColumnDefinition;$col.Width='*';$root.ColumnDefinitions.Add($col)}
    $border = New-Object Windows.Controls.Border; $border.Padding='10,7';$border.BorderThickness='0,0,1,0';$border.BorderBrush=$OutlineBrush
    $stack = New-Object Windows.Controls.StackPanel
    $headRow=New-Object Windows.Controls.StackPanel;$headRow.Orientation='Horizontal';$headRow.HorizontalAlignment='Center'
    $headIcon=New-TechnologyBadge 'NETWORK' 22;$headIcon.Margin='0,0,6,0';$head=New-Text 'NETWORK' 17 $Cyan 'SemiBold'
    $headRow.Children.Add($headIcon)|Out-Null;$headRow.Children.Add($head)|Out-Null;$stack.Children.Add($headRow)|Out-Null
    $channels = New-Object Windows.Controls.Grid; $channels.Margin='2,5,2,0'
    1..2|ForEach-Object{$col=New-Object Windows.Controls.ColumnDefinition;$col.Width='*';$channels.ColumnDefinitions.Add($col)}
    $downStack=New-Object Windows.Controls.StackPanel
    $downHeader=New-Object Windows.Controls.Border;$downHeader.CornerRadius=5;$downHeader.Padding='5,2';$downHeader.Margin='2,0,4,0';$downHeader.Background=Brush '#2410BFD0';$downHeader.BorderBrush=Brush '#6600EAF2';$downHeader.BorderThickness=1
    $downHeaderRow=New-Object Windows.Controls.StackPanel;$downHeaderRow.Orientation='Horizontal';$downHeaderRow.HorizontalAlignment='Center'
    $downArrow=New-Text ([string][char]0x2193) 19 $Cyan 'Bold';$downArrow.FontFamily='Segoe UI Symbol';$downArrow.Margin='0,-3,5,-2';$downArrow.ToolTip='Download — data received'
    $downLabel=New-Text 'DOWNLOAD' 11.5 $Cyan 'Bold';$downHeaderRow.Children.Add($downArrow)|Out-Null;$downHeaderRow.Children.Add($downLabel)|Out-Null;$downHeader.Child=$downHeaderRow
    $downRow=New-Object Windows.Controls.StackPanel;$downRow.Orientation='Horizontal';$downRow.HorizontalAlignment='Center';$downRow.Margin='0,2,0,0'
    $downValue=New-Text '0.0' 22 $White 'SemiBold';$downUnit=New-Text 'MB/s' 10 $Muted 'SemiBold';$downUnit.Margin='4,5,0,0';$downRow.Children.Add($downValue)|Out-Null;$downRow.Children.Add($downUnit)|Out-Null
    $downStack.Children.Add($downHeader)|Out-Null;$downStack.Children.Add($downRow)|Out-Null;$channels.Children.Add($downStack)|Out-Null
    $upStack=New-Object Windows.Controls.StackPanel
    $upHeader=New-Object Windows.Controls.Border;$upHeader.CornerRadius=5;$upHeader.Padding='5,2';$upHeader.Margin='4,0,2,0';$upHeader.Background=Brush '#241C2900';$upHeader.BorderBrush=Brush '#66C8F000';$upHeader.BorderThickness=1
    $upHeaderRow=New-Object Windows.Controls.StackPanel;$upHeaderRow.Orientation='Horizontal';$upHeaderRow.HorizontalAlignment='Center'
    $upArrow=New-Text ([string][char]0x2191) 19 $Lime 'Bold';$upArrow.FontFamily='Segoe UI Symbol';$upArrow.Margin='0,-3,5,-2';$upArrow.ToolTip='Upload — data sent'
    $upLabel=New-Text 'UPLOAD' 11.5 $Lime 'Bold';$upHeaderRow.Children.Add($upArrow)|Out-Null;$upHeaderRow.Children.Add($upLabel)|Out-Null;$upHeader.Child=$upHeaderRow
    $upRow=New-Object Windows.Controls.StackPanel;$upRow.Orientation='Horizontal';$upRow.HorizontalAlignment='Center';$upRow.Margin='0,2,0,0'
    $upValue=New-Text '0.0' 22 $White 'SemiBold';$upUnit=New-Text 'MB/s' 10 $Muted 'SemiBold';$upUnit.Margin='4,5,0,0';$upRow.Children.Add($upValue)|Out-Null;$upRow.Children.Add($upUnit)|Out-Null
    $upStack.Children.Add($upHeader)|Out-Null;$upStack.Children.Add($upRow)|Out-Null;[Windows.Controls.Grid]::SetColumn($upStack,1);$channels.Children.Add($upStack)|Out-Null
    $stack.Children.Add($channels)|Out-Null;$border.Child=$stack;$root.Children.Add($border)|Out-Null

    $deviceGrid=New-Object Windows.Controls.Grid;[Windows.Controls.Grid]::SetColumn($deviceGrid,1)
    1..2|ForEach-Object{$row=New-Object Windows.Controls.RowDefinition;$row.Height='*';$deviceGrid.RowDefinitions.Add($row)}
    $speakerCell=New-Object Windows.Controls.Border;$speakerCell.BorderThickness=0;$speakerCell.BorderBrush=$OutlineBrush;$speakerCell.Padding='10,5';$speakerCell.Background=Brush '#01000000'
    $speakerCell.Add_MouseEnter({$this.Background=Brush '#3315C8D4'});$speakerCell.Add_MouseLeave({$this.Background=Brush '#01000000'})
    $speakerRow=New-Object Windows.Controls.Grid;$speakerRow.Margin='8,0,8,0';$speakerRow.HorizontalAlignment='Stretch'
    $speakerIconColumn=New-Object Windows.Controls.ColumnDefinition;$speakerIconColumn.Width='Auto';$speakerRow.ColumnDefinitions.Add($speakerIconColumn)
    $speakerTextColumn=New-Object Windows.Controls.ColumnDefinition;$speakerTextColumn.Width='*';$speakerRow.ColumnDefinitions.Add($speakerTextColumn)
    $speakerValueColumn=New-Object Windows.Controls.ColumnDefinition;$speakerValueColumn.Width=78;$speakerRow.ColumnDefinitions.Add($speakerValueColumn)
    $speakerIcon=New-VectorIcon 'AUDIO' $Cyan 34;$speakerIcon.Margin='0,0,8,0'
    $speakerMuteButton=New-Object Windows.Controls.Button;$speakerMuteButton.Template=$flatButtonTemplate;$speakerMuteButton.Background=Brush '#01000000';$speakerMuteButton.BorderThickness=0;$speakerMuteButton.Padding=0;$speakerMuteButton.Cursor='Hand';$speakerMuteButton.Focusable=$false;$speakerMuteButton.ToolTip='Click to mute or unmute the default audio output';$speakerMuteButton.Content=$speakerIcon
    $speakerText=New-Object Windows.Controls.StackPanel;$speakerTitle=New-Text 'AUDIO OUTPUT' 14 $Cyan 'SemiBold';$speakerTitle.HorizontalAlignment='Left';$speakerTitle.Cursor='Hand';$speakerTitle.ToolTip='Click to switch to the next available audio output'
    $speakerDevice=New-Text 'DEFAULT DEVICE' 12 $Muted 'SemiBold';$speakerDevice.HorizontalAlignment='Stretch';$speakerDevice.TextAlignment='Left';$speakerDevice.TextTrimming='CharacterEllipsis';$speakerDevice.TextWrapping='NoWrap';$speakerDevice.Cursor='Hand';$speakerDevice.ToolTip='Click to switch to the next available audio output'
    $speakerSwitchStack=New-Object Windows.Controls.StackPanel;$speakerSwitchStack.Children.Add($speakerTitle)|Out-Null;$speakerSwitchStack.Children.Add($speakerDevice)|Out-Null
    $speakerSwitchButton=New-Object Windows.Controls.Button;$speakerSwitchButton.Template=$flatButtonTemplate;$speakerSwitchButton.Background=Brush '#01000000';$speakerSwitchButton.BorderThickness=0;$speakerSwitchButton.Padding=0;$speakerSwitchButton.HorizontalAlignment='Stretch';$speakerSwitchButton.HorizontalContentAlignment='Stretch';$speakerSwitchButton.Cursor='Hand';$speakerSwitchButton.Focusable=$false;$speakerSwitchButton.ToolTip='Click to switch to the next available audio output';$speakerSwitchButton.Content=$speakerSwitchStack
    $speakerValue=New-Text '--' 17.5 $White 'SemiBold';$speakerValue.HorizontalAlignment='Stretch';$speakerValue.VerticalAlignment='Center';$speakerValue.TextAlignment='Center';$speakerValue.TextWrapping='NoWrap';$speakerValue.Margin='4,0,0,0'
    $speakerSlider=New-NeonSlider '#00EAF2';$speakerSlider.Margin='6,2,6,0';$speakerSlider.HorizontalAlignment='Center';$speakerSlider.ToolTip='Audio output volume'
    $speakerPanel=New-Object Windows.Controls.StackPanel
    $speakerText.Children.Add($speakerSwitchButton)|Out-Null;[Windows.Controls.Grid]::SetColumn($speakerMuteButton,0);$speakerRow.Children.Add($speakerMuteButton)|Out-Null;[Windows.Controls.Grid]::SetColumn($speakerText,1);$speakerRow.Children.Add($speakerText)|Out-Null;[Windows.Controls.Grid]::SetColumn($speakerValue,2);$speakerRow.Children.Add($speakerValue)|Out-Null;$speakerPanel.Children.Add($speakerRow)|Out-Null;$speakerPanel.Children.Add($speakerSlider)|Out-Null;$speakerCell.Child=$speakerPanel;$deviceGrid.Children.Add($speakerCell)|Out-Null

    $micCell=New-Object Windows.Controls.Border;$micCell.Padding='10,5';$micCell.Background=Brush '#01000000';$micCell.BorderThickness=0;[Windows.Controls.Grid]::SetRow($micCell,1)
    $micCell.Add_MouseEnter({$this.Background=Brush '#3320D96B'});$micCell.Add_MouseLeave({$this.Background=Brush '#01000000'})
    $micRow=New-Object Windows.Controls.Grid;$micRow.Margin='8,0,8,0';$micRow.HorizontalAlignment='Stretch'
    $micIconColumn=New-Object Windows.Controls.ColumnDefinition;$micIconColumn.Width='Auto';$micRow.ColumnDefinitions.Add($micIconColumn)
    $micTextColumn=New-Object Windows.Controls.ColumnDefinition;$micTextColumn.Width='*';$micRow.ColumnDefinitions.Add($micTextColumn)
    $micValueColumn=New-Object Windows.Controls.ColumnDefinition;$micValueColumn.Width=78;$micRow.ColumnDefinitions.Add($micValueColumn)
    $micIcon=New-VectorIcon 'MIC' $Lime 34;$micIcon.Margin='0,0,8,0'
    $micMuteButton=New-Object Windows.Controls.Button;$micMuteButton.Template=$flatButtonTemplate;$micMuteButton.Background=Brush '#01000000';$micMuteButton.BorderThickness=0;$micMuteButton.Padding=0;$micMuteButton.Cursor='Hand';$micMuteButton.Focusable=$false;$micMuteButton.ToolTip='Click to mute or unmute the default microphone';$micMuteButton.Content=$micIcon
    $micText=New-Object Windows.Controls.StackPanel;$micTitle=New-Text 'MICROPHONE' 14 $Lime 'SemiBold';$micTitle.HorizontalAlignment='Left';$micTitle.Cursor='Hand';$micTitle.ToolTip='Click to switch to the next available microphone'
    $micDevice=New-Text 'DEFAULT DEVICE' 12 $Muted 'SemiBold';$micDevice.HorizontalAlignment='Stretch';$micDevice.TextAlignment='Left';$micDevice.TextTrimming='CharacterEllipsis';$micDevice.TextWrapping='NoWrap';$micDevice.Cursor='Hand';$micDevice.ToolTip='Click to switch to the next available microphone'
    $micSwitchStack=New-Object Windows.Controls.StackPanel;$micSwitchStack.Children.Add($micTitle)|Out-Null;$micSwitchStack.Children.Add($micDevice)|Out-Null
    $micSwitchButton=New-Object Windows.Controls.Button;$micSwitchButton.Template=$flatButtonTemplate;$micSwitchButton.Background=Brush '#01000000';$micSwitchButton.BorderThickness=0;$micSwitchButton.Padding=0;$micSwitchButton.HorizontalAlignment='Stretch';$micSwitchButton.HorizontalContentAlignment='Stretch';$micSwitchButton.Cursor='Hand';$micSwitchButton.Focusable=$false;$micSwitchButton.ToolTip='Click to switch to the next available microphone';$micSwitchButton.Content=$micSwitchStack
    $micValue=New-Text '--' 17.5 $White 'SemiBold';$micValue.HorizontalAlignment='Stretch';$micValue.VerticalAlignment='Center';$micValue.TextAlignment='Center';$micValue.TextWrapping='NoWrap';$micValue.Margin='4,0,0,0'
    $micSlider=New-NeonSlider '#C8F000';$micSlider.Margin='6,2,6,0';$micSlider.HorizontalAlignment='Center';$micSlider.ToolTip='Microphone input level'
    $micSignalRow=New-Object Windows.Controls.StackPanel;$micSignalRow.Orientation='Horizontal';$micSignalRow.HorizontalAlignment='Center';$micSignalRow.Margin='0,-1,0,0';$micSignalRow.ToolTip='Live microphone signal level'
    $micSignalLabel=New-Text 'SIGNAL' 9 $Lime 'Bold';$micSignalLabel.Width=39;$micSignalLabel.TextAlignment='Left'
    $micSignalTrack=New-Object Windows.Controls.Border;$micSignalTrack.Width=100;$micSignalTrack.Height=8;$micSignalTrack.CornerRadius=4;$micSignalTrack.Padding=1;$micSignalTrack.Margin='4,0,5,0';$micSignalTrack.Background=Brush '#FF102A34';$micSignalTrack.BorderBrush=Brush '#704D7581';$micSignalTrack.BorderThickness=1
    $micSignalFill=New-Object Windows.Controls.Border;$micSignalFill.Width=0;$micSignalFill.Height=4;$micSignalFill.CornerRadius=2;$micSignalFill.HorizontalAlignment='Left';$micSignalFill.Background=$Lime;$micSignalTrack.Child=$micSignalFill
    $micSignalValue=New-Text '0%' 9 $Muted 'SemiBold';$micSignalValue.Width=30;$micSignalValue.TextAlignment='Right'
    $micSignalRow.Children.Add($micSignalLabel)|Out-Null;$micSignalRow.Children.Add($micSignalTrack)|Out-Null;$micSignalRow.Children.Add($micSignalValue)|Out-Null
    $micPanel=New-Object Windows.Controls.StackPanel
    $micText.Children.Add($micSwitchButton)|Out-Null;[Windows.Controls.Grid]::SetColumn($micMuteButton,0);$micRow.Children.Add($micMuteButton)|Out-Null;[Windows.Controls.Grid]::SetColumn($micText,1);$micRow.Children.Add($micText)|Out-Null;[Windows.Controls.Grid]::SetColumn($micValue,2);$micRow.Children.Add($micValue)|Out-Null;$micPanel.Children.Add($micRow)|Out-Null;$micPanel.Children.Add($micSlider)|Out-Null;$micPanel.Children.Add($micSignalRow)|Out-Null;$micCell.Child=$micPanel;$deviceGrid.Children.Add($micCell)|Out-Null
    $deviceSeparator=New-Object Windows.Controls.Border;$deviceSeparator.Height=1;$deviceSeparator.Background=$OutlineBrush;$deviceSeparator.Margin='11,0,11,0';$deviceSeparator.VerticalAlignment='Top';$deviceSeparator.IsHitTestVisible=$false;[Windows.Controls.Grid]::SetRow($deviceSeparator,1);[Windows.Controls.Panel]::SetZIndex($deviceSeparator,5);$deviceGrid.Children.Add($deviceSeparator)|Out-Null
    $root.Children.Add($deviceGrid)|Out-Null
    [pscustomobject]@{Root=$root;Download=$downValue;DownloadUnit=$downUnit;Upload=$upValue;UploadUnit=$upUnit;SpeakerValue=$speakerValue;SpeakerTitle=$speakerTitle;SpeakerDevice=$speakerDevice;SpeakerIcon=$speakerIcon;SpeakerButton=$speakerMuteButton;SpeakerSwitchButton=$speakerSwitchButton;SpeakerSlider=$speakerSlider;MicValue=$micValue;MicTitle=$micTitle;MicDevice=$micDevice;MicIcon=$micIcon;MicButton=$micMuteButton;MicSwitchButton=$micSwitchButton;MicSlider=$micSlider;MicSignalFill=$micSignalFill;MicSignalValue=$micSignalValue}
}

function Set-NetworkRateDisplay($valueText,$unitText,[double]$bytesPerSecond) {
    $rate=[math]::Max(0,$bytesPerSecond)
    if($rate -le 0){$valueText.Text='0';$unitText.Text='B/s';return}
    if($rate -lt 1){$valueText.Text='<1';$unitText.Text='B/s';return}
    if($rate -lt 1KB){$valueText.Text=('{0:N0}' -f $rate);$unitText.Text='B/s';return}
    if($rate -lt 1MB){$valueText.Text=('{0:N1}' -f ($rate/1KB));$unitText.Text='KB/s';return}
    if($rate -lt 1GB){$valueText.Text=('{0:N1}' -f ($rate/1MB));$unitText.Text='MB/s';return}
    $valueText.Text=('{0:N2}' -f ($rate/1GB));$unitText.Text='GB/s'
}

function New-FlagIcon([string]$country) {
    $flag = New-Object Windows.Controls.Grid; $flag.Width=23; $flag.Height=14; $flag.Margin='8,0,0,0'; $flag.ClipToBounds=$true
    if ($country -eq 'PH') {
        $r1=New-Object Windows.Controls.RowDefinition; $r1.Height='*'; $r2=New-Object Windows.Controls.RowDefinition; $r2.Height='*'; $flag.RowDefinitions.Add($r1); $flag.RowDefinitions.Add($r2)
        $b=New-Object Windows.Controls.Border; $b.Background=Brush '#0038A8'; [Windows.Controls.Grid]::SetRow($b,0); $flag.Children.Add($b)|Out-Null
        $r=New-Object Windows.Controls.Border; $r.Background=Brush '#CE1126'; [Windows.Controls.Grid]::SetRow($r,1); $flag.Children.Add($r)|Out-Null
        $tri=New-Object Windows.Shapes.Polygon; $tri.Fill=[Windows.Media.Brushes]::White; $tri.Points=[Windows.Media.PointCollection]::Parse('0,0 0,14 11,7'); [Windows.Controls.Grid]::SetRowSpan($tri,2); $flag.Children.Add($tri)|Out-Null
        $sun=New-Object Windows.Shapes.Ellipse; $sun.Width=3; $sun.Height=3; $sun.Fill=Brush '#FCD116'; $sun.HorizontalAlignment='Left'; $sun.VerticalAlignment='Center'; $sun.Margin='3,0,0,0'; [Windows.Controls.Grid]::SetRowSpan($sun,2); $flag.Children.Add($sun)|Out-Null
    } elseif ($country -eq 'AU') {
        $flag.Background=Brush '#012169'
        $whiteH=New-Object Windows.Controls.Border; $whiteH.Width=11; $whiteH.Height=3; $whiteH.Background=[Windows.Media.Brushes]::White; $whiteH.HorizontalAlignment='Left'; $whiteH.VerticalAlignment='Top'; $whiteH.Margin='0,3,0,0'; $flag.Children.Add($whiteH)|Out-Null
        $whiteV=New-Object Windows.Controls.Border; $whiteV.Width=3; $whiteV.Height=8; $whiteV.Background=[Windows.Media.Brushes]::White; $whiteV.HorizontalAlignment='Left'; $whiteV.VerticalAlignment='Top'; $whiteV.Margin='4,0,0,0'; $flag.Children.Add($whiteV)|Out-Null
        $redH=New-Object Windows.Controls.Border; $redH.Width=11; $redH.Height=1; $redH.Background=Brush '#C8102E'; $redH.HorizontalAlignment='Left'; $redH.VerticalAlignment='Top'; $redH.Margin='0,4,0,0'; $flag.Children.Add($redH)|Out-Null
        $redV=New-Object Windows.Controls.Border; $redV.Width=1; $redV.Height=8; $redV.Background=Brush '#C8102E'; $redV.HorizontalAlignment='Left'; $redV.VerticalAlignment='Top'; $redV.Margin='5,0,0,0'; $flag.Children.Add($redV)|Out-Null
        foreach($pt in @(@(16,3),@(19,7),@(14,10),@(20,12))){$star=New-Object Windows.Shapes.Ellipse;$star.Width=2;$star.Height=2;$star.Fill=[Windows.Media.Brushes]::White;$star.HorizontalAlignment='Left';$star.VerticalAlignment='Top';$star.Margin=("{0},{1},0,0" -f $pt[0],$pt[1]);$flag.Children.Add($star)|Out-Null}
    } elseif ($country -eq 'IN') {
        foreach($color in @('#FF9933','#FFFFFF','#138808')){$row=New-Object Windows.Controls.RowDefinition;$row.Height='*';$flag.RowDefinitions.Add($row);$band=New-Object Windows.Controls.Border;$band.Background=Brush $color;[Windows.Controls.Grid]::SetRow($band,$flag.Children.Count);$flag.Children.Add($band)|Out-Null}
        $wheel=New-Object Windows.Shapes.Ellipse;$wheel.Width=4;$wheel.Height=4;$wheel.Stroke=Brush '#000080';$wheel.StrokeThickness=1;$wheel.HorizontalAlignment='Center';$wheel.VerticalAlignment='Center';[Windows.Controls.Grid]::SetRowSpan($wheel,3);$flag.Children.Add($wheel)|Out-Null
    } elseif ($country -eq 'JP') {
        $flag.Background=[Windows.Media.Brushes]::White
        $disc=New-Object Windows.Shapes.Ellipse;$disc.Width=7;$disc.Height=7;$disc.Fill=Brush '#BC002D';$disc.HorizontalAlignment='Center';$disc.VerticalAlignment='Center';$flag.Children.Add($disc)|Out-Null
    } elseif ($country -eq 'GB') {
        $flag.Background=Brush '#012169'
        $whiteH=New-Object Windows.Controls.Border;$whiteH.Height=4;$whiteH.Background=[Windows.Media.Brushes]::White;$whiteH.VerticalAlignment='Center';$flag.Children.Add($whiteH)|Out-Null
        $whiteV=New-Object Windows.Controls.Border;$whiteV.Width=4;$whiteV.Background=[Windows.Media.Brushes]::White;$whiteV.HorizontalAlignment='Center';$flag.Children.Add($whiteV)|Out-Null
        $redH=New-Object Windows.Controls.Border;$redH.Height=2;$redH.Background=Brush '#C8102E';$redH.VerticalAlignment='Center';$flag.Children.Add($redH)|Out-Null
        $redV=New-Object Windows.Controls.Border;$redV.Width=2;$redV.Background=Brush '#C8102E';$redV.HorizontalAlignment='Center';$flag.Children.Add($redV)|Out-Null
    } elseif ($country -eq 'DE') {
        foreach($color in @('#000000','#DD0000','#FFCE00')){$row=New-Object Windows.Controls.RowDefinition;$row.Height='*';$flag.RowDefinitions.Add($row);$band=New-Object Windows.Controls.Border;$band.Background=Brush $color;[Windows.Controls.Grid]::SetRow($band,$flag.Children.Count);$flag.Children.Add($band)|Out-Null}
    } elseif ($country -eq 'AE') {
        foreach($color in @('#00732F','#FFFFFF','#000000')){$row=New-Object Windows.Controls.RowDefinition;$row.Height='*';$flag.RowDefinitions.Add($row);$band=New-Object Windows.Controls.Border;$band.Background=Brush $color;[Windows.Controls.Grid]::SetRow($band,$flag.Children.Count);$flag.Children.Add($band)|Out-Null}
        $red=New-Object Windows.Controls.Border;$red.Width=6;$red.Background=Brush '#FF0000';$red.HorizontalAlignment='Left';[Windows.Controls.Grid]::SetRowSpan($red,3);$flag.Children.Add($red)|Out-Null
    } elseif ($country -eq 'SG') {
        $r1=New-Object Windows.Controls.RowDefinition;$r1.Height='*';$r2=New-Object Windows.Controls.RowDefinition;$r2.Height='*';$flag.RowDefinitions.Add($r1);$flag.RowDefinitions.Add($r2)
        $top=New-Object Windows.Controls.Border;$top.Background=Brush '#EF3340';$flag.Children.Add($top)|Out-Null;$bottom=New-Object Windows.Controls.Border;$bottom.Background=[Windows.Media.Brushes]::White;[Windows.Controls.Grid]::SetRow($bottom,1);$flag.Children.Add($bottom)|Out-Null
        $moon=New-Object Windows.Shapes.Ellipse;$moon.Width=5;$moon.Height=5;$moon.Stroke=[Windows.Media.Brushes]::White;$moon.StrokeThickness=1;$moon.HorizontalAlignment='Left';$moon.VerticalAlignment='Top';$moon.Margin='3,1,0,0';$flag.Children.Add($moon)|Out-Null
    } elseif ($country -eq 'HK') {
        $flag.Background=Brush '#DE2910';$flower=New-Object Windows.Shapes.Ellipse;$flower.Width=6;$flower.Height=6;$flower.Fill=[Windows.Media.Brushes]::White;$flower.HorizontalAlignment='Center';$flower.VerticalAlignment='Center';$flag.Children.Add($flower)|Out-Null
    } else {
        for($n=0;$n -lt 7;$n++){$row=New-Object Windows.Controls.RowDefinition;$row.Height='*';$flag.RowDefinitions.Add($row);$stripe=New-Object Windows.Controls.Border;$stripe.Background=if(($n%2)-eq 0){Brush '#B22234'}else{[Windows.Media.Brushes]::White};[Windows.Controls.Grid]::SetRow($stripe,$n);$flag.Children.Add($stripe)|Out-Null}
        $canton=New-Object Windows.Controls.Border;$canton.Width=10;$canton.Height=8;$canton.Background=Brush '#3C3B6E';$canton.HorizontalAlignment='Left';$canton.VerticalAlignment='Top';[Windows.Controls.Grid]::SetRowSpan($canton,4);$flag.Children.Add($canton)|Out-Null
        foreach($pt in @(@(2,1),@(5,1),@(8,1),@(3,4),@(7,4))){$star=New-Object Windows.Shapes.Ellipse;$star.Width=1;$star.Height=1;$star.Fill=[Windows.Media.Brushes]::White;$star.HorizontalAlignment='Left';$star.VerticalAlignment='Top';$star.Margin=("{0},{1},0,0" -f $pt[0],$pt[1]);[Windows.Controls.Grid]::SetRowSpan($star,7);$flag.Children.Add($star)|Out-Null}
    }
    return $flag
}

$script:DesignWidth = 1015.0
$script:DesignHeight = 678.0
$script:WorkArea = [Windows.SystemParameters]::WorkArea
function Get-ResponsiveWindowSize {
    # Keep a small desktop margin and preserve the original design ratio.
    $scaleX = [math]::Max(.55, ($script:WorkArea.Width - 36) / $script:DesignWidth)
    $scaleY = [math]::Max(.55, ($script:WorkArea.Height - 36) / $script:DesignHeight)
    $scale = [math]::Min(1.35, [math]::Min($scaleX, $scaleY) * .90)
    [pscustomobject]@{ Width=[math]::Round($script:DesignWidth*$scale); Height=[math]::Round($script:DesignHeight*$scale) }
}
$responsiveSize = Get-ResponsiveWindowSize
$window = New-Object Windows.Window
$window.Title = $script:AppName; $window.Width = $responsiveSize.Width; $window.Height = $responsiveSize.Height
$window.WindowStyle = 'None'; $window.AllowsTransparency = $true; $window.Background = [Windows.Media.Brushes]::Transparent
$window.Topmost = $true; $window.ResizeMode = 'CanResizeWithGrip'; $window.ShowInTaskbar = $false
$window.MinWidth = [math]::Round($script:DesignWidth*.62); $window.MinHeight = [math]::Round($script:DesignHeight*.62)
$window.MaxWidth = $script:WorkArea.Width; $window.MaxHeight = $script:WorkArea.Height
$window.Left = [Windows.SystemParameters]::WorkArea.Right - $window.Width - 18
$window.Top = [Windows.SystemParameters]::WorkArea.Top + 18

if (Test-Path $script:ConfigFile) {
    try {
        $cfg = Get-Content $script:ConfigFile -Raw | ConvertFrom-Json
        if ($cfg.Left -ge [Windows.SystemParameters]::VirtualScreenLeft -and $cfg.Left -lt [Windows.SystemParameters]::VirtualScreenWidth) { $window.Left = $cfg.Left }
        if ($cfg.Top -ge [Windows.SystemParameters]::VirtualScreenTop -and $cfg.Top -lt [Windows.SystemParameters]::VirtualScreenHeight) { $window.Top = $cfg.Top }
        # Restore a manual size only when the display work area has not changed.
        if ($cfg.Width -and $cfg.Height -and $cfg.WorkAreaWidth -eq [math]::Round($script:WorkArea.Width) -and $cfg.WorkAreaHeight -eq [math]::Round($script:WorkArea.Height)) {
            $window.Width = [math]::Min($window.MaxWidth,[math]::Max($window.MinWidth,[double]$cfg.Width))
            $window.Height = [math]::Min($window.MaxHeight,[math]::Max($window.MinHeight,[double]$cfg.Height))
        }
        if ($null -ne $cfg.Opacity) {
            $window.Opacity = [math]::Min(1,[math]::Max(0,[double]$cfg.Opacity))
        }
    } catch {}
}
# A size change or a previous monitor position must never leave the widget off-screen.
$window.Left = [math]::Min($script:WorkArea.Right-$window.Width,[math]::Max($script:WorkArea.Left,$window.Left))
$window.Top = [math]::Min($script:WorkArea.Bottom-$window.Height,[math]::Max($script:WorkArea.Top,$window.Top))
$script:IsWidgetMaximized=$false
$script:IsWidgetCompact=$false
$script:MinimizedByButton=$false
$script:RestoreBounds=[pscustomobject]@{Left=$window.Left;Top=$window.Top;Width=$window.Width;Height=$window.Height}

function Set-WidgetBounds($bounds) {
    $window.Width=[math]::Min($window.MaxWidth,[math]::Max($window.MinWidth,[double]$bounds.Width))
    $window.Height=[math]::Min($window.MaxHeight,[math]::Max($window.MinHeight,[double]$bounds.Height))
    $window.Left=[math]::Min($script:WorkArea.Right-$window.Width,[math]::Max($script:WorkArea.Left,[double]$bounds.Left))
    $window.Top=[math]::Min($script:WorkArea.Bottom-$window.Height,[math]::Max($script:WorkArea.Top,[double]$bounds.Top))
}
function Restore-WidgetSize {
    $script:IsWidgetMaximized=$false;$script:IsWidgetCompact=$false
    Set-WidgetBounds $script:RestoreBounds
}
function Show-Widget {
    if($window.WindowState -eq 'Minimized'){$window.WindowState='Normal'}
    $window.ShowInTaskbar=$false
    if(-not $window.IsVisible){$window.Show()}
    $window.Activate()|Out-Null
}
function New-WindowControl([string]$symbol,[string]$tip,$accent) {
    $button=New-Object Windows.Controls.Button;$button.Width=24;$button.Height=22;$button.Margin='2,0';$button.Padding=0;$button.Focusable=$false
    $button.Background=Brush '#FF0A171D';$button.BorderBrush=Brush '#70496D78';$button.BorderThickness=1;$button.Cursor='Hand';$button.ToolTip=$tip
    $label=New-Text $symbol 13 $accent 'SemiBold';$button.Content=$label
    $button.Add_MouseEnter({$this.Background=Brush '#FF12313B';$this.BorderBrush=$Cyan})
    $button.Add_MouseLeave({$this.Background=Brush '#D00A171D';$this.BorderBrush=Brush '#70496D78'})
    return $button
}

$outer = New-Object Windows.Controls.Border; $outer.Width=$script:DesignWidth; $outer.Height=$script:DesignHeight; $outer.CornerRadius = 12; $outer.BorderThickness = 1; $outer.BorderBrush = Brush '#4D65717A'; $outer.Background = Brush '#FF000000'; $outer.Padding = 12
$shadow = New-Object Windows.Media.Effects.DropShadowEffect; $shadow.Color = [Windows.Media.Colors]::Black; $shadow.BlurRadius = 30; $shadow.ShadowDepth = 6; $shadow.Opacity = .75; $outer.Effect = $shadow
$layout = New-Object Windows.Controls.Grid
foreach ($h in @('64','*','184','30')) { $r = New-Object Windows.Controls.RowDefinition; $r.Height = $h; $layout.RowDefinitions.Add($r) }

$header = New-Object Windows.Controls.Grid; $header.Margin = '8,0,8,4'
1..4 | ForEach-Object { $c=New-Object Windows.Controls.ColumnDefinition; $c.Width='*'; $header.ColumnDefinitions.Add($c) }
$script:ClockTexts = @()
$script:ClockZoneCatalog=@(
    [pscustomobject]@{Key='MNL';Name='Manila';Zone='Singapore Standard Time';Flag='PH'},
    [pscustomobject]@{Key='SYD';Name='Sydney';Zone='AUS Eastern Standard Time';Flag='AU'},
    [pscustomobject]@{Key='BLR';Name='Bengaluru';Zone='India Standard Time';Flag='IN'},
    [pscustomobject]@{Key='CHI';Name='Chicago';Zone='Central Standard Time';Flag='US'},
    [pscustomobject]@{Key='NYC';Name='New York';Zone='Eastern Standard Time';Flag='US'},
    [pscustomobject]@{Key='LAX';Name='Los Angeles';Zone='Pacific Standard Time';Flag='US'},
    [pscustomobject]@{Key='LON';Name='London';Zone='GMT Standard Time';Flag='GB'},
    [pscustomobject]@{Key='BER';Name='Berlin';Zone='W. Europe Standard Time';Flag='DE'},
    [pscustomobject]@{Key='DXB';Name='Dubai';Zone='Arabian Standard Time';Flag='AE'},
    [pscustomobject]@{Key='TYO';Name='Tokyo';Zone='Tokyo Standard Time';Flag='JP'},
    [pscustomobject]@{Key='SIN';Name='Singapore';Zone='Singapore Standard Time';Flag='SG'},
    [pscustomobject]@{Key='HKG';Name='Hong Kong';Zone='China Standard Time';Flag='HK'}
)
$defaultZoneKeys=@('MNL','SYD','BLR','CHI')
$savedZoneKeys=if($cfg -and @($cfg.ClockZones).Count -eq 4){@($cfg.ClockZones)}else{$defaultZoneKeys}
$zones=@()
for($i=0;$i -lt 4;$i++){
    $zoneDefinition=$script:ClockZoneCatalog|Where-Object Key -eq ([string]$savedZoneKeys[$i])|Select-Object -First 1
    if(-not $zoneDefinition){$zoneDefinition=$script:ClockZoneCatalog|Where-Object Key -eq $defaultZoneKeys[$i]|Select-Object -First 1}
    $zones+=$zoneDefinition
}
for ($i=0; $i -lt 4; $i++) {
    $zoneDefinition=$zones[$i]
    $cellBorder = New-Object Windows.Controls.Border
    $cellBorder.Padding = '10,0'; $cellBorder.Margin = '0,3';$cellBorder.Tag=$i;$cellBorder.Cursor='Hand';$cellBorder.ToolTip='Ctrl+click to choose this clock time zone'
    if ($i -lt 3) { $cellBorder.BorderThickness = '0,0,1,0'; $cellBorder.BorderBrush = Brush '#3C5360' }
    $cell = New-Object Windows.Controls.StackPanel
    $topRow = New-Object Windows.Controls.StackPanel; $topRow.Orientation='Horizontal'; $topRow.HorizontalAlignment='Left'
    $lab = New-Text $zoneDefinition.Key 17 $Cyan 'SemiBold'; $lab.Margin='0,0,9,0'
    $tm = New-Text '--:--' 25 $White 'SemiBold'; $amp=New-Text '' 13 $Muted 'SemiBold'; $amp.Margin='5,8,0,0'
    $topRow.Children.Add($lab)|Out-Null; $topRow.Children.Add($tm)|Out-Null; $topRow.Children.Add($amp)|Out-Null
    $bottomRow = New-Object Windows.Controls.StackPanel; $bottomRow.Orientation='Horizontal'; $bottomRow.HorizontalAlignment='Left'; $bottomRow.Margin='0,-2,0,0'
    $dayText = New-Text '---' 12 $Cyan 'SemiBold'; $dayText.Width=35; $dayText.TextAlignment='Left'
    $dateText = New-Text '--- --' 12 (Brush '#7292A5') 'SemiBold'; $dateText.Width=67; $dateText.TextAlignment='Left'; $dateText.Margin='5,0,0,0'
    $bottomRow.Children.Add($dayText)|Out-Null; $bottomRow.Children.Add($dateText)|Out-Null
    $flagIcon=New-FlagIcon $zoneDefinition.Flag;$bottomRow.Children.Add($flagIcon)|Out-Null
    $cell.Children.Add($topRow)|Out-Null; $cell.Children.Add($bottomRow)|Out-Null; $cellBorder.Child=$cell
    [Windows.Controls.Grid]::SetColumn($cellBorder,$i); $header.Children.Add($cellBorder)|Out-Null
    $script:ClockTexts += [pscustomobject]@{Time=$tm;Ampm=$amp;Day=$dayText;Date=$dateText;Zone=$zoneDefinition.Zone;Key=$zoneDefinition.Key;Label=$lab;Flag=$flagIcon;BottomRow=$bottomRow;Cell=$cellBorder}
    $cellBorder.Add_PreviewMouseLeftButtonDown({if($_.ChangedButton -eq [Windows.Input.MouseButton]::Left -and (([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control) -ne 0)){$_.Handled=$true;Show-ClockZonePicker ([int]$this.Tag)}})
}
$layout.Children.Add($header)|Out-Null

$clockContextMenu=New-Object Windows.Controls.ContextMenu;$clockContextMenu.Background=Brush '#FF07161E';$clockContextMenu.Foreground=$White;$clockContextMenu.BorderBrush=$OutlineBrush;$clockContextMenu.BorderThickness=1;$clockContextMenu.Padding='4'
function Update-ClockDisplay($clock,[DateTime]$utcNow=[DateTime]::UtcNow) {
    try{$tz=[TimeZoneInfo]::FindSystemTimeZoneById($clock.Zone);$z=[TimeZoneInfo]::ConvertTimeFromUtc($utcNow,$tz);$clock.Time.Text=$z.ToString('h:mm');$clock.Ampm.Text=$z.ToString('tt');$clock.Day.Text=$z.ToString('ddd').ToUpper();$clock.Date.Text=$z.ToString('MMM dd').ToUpper()}catch{}
}
function Set-ClockZone([int]$slot,[string]$key) {
    if($slot -lt 0 -or $slot -ge $script:ClockTexts.Count){return}
    $zoneDefinition=$script:ClockZoneCatalog|Where-Object Key -eq $key|Select-Object -First 1
    if(-not $zoneDefinition){return}
    $clock=$script:ClockTexts[$slot];$clock.Key=$zoneDefinition.Key;$clock.Zone=$zoneDefinition.Zone;$clock.Label.Text=$zoneDefinition.Key
    $clock.BottomRow.Children.Remove($clock.Flag);$newFlag=New-FlagIcon $zoneDefinition.Flag;$clock.BottomRow.Children.Add($newFlag)|Out-Null;$clock.Flag=$newFlag
    $clock.Cell.ToolTip=("{0} ({1})`nCtrl+click to choose this clock time zone" -f $zoneDefinition.Name,$zoneDefinition.Zone)
    Update-ClockDisplay $clock
    Save-Settings
}
function Show-ClockZonePicker([int]$slot) {
    $clockContextMenu.Items.Clear();$heading=New-Object Windows.Controls.MenuItem;$heading.Header=('CLOCK {0} - SELECT CITY' -f ($slot+1));$heading.IsEnabled=$false;$heading.FontWeight='Bold';$heading.Foreground=$Cyan;$clockContextMenu.Items.Add($heading)|Out-Null;$clockContextMenu.Items.Add((New-Object Windows.Controls.Separator))|Out-Null
    foreach($zoneDefinition in $script:ClockZoneCatalog){$item=New-Object Windows.Controls.MenuItem;$item.Header=("{0}  {1}" -f $zoneDefinition.Key,$zoneDefinition.Name);$item.ToolTip=$zoneDefinition.Zone;$item.Tag=("{0}|{1}" -f $slot,$zoneDefinition.Key);$item.IsCheckable=$true;$item.IsChecked=($script:ClockTexts[$slot].Key -eq $zoneDefinition.Key);$item.Add_Click({$parts=([string]$this.Tag).Split('|');Set-ClockZone ([int]$parts[0]) $parts[1]});$clockContextMenu.Items.Add($item)|Out-Null}
    $clockContextMenu.PlacementTarget=$script:ClockTexts[$slot].Cell;$clockContextMenu.Placement='MousePoint';$clockContextMenu.IsOpen=$true
}
foreach($clock in $script:ClockTexts){Update-ClockDisplay $clock}

$windowControls=New-Object Windows.Controls.StackPanel;$windowControls.Orientation='Horizontal';$windowControls.HorizontalAlignment='Right';$windowControls.VerticalAlignment='Top';$windowControls.Margin='0,4,4,0';[Windows.Controls.Panel]::SetZIndex($windowControls,20)
$minButton=New-WindowControl ([string][char]0x2212) 'Minimize to the Windows notification area' $Muted
$sizeButton=New-WindowControl ([string][char]0x2194) 'Resize: toggle compact / recommended size' $Cyan
$maxButton=New-WindowControl ([string][char]0x25A1) 'Maximize to the current screen' $Lime
$minButton.Add_Click({
    $script:MinimizedByButton=$false
    $window.ShowInTaskbar=$false
    $window.Hide()
    if($tray){$tray.ShowBalloonTip(3000,'NeonPulse Widget','The widget is running in the notification area. Click its cyan gauge icon to restore it.','Info')}
})
$sizeButton.Add_Click({
    if($script:IsWidgetMaximized){Restore-WidgetSize}
    elseif(-not $script:IsWidgetCompact){
        $script:RestoreBounds=[pscustomobject]@{Left=$window.Left;Top=$window.Top;Width=$window.Width;Height=$window.Height};$script:IsWidgetCompact=$true
        $w=[math]::Max($window.MinWidth,[math]::Round($script:DesignWidth*.72));$h=[math]::Max($window.MinHeight,[math]::Round($script:DesignHeight*.72))
        Set-WidgetBounds ([pscustomobject]@{Left=$window.Left+($window.Width-$w)/2;Top=$window.Top+($window.Height-$h)/2;Width=$w;Height=$h})
    }else{Restore-WidgetSize}
})
$maxButton.Add_Click({
    if(-not $script:IsWidgetMaximized){$script:RestoreBounds=[pscustomobject]@{Left=$window.Left;Top=$window.Top;Width=$window.Width;Height=$window.Height}}
    $script:IsWidgetMaximized=$true;$script:IsWidgetCompact=$false
    Set-WidgetBounds ([pscustomobject]@{Left=$script:WorkArea.Left;Top=$script:WorkArea.Top;Width=$script:WorkArea.Width;Height=$script:WorkArea.Height})
})
$windowControls.Children.Add($minButton)|Out-Null;$windowControls.Children.Add($sizeButton)|Out-Null;$windowControls.Children.Add($maxButton)|Out-Null;$layout.Children.Add($windowControls)|Out-Null

$gaugesGrid = New-Object Windows.Controls.Grid; $gaugesGrid.Margin='0,0,0,6'; [Windows.Controls.Grid]::SetRow($gaugesGrid,1)
1..4 | ForEach-Object { $c=New-Object Windows.Controls.ColumnDefinition; $c.Width='*'; $gaugesGrid.ColumnDefinitions.Add($c) }
$cpu = New-GaugeCard 'CPU' $script:Hardware.Cpu 'TEMP' 'CPU'
$gpu = New-GaugeCard 'GPU' $script:Hardware.Gpu 'TEMP' 'GPU'
$ram = New-GaugeCard 'RAM' $script:Hardware.Memory 'USED' 'RAM'
$disk = New-GaugeCard $script:SelectedDriveDescriptor.Title $script:SelectedDriveDescriptor.Subtitle 'READ       WRITE' 'DISK'
$disk.FooterValue.FontSize = 22
function Update-DiskCapacityBadge([int64]$totalBytes,[int64]$freeBytes) {
    if(-not $disk.HeaderMetric -or $totalBytes -le 0){return}
    $usedBytes=[math]::Max([int64]0,[int64]($totalBytes-$freeBytes))
    if($totalBytes -ge 1TB){$disk.HeaderMetric.Text=('{0:N1} / {1:N1} TB' -f ($usedBytes/1TB),($totalBytes/1TB))}
    else{$disk.HeaderMetric.Text=('{0:N0} / {1:N0} GB' -f ($usedBytes/1GB),($totalBytes/1GB))}
    $usedPercent=[math]::Round($usedBytes/$totalBytes*100)
    $disk.HeaderMetric.ToolTip=("Used: {0:N1} GB`nFree: {1:N1} GB`nTotal: {2:N1} GB`n{3}% used" -f ($usedBytes/1GB),($freeBytes/1GB),($totalBytes/1GB),$usedPercent)
}
Update-DiskCapacityBadge $script:SelectedDriveDescriptor.Size $script:SelectedDriveDescriptor.FreeSpace
$cards=@($cpu,$gpu,$ram,$disk)
for($i=0;$i -lt 4;$i++){ [Windows.Controls.Grid]::SetColumn($cards[$i].Root,$i); $gaugesGrid.Children.Add($cards[$i].Root)|Out-Null }
$layout.Children.Add($gaugesGrid)|Out-Null

$script:TaskManagerNavigationTimer=$null
$script:TaskManagerNavigationAttempts=0
$script:TaskManagerNavigationPhase='Performance'
function Invoke-UiaNavigationItem($windowElement,[string]$name) {
    $nameCondition=New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::NameProperty,$name)
    $matches=$windowElement.FindAll([Windows.Automation.TreeScope]::Descendants,$nameCondition)
    # Prefer true selectable navigation entries. Static labels can expose the
    # legacy accessibility pattern but do not actually change Task Manager pages.
    foreach($element in $matches){
        $pattern=$null
        if($element.TryGetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern,[ref]$pattern)){$pattern.Select();return $true}
    }
    foreach($element in $matches){
        $pattern=$null
        if($element.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern,[ref]$pattern)){$pattern.Invoke();return $true}
    }
    return $false
}
function Invoke-UiaAutomationId($windowElement,[string]$automationId) {
    $idCondition=New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::AutomationIdProperty,$automationId)
    $element=$windowElement.FindFirst([Windows.Automation.TreeScope]::Descendants,$idCondition)
    if(-not $element){return $false}
    $pattern=$null
    if($element.TryGetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern,[ref]$pattern)){$pattern.Select();return $true}
    if($element.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern,[ref]$pattern)){$pattern.Invoke();return $true}
    return $false
}
function Open-TaskManagerPerformance {
    try{Start-Process -FilePath (Join-Path $env:WINDIR 'System32\Taskmgr.exe')|Out-Null}catch{return}
    if($script:TaskManagerNavigationTimer){$script:TaskManagerNavigationTimer.Stop()}
    $script:TaskManagerNavigationAttempts=0
    $script:TaskManagerNavigationPhase='Performance'
    $script:TaskManagerNavigationTimer=New-Object Windows.Threading.DispatcherTimer
    $script:TaskManagerNavigationTimer.Interval=[TimeSpan]::FromMilliseconds(250)
    $script:TaskManagerNavigationTimer.Add_Tick({
        $script:TaskManagerNavigationAttempts++
        try{
            $desktop=[Windows.Automation.AutomationElement]::RootElement
            $windows=$desktop.FindAll([Windows.Automation.TreeScope]::Children,[Windows.Automation.Condition]::TrueCondition)
            foreach($candidate in $windows){
                try{$process=Get-Process -Id $candidate.Current.ProcessId -ErrorAction Stop}catch{continue}
                if($process.ProcessName -ne 'Taskmgr'){continue}
                $handle=[IntPtr]$candidate.Current.NativeWindowHandle
                if($handle -ne [IntPtr]::Zero){[NeonNative]::ShowWindow($handle,9)|Out-Null;[NeonNative]::SetForegroundWindow($handle)|Out-Null}
                if($script:TaskManagerNavigationPhase -eq 'Performance'){
                    if(Invoke-UiaAutomationId $candidate 'PerformanceItem'){
                        $script:TaskManagerNavigationPhase='CPU';$script:TaskManagerNavigationAttempts=0
                    }else{
                        $toggleCondition=New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::AutomationIdProperty,'TogglePaneButton')
                        $toggle=$candidate.FindFirst([Windows.Automation.TreeScope]::Descendants,$toggleCondition)
                        if($toggle -and $toggle.Current.Name -match '^Open Navigation'){
                            $togglePattern=$null
                            if($toggle.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern,[ref]$togglePattern)){$togglePattern.Invoke()}
                        }
                    }
                }elseif((Invoke-UiaAutomationId $candidate 'dashSidebarCpuButton') -or (Invoke-UiaNavigationItem $candidate 'CPU')){
                    try{$candidate.SetFocus()}catch{}
                    $script:TaskManagerNavigationTimer.Stop()
                }
                break
            }
        }catch{}
        if($script:TaskManagerNavigationAttempts -ge 48){$script:TaskManagerNavigationTimer.Stop()}
    })
    $script:TaskManagerNavigationTimer.Start()
}
$cpu.Root.ToolTip='Ctrl+click to open Task Manager Performance > CPU'
$cpu.Root.Add_PreviewMouseLeftButtonDown({
    if($_.ChangedButton -eq [Windows.Input.MouseButton]::Left -and (([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control) -ne 0)){
        $_.Handled=$true
        Open-TaskManagerPerformance
    }
})

$diskContextMenu=New-Object Windows.Controls.ContextMenu
$diskContextMenu.Background=Brush '#FF07161E';$diskContextMenu.Foreground=$White;$diskContextMenu.BorderBrush=$OutlineBrush;$diskContextMenu.BorderThickness=1;$diskContextMenu.Padding='4'
function Select-MonitoredDrive([string]$driveLetter) {
    $descriptor=Get-DriveDescriptor $driveLetter
    if(-not $descriptor){return}
    $script:SelectedDrive=$descriptor.Id
    $script:SelectedDriveDescriptor=$descriptor
    Initialize-DiskCounters $script:SelectedDrive
    $disk.Title.Text=$descriptor.Title
    $disk.Subtitle.Text=$descriptor.Subtitle.ToUpperInvariant()
    $disk.Subtitle.ToolTip=("{0} ({1})`n{2:N1} GB total" -f $descriptor.Volume,$descriptor.Id,($descriptor.Size/1GB))
    Update-DiskCapacityBadge $descriptor.Size $descriptor.FreeSpace
    $disk.History.Clear();Update-GaugeHistory $disk 0
    Save-Settings
}
function Show-DrivePicker {
    $diskContextMenu.Items.Clear()
    $heading=New-Object Windows.Controls.MenuItem;$heading.Header='MONITOR DRIVE';$heading.IsEnabled=$false;$heading.FontWeight='Bold';$heading.Foreground=$Cyan;$diskContextMenu.Items.Add($heading)|Out-Null
    $diskContextMenu.Items.Add((New-Object Windows.Controls.Separator))|Out-Null
    foreach($descriptor in @(Get-AvailableDriveDescriptors)){
        $item=New-Object Windows.Controls.MenuItem
        $volumeLabel=if($descriptor.Volume -and $descriptor.Volume -ne 'LOCAL DISK'){"- $($descriptor.Volume)"}else{''}
        $item.Header=("{0}  {1}" -f $descriptor.Id,$volumeLabel)
        $item.ToolTip=("{0}`n{1:N1} GB total" -f $descriptor.Subtitle,($descriptor.Size/1GB))
        $item.Tag=$descriptor.Id;$item.IsCheckable=$true;$item.IsChecked=($descriptor.Id -eq $script:SelectedDrive)
        $item.Add_Click({Select-MonitoredDrive ([string]$this.Tag)})
        $diskContextMenu.Items.Add($item)|Out-Null
    }
    $diskContextMenu.PlacementTarget=$disk.Root;$diskContextMenu.Placement='MousePoint';$diskContextMenu.IsOpen=$true
}
$disk.Root.ToolTip='Ctrl+click to select a drive to monitor'
$disk.Root.Add_PreviewMouseLeftButtonDown({
    if($_.ChangedButton -eq [Windows.Input.MouseButton]::Left -and (([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control) -ne 0)){
        $_.Handled=$true
        Show-DrivePicker
    }
})

$bottom = New-Object Windows.Controls.Border; $bottom.CornerRadius=13; $bottom.BorderThickness=1; $bottom.BorderBrush=$OutlineBrush; $bottom.Background=$Panel; $bottom.Padding='8,14'; [Windows.Controls.Grid]::SetRow($bottom,2)
$bottomGrid=New-Object Windows.Controls.Grid
foreach($w in @('*','*','*','*')){$c=New-Object Windows.Controls.ColumnDefinition;$c.Width=$w;$bottomGrid.ColumnDefinitions.Add($c)}
$clockStat=New-StatBlock 'CPU CLOCK' 'CLOCK' '--' 'GHz' $Cyan
$vramStat=New-StatBlock 'GPU VRAM' 'VRAM' '--' 'GB' $Cyan
$netStat=New-NetworkBlock
$script:MicrophoneMuted=$false
$script:MicrophoneMeterAvailable=$false
$script:MicrophoneDisplayedPeak=0.0
function Update-MicrophoneSignal([double]$rawPeak) {
    if(-not $script:MicrophoneMeterAvailable -or $script:MicrophoneMuted){$target=0.0}else{$target=[math]::Max(0,[math]::Min(100,$rawPeak))}
    if($target -ge $script:MicrophoneDisplayedPeak){$script:MicrophoneDisplayedPeak=$target}else{$script:MicrophoneDisplayedPeak=[math]::Max(0,$script:MicrophoneDisplayedPeak*.72)}
    $display=[int][math]::Round($script:MicrophoneDisplayedPeak)
    $netStat.MicSignalFill.Width=98*$display/100
    $netStat.MicSignalValue.Text=('{0}%' -f $display)
    if($display -ge 85){$netStat.MicSignalFill.Background=$WarningRed;$netStat.MicSignalValue.Foreground=$WarningRed}
    elseif($display -ge 60){$amber=Brush '#FFFFC107';$netStat.MicSignalFill.Background=$amber;$netStat.MicSignalValue.Foreground=$amber}
    else{$netStat.MicSignalFill.Background=$Lime;$netStat.MicSignalValue.Foreground=if($display -gt 0){$Lime}else{$Muted}}
}
function Update-SpeakerPanel($speaker) {
    $netStat.SpeakerDevice.Text=Get-AudioDeviceLabel $speaker.Name $false
    $netStat.SpeakerDevice.ToolTip=if($speaker.Name){$speaker.Name+"`nClick to switch to the next available audio output"}else{'No output device available'}
    $script:UpdatingAudioSliders=$true
    try{$netStat.SpeakerSlider.IsEnabled=$speaker.Available;if($speaker.Available){$netStat.SpeakerSlider.Value=$speaker.Volume};$netStat.SpeakerSlider.ToolTip=('Audio output volume: {0}%' -f $speaker.Volume)}finally{$script:UpdatingAudioSliders=$false}
    if(-not $speaker.Available){$netStat.SpeakerValue.Text='OFFLINE';$netStat.SpeakerValue.Foreground=$Muted;Set-DeviceIconState $netStat.SpeakerIcon 'Offline' $Cyan}
    elseif($speaker.Muted -or $speaker.Volume -le 0){$netStat.SpeakerValue.Text='MUTED';$netStat.SpeakerValue.Foreground=$WarningRed;Set-DeviceIconState $netStat.SpeakerIcon 'Muted' $Cyan}
    else{$netStat.SpeakerValue.Text=('{0}%' -f $speaker.Volume);$netStat.SpeakerValue.Foreground=$White;Set-DeviceIconState $netStat.SpeakerIcon 'Active' $Cyan}
}
function Update-MicrophonePanel($microphone) {
    $netStat.MicDevice.Text=Get-AudioDeviceLabel $microphone.Name $true
    $netStat.MicDevice.ToolTip=if($microphone.Name){$microphone.Name+"`nClick to switch to the next available microphone"}else{'No microphone available'}
    $script:UpdatingAudioSliders=$true
    try{$netStat.MicSlider.IsEnabled=$microphone.Available;if($microphone.Available){$netStat.MicSlider.Value=$microphone.Volume};$netStat.MicSlider.ToolTip=('Microphone input level: {0}%' -f $microphone.Volume)}finally{$script:UpdatingAudioSliders=$false}
    $script:MicrophoneMeterAvailable=$microphone.Available
    $script:MicrophoneMuted=(-not $microphone.Available -or $microphone.Muted -or $microphone.Volume -le 0)
    if($script:MicrophoneMuted){Update-MicrophoneSignal 0}
    if(-not $microphone.Available){$netStat.MicValue.Text='OFFLINE';$netStat.MicValue.Foreground=$Muted;Set-DeviceIconState $netStat.MicIcon 'Offline' $Lime}
    elseif($microphone.Muted -or $microphone.Volume -le 0){$netStat.MicValue.Text='MUTED';$netStat.MicValue.Foreground=$WarningRed;Set-DeviceIconState $netStat.MicIcon 'Muted' $Lime}
    else{$netStat.MicValue.Text=('{0}%' -f $microphone.Volume);$netStat.MicValue.Foreground=$Lime;Set-DeviceIconState $netStat.MicIcon 'Active' $Lime}
}
$netStat.SpeakerButton.Add_Click({
    try {Update-SpeakerPanel ([NeonAudio]::ToggleDefaultMute($false))} catch {}
})
$netStat.MicButton.Add_Click({
    try {Update-MicrophonePanel ([NeonAudio]::ToggleDefaultMute($true))} catch {}
})
$netStat.SpeakerValue.Cursor='Hand';$netStat.SpeakerValue.ToolTip='Click to mute or unmute the default audio output'
$netStat.MicValue.Cursor='Hand';$netStat.MicValue.ToolTip='Click to mute or unmute the default microphone'
$netStat.SpeakerValue.Add_PreviewMouseLeftButtonDown({$_.Handled=$true;try{Update-SpeakerPanel ([NeonAudio]::ToggleDefaultMute($false))}catch{}})
$netStat.MicValue.Add_PreviewMouseLeftButtonDown({$_.Handled=$true;try{Update-MicrophonePanel ([NeonAudio]::ToggleDefaultMute($true))}catch{}})
$netStat.SpeakerSlider.Add_ValueChanged({
    if($script:UpdatingAudioSliders){return}
    try{Update-SpeakerPanel ([NeonAudio]::SetDefaultVolume($false,[int][math]::Round($this.Value)))}catch{}
})
$netStat.MicSlider.Add_ValueChanged({
    if($script:UpdatingAudioSliders){return}
    try{Update-MicrophonePanel ([NeonAudio]::SetDefaultVolume($true,[int][math]::Round($this.Value)))}catch{}
})
$netStat.SpeakerSwitchButton.Add_Click({try{Update-SpeakerPanel ([NeonAudio]::CycleDefault($false))}catch{}})
$netStat.MicSwitchButton.Add_Click({try{Update-MicrophonePanel ([NeonAudio]::CycleDefault($true))}catch{}})
$audioMeterTimer=New-Object Windows.Threading.DispatcherTimer
$audioMeterTimer.Interval=[TimeSpan]::FromMilliseconds(120)
$audioMeterTimer.Add_Tick({if($window.IsVisible){try{Update-MicrophoneSignal ([NeonAudio]::GetDefaultPeak($true))}catch{Update-MicrophoneSignal 0}}})
[Windows.Controls.Grid]::SetColumn($clockStat.Root,0); $bottomGrid.Children.Add($clockStat.Root)|Out-Null
[Windows.Controls.Grid]::SetColumn($vramStat.Root,1); $bottomGrid.Children.Add($vramStat.Root)|Out-Null
[Windows.Controls.Grid]::SetColumn($netStat.Root,2); [Windows.Controls.Grid]::SetColumnSpan($netStat.Root,2); $bottomGrid.Children.Add($netStat.Root)|Out-Null
$bottom.Child=$bottomGrid;$layout.Children.Add($bottom)|Out-Null
$resizeHint=New-Text 'DRAG CORNER TO RESIZE' 10 (Brush '#6F91A2') 'SemiBold';$resizeHint.HorizontalAlignment='Right';$resizeHint.Margin='0,3,25,0';[Windows.Controls.Grid]::SetRow($resizeHint,3);$layout.Children.Add($resizeHint)|Out-Null
$outer.Child=$layout
$viewbox=New-Object Windows.Controls.Viewbox
$viewbox.Stretch='Uniform';$viewbox.StretchDirection='Both';$viewbox.HorizontalAlignment='Center';$viewbox.VerticalAlignment='Center';$viewbox.Child=$outer
$windowRoot=New-Object Windows.Controls.Grid;$windowRoot.Children.Add($viewbox)|Out-Null
$resizeGrip=New-Object Windows.Controls.Border
$resizeGrip.Width=42;$resizeGrip.Height=42;$resizeGrip.HorizontalAlignment='Right';$resizeGrip.VerticalAlignment='Bottom';$resizeGrip.Cursor='SizeNWSE';$resizeGrip.Background=Brush '#01000000';$resizeGrip.ToolTip='Drag this corner to resize • double-click to fit the screen'
$gripCanvas=New-Object Windows.Controls.Canvas;$gripCanvas.Width=34;$gripCanvas.Height=34;$gripCanvas.HorizontalAlignment='Center';$gripCanvas.VerticalAlignment='Center'
foreach($offset in @(8,16,24)){$mark=New-Object Windows.Shapes.Line;$mark.X1=32-$offset;$mark.Y1=32;$mark.X2=32;$mark.Y2=32-$offset;$mark.Stroke=$Cyan;$mark.StrokeThickness=2.3;$mark.Opacity=.9;$mark.StrokeStartLineCap='Round';$mark.StrokeEndLineCap='Round';$gripCanvas.Children.Add($mark)|Out-Null}
$gripGlow=New-Object Windows.Media.Effects.DropShadowEffect;$gripGlow.Color=[Windows.Media.ColorConverter]::ConvertFromString('#00DDEA');$gripGlow.BlurRadius=7;$gripGlow.ShadowDepth=0;$gripGlow.Opacity=.75;$gripCanvas.Effect=$gripGlow
$resizeGrip.Child=$gripCanvas
$resizeGrip.Add_PreviewMouseLeftButtonDown({
    if($_.ClickCount -eq 2){$s=Get-ResponsiveWindowSize;$window.Width=$s.Width;$window.Height=$s.Height;$_.Handled=$true;return}
    $script:IsWidgetMaximized=$false;$script:IsWidgetCompact=$false
    $handle=(New-Object Windows.Interop.WindowInteropHelper($window)).Handle
    if($handle -ne [IntPtr]::Zero){[NeonNative]::ReleaseCapture()|Out-Null;[NeonNative]::SendMessage($handle,0x00A1,[IntPtr]17,[IntPtr]::Zero)|Out-Null}
    $_.Handled=$true
})
$windowRoot.Children.Add($resizeGrip)|Out-Null
$window.Content=$windowRoot

function Set-Gauge($g,[double]$value,[string]$display,[string]$unit='%') {
    $g.Progress.Data = New-ArcGeometry $value; $g.Value.Text=$display; $g.Unit.Text=$unit
    Update-GaugeHistory $g $value
    if($value -gt 89){
        $g.Progress.Stroke=$WarningRed;$g.Value.Foreground=$WarningRed;$g.Unit.Foreground=$WarningRed
        $g.GraphLine.Stroke=$WarningRed;$g.GraphFill.Fill=Brush '#44FF243D'
        if($g.Progress.Effect){$g.Progress.Effect.Color=[Windows.Media.ColorConverter]::ConvertFromString('#FFFF243D');$g.Progress.Effect.BlurRadius=17;$g.Progress.Effect.Opacity=.95}
    }else{
        $g.Progress.Stroke=$Cyan;$g.Value.Foreground=$White;$g.Unit.Foreground=$Lime
        $g.GraphLine.Stroke=$Cyan;$g.GraphFill.Fill=Brush '#3A00DDEA'
        if($g.Progress.Effect){$g.Progress.Effect.Color=[Windows.Media.ColorConverter]::ConvertFromString('#009CFF');$g.Progress.Effect.BlurRadius=13;$g.Progress.Effect.Opacity=.8}
    }
}

$script:LastNetwork = Get-NetworkSample
$script:LastTick = [DateTime]::UtcNow
$script:TickCount = 0
$script:LastTemp = 'N/A'
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(1)
$timer.Add_Tick({
    try {
        $nowUtc=[DateTime]::UtcNow; $elapsed=[math]::Max(.1,($nowUtc-$script:LastTick).TotalSeconds)
        $script:TickCount++
        if(($script:TickCount%3)-eq 0){try{[IO.File]::WriteAllText($script:SensorHeartbeatFile,[DateTime]::UtcNow.ToString('o'),[Text.UTF8Encoding]::new($false))}catch{}}
        for($i=0;$i -lt $script:ClockTexts.Count;$i++){
            Update-ClockDisplay $script:ClockTexts[$i] $nowUtc
        }
        $cpuVal=if($script:CpuCounter){[math]::Max(0,[math]::Min(100,$script:CpuCounter.NextValue()))}else{0}
        Set-Gauge $cpu $cpuVal ([math]::Round($cpuVal).ToString())
        $sensorSample=Get-HardwareSensorSample
        if($sensorSample.CpuTemp -gt 0){
            $cpu.FooterValue.Text=('{0}{1}C' -f [math]::Round($sensorSample.CpuTemp),[char]176)
            $cpu.FooterValue.ToolTip='CPU temperature supplied by the optional elevated PawnIO sensor helper.'
        }else{
            $cpu.FooterValue.Text=if($script:SensorRecoveryStatus -like 'Starting*' -or $script:SensorRecoveryStatus -like '*pending'){'STARTING...'}else{'NO SENSOR'}
            $cpu.FooterValue.ToolTip=('CPU sensor recovery: {0}' -f $script:SensorRecoveryStatus)
        }
        $gpuSample=Get-GpuSample
        $gpu.FooterValue.ToolTip=('{0} temperature sensor: {1}' -f $script:Hardware.GpuFullName,$script:NvidiaSensorStatus)
        if($sensorSample.GpuTemp -gt 0){$gpu.FooterValue.Text=('{0}{1}C' -f [math]::Round($sensorSample.GpuTemp),[char]176)}else{$gpu.FooterValue.Text='N/A'}
        $mem=Get-MemorySample
        if($gpuSample.DedicatedAvailable){
            $reportedLimitGB=[math]::Round($script:Hardware.GpuRam/1GB,1)
            $dedicatedLimitGB=if($script:NvidiaDedicatedLimitGB -gt 0){$script:NvidiaDedicatedLimitGB}elseif($reportedLimitGB -ge $gpuSample.UsedGB -and $reportedLimitGB -gt 0){$reportedLimitGB}else{[math]::Pow(2,[math]::Ceiling([math]::Log([math]::Max(1,$gpuSample.UsedGB),2)))}
            $dedicatedPercent=[math]::Min(100,[math]::Max(0,$gpuSample.UsedGB/$dedicatedLimitGB*100))
            Set-Gauge $gpu $dedicatedPercent ('{0:N1}' -f $gpuSample.UsedGB) 'GB'
            $gpu.Value.ToolTip=("{0} dedicated GPU memory`nUsed: {1:N2} GB`nCapacity: {2:N1} GB" -f $script:Hardware.GpuFullName,$gpuSample.UsedGB,$dedicatedLimitGB)
        }else{Set-Gauge $gpu 0 'N/A' ''}
        Set-Gauge $ram $mem.Percent ([math]::Round($mem.Percent).ToString()); $ram.FooterValue.Text=("{0} GB" -f $mem.UsedGB)
        $diskActive=if($script:DiskActiveCounter){[math]::Min(100,[math]::Max(0,$script:DiskActiveCounter.NextValue()))}else{0}
        Set-Gauge $disk $diskActive ([math]::Round($diskActive).ToString())
        if(($script:TickCount%5)-eq 1){try{$liveDrive=New-Object IO.DriveInfo($script:SelectedDrive);if($liveDrive.IsReady){Update-DiskCapacityBadge $liveDrive.TotalSize $liveDrive.AvailableFreeSpace}}catch{}}
        $readRate=if($script:DiskReadCounter){[math]::Max(0,$script:DiskReadCounter.NextValue()/1MB)}else{0}
        $writeRate=if($script:DiskWriteCounter){[math]::Max(0,$script:DiskWriteCounter.NextValue()/1MB)}else{0}
        $disk.FooterValue.Text=('{0:N1} / {1:N1} MB/s' -f $readRate,$writeRate)
        if($script:CpuFreqCounter){
            $mhz=$script:CpuFreqCounter.NextValue()
            if($script:CpuPerformanceCounter){$mhz*=[math]::Max(0,$script:CpuPerformanceCounter.NextValue())/100}
            $clockStat.Value.Text=('{0:N2}' -f ($mhz/1000))
        }else{$clockStat.Value.Text='N/A'}
        if($gpuSample.UsedGB -gt 0){$vramStat.Value.Text=('{0:N1}' -f $gpuSample.UsedGB)}else{$vramStat.Value.Text='N/A'}
        $net=Get-NetworkSample;$down=($net.Rx-$script:LastNetwork.Rx)/$elapsed;$up=($net.Tx-$script:LastNetwork.Tx)/$elapsed
        Set-NetworkRateDisplay $netStat.Download $netStat.DownloadUnit $down
        Set-NetworkRateDisplay $netStat.Upload $netStat.UploadUnit $up
        Update-SpeakerPanel ([NeonAudio]::GetDefault($false))
        Update-MicrophonePanel ([NeonAudio]::GetDefault($true))
        $script:LastNetwork=$net;$script:LastTick=$nowUtc
    } catch {}
})

function Save-Settings {
    New-Item -ItemType Directory -Force -Path $script:ConfigDir | Out-Null
    $saved=if($script:IsWidgetMaximized){$script:RestoreBounds}else{[pscustomobject]@{Left=$window.Left;Top=$window.Top;Width=$window.Width;Height=$window.Height}}
    @{Left=$saved.Left;Top=$saved.Top;Width=$saved.Width;Height=$saved.Height;WorkAreaWidth=[math]::Round($script:WorkArea.Width);WorkAreaHeight=[math]::Round($script:WorkArea.Height);Opacity=$window.Opacity;DriveLetter=$script:SelectedDrive;ClockZones=@($script:ClockTexts|ForEach-Object Key)}|ConvertTo-Json|Set-Content -Path $script:ConfigFile -Encoding UTF8
}
function Set-Startup([bool]$enable) {
    $startup=[Environment]::GetFolderPath('Startup');$link=Join-Path $startup 'NeonPulse Widget.lnk'
    if($enable){$launcher=Join-Path $script:WidgetDir 'Run Widget.cmd';if(-not (Test-Path -LiteralPath $launcher -PathType Leaf)){return};$shell=New-Object -ComObject WScript.Shell;$s=$shell.CreateShortcut($link);$s.TargetPath=$launcher;$s.WorkingDirectory=$script:WidgetDir;$s.WindowStyle=7;$s.IconLocation='shell32.dll,14';$s.Save()}elseif(Test-Path -LiteralPath $link){Remove-Item -LiteralPath $link -Force}
}

$script:TrayIcon=New-NeonPulseTrayIcon
$tray=New-Object Windows.Forms.NotifyIcon;$tray.Text='NeonPulse Widget - click to restore';$tray.Icon=$script:TrayIcon;$tray.Visible=$true
$menu=New-Object Windows.Forms.ContextMenuStrip
$showItem=$menu.Items.Add('Show / Hide');$topItem=$menu.Items.Add('Always on top');$topItem.Checked=$true
$fitItem=$menu.Items.Add('Fit to current screen')
$opacityMenu=New-Object Windows.Forms.ToolStripMenuItem('Opacity')
$opacityPanel=New-Object Windows.Forms.Panel;$opacityPanel.Width=245;$opacityPanel.Height=68;$opacityPanel.Padding='8,5,8,3';$opacityPanel.BackColor=[Drawing.Color]::White
$opacityLabel=New-Object Windows.Forms.Label;$opacityLabel.AutoSize=$false;$opacityLabel.Width=225;$opacityLabel.Height=20;$opacityLabel.Location=New-Object Drawing.Point(10,5);$opacityLabel.TextAlign='MiddleLeft';$opacityLabel.Font=New-Object Drawing.Font('Segoe UI',9,[Drawing.FontStyle]::Bold)
$opacitySlider=New-Object Windows.Forms.TrackBar;$opacitySlider.Minimum=0;$opacitySlider.Maximum=100;$opacitySlider.TickFrequency=10;$opacitySlider.SmallChange=1;$opacitySlider.LargeChange=10;$opacitySlider.AutoSize=$false;$opacitySlider.Width=225;$opacitySlider.Height=37;$opacitySlider.Location=New-Object Drawing.Point(7,27);$opacitySlider.Value=[int][math]::Round($window.Opacity*100)
$opacityLabel.Text=('Opacity: {0}%' -f $opacitySlider.Value)
$opacitySlider.Add_ValueChanged({$pct=[int]$this.Value;$window.Opacity=[double]$pct/100;$opacityLabel.Text=('Opacity: {0}%' -f $pct)})
$opacitySlider.Add_MouseUp({Save-Settings})
$opacityPanel.Controls.Add($opacityLabel);$opacityPanel.Controls.Add($opacitySlider)
$opacityHost=New-Object Windows.Forms.ToolStripControlHost -ArgumentList $opacityPanel;$opacityHost.AutoSize=$false;$opacityHost.Size=New-Object Drawing.Size(245,68);$opacityHost.Margin='0,0,0,0';$opacityHost.Padding='0,0,0,0'
$opacityMenu.DropDownItems.Add($opacityHost)|Out-Null
$opacityMenu.Add_DropDownOpening({$pct=[int][math]::Round($window.Opacity*100);if($opacitySlider.Value-ne$pct){$opacitySlider.Value=$pct};$opacityLabel.Text=('Opacity: {0}%' -f $pct)})
$opacityMenu.Add_DropDownClosed({Save-Settings})
$startupItem=$menu.Items.Add('Start with Windows');$startupItem.Checked=Test-Path (Join-Path ([Environment]::GetFolderPath('Startup')) 'NeonPulse Widget.lnk')
$menu.Items.Add($opacityMenu)|Out-Null;$menu.Items.Add('-')|Out-Null;$exitItem=$menu.Items.Add('Exit')
$showItem.Add_Click({if($window.WindowState -eq 'Minimized'){Show-Widget}elseif($window.IsVisible){$window.Hide()}else{Show-Widget}})
$tray.Add_MouseClick({if($_.Button -eq [Windows.Forms.MouseButtons]::Left){Show-Widget}})
$tray.Add_DoubleClick({Show-Widget})
$topItem.Add_Click({$this.Checked=-not $this.Checked;$window.Topmost=$this.Checked})
$fitItem.Add_Click({$script:IsWidgetMaximized=$false;$script:IsWidgetCompact=$false;$s=Get-ResponsiveWindowSize;$window.Width=$s.Width;$window.Height=$s.Height;$window.Left=$script:WorkArea.Right-$window.Width-18;$window.Top=$script:WorkArea.Top+18;$script:RestoreBounds=[pscustomobject]@{Left=$window.Left;Top=$window.Top;Width=$window.Width;Height=$window.Height}})
$startupItem.Add_Click({$this.Checked=-not $this.Checked;Set-Startup $this.Checked})
$exitItem.Add_Click({$window.Close()})
$tray.ContextMenuStrip=$menu

$window.Add_MouseLeftButtonDown({
    if($_.ButtonState -ne 'Pressed'){return}
    $node=$_.OriginalSource -as [Windows.DependencyObject]
    while($node -and $node -ne $window){
        if($node -is [Windows.Controls.Button] -or $node -is [Windows.Controls.Slider] -or $node -is [Windows.Controls.Primitives.Thumb] -or $node -is [Windows.Controls.Primitives.RepeatButton]){return}
        try{$node=[Windows.Media.VisualTreeHelper]::GetParent($node)}catch{$node=$null}
    }
    $window.DragMove()
})
$window.Add_MouseRightButtonUp({$tray.ContextMenuStrip.Show([Windows.Forms.Cursor]::Position)})
$window.Add_KeyDown({if($_.Key -eq 'Escape'){$window.Hide()}})
$window.Add_LocationChanged({Save-Settings})
$window.Add_SizeChanged({Save-Settings})
$window.Add_StateChanged({if($window.WindowState -eq 'Normal' -and $script:MinimizedByButton){$script:MinimizedByButton=$false;$window.ShowInTaskbar=$false}})
$showSignalTimer=New-Object Windows.Threading.DispatcherTimer
$showSignalTimer.Interval=[TimeSpan]::FromMilliseconds(100)
$showSignalTimer.Add_Tick({if($script:ShowSignal.WaitOne(0)){Show-Widget}})
$script:WpfApplication=[Windows.Application]::Current
if(-not $script:WpfApplication){$script:WpfApplication=New-Object Windows.Application}
$script:WpfApplication.ShutdownMode=[Windows.ShutdownMode]::OnExplicitShutdown
$window.Add_Closed({$timer.Stop();$audioMeterTimer.Stop();$showSignalTimer.Stop();try{[NeonAudio]::ClosePeakMeter()}catch{};if($script:NvidiaProcess){try{$script:NvidiaProcess.Dispose()}catch{}};if(Test-Path -LiteralPath $script:SensorHeartbeatFile){Remove-Item -LiteralPath $script:SensorHeartbeatFile -Force -ErrorAction SilentlyContinue};Save-Settings;$tray.Visible=$false;$tray.Dispose();if($script:TrayIcon){$script:TrayIcon.Dispose()};$script:ShowSignal.Dispose();$script:Mutex.ReleaseMutex();$script:Mutex.Dispose();$script:WpfApplication.Shutdown()})
$timer.Start()
$audioMeterTimer.Start()
$showSignalTimer.Start()
[void]$script:WpfApplication.Run($window)
