using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Interop;
using System.Windows.Threading;
using Cleaner = Fxclip.Engine.Engine;

namespace Fxclip;

// All clipboard state stays on the UI dispatcher. No text, host, or app history is persisted.
internal sealed class ClipboardService : IDisposable
{
    private readonly HwndSource window;
    private readonly Native.WinEventProc foregroundCallback;
    private readonly nint hook;
    private readonly DispatcherTimer retry;
    private readonly SettingsStore store;
    private uint? seen;
    private Clip? clip;
    private int attempts;
    private bool busy;
    private bool paused;
    private bool skipNext;
    private sealed record Clip(uint Sequence, string Text, string Clean);
    public Cleaner Engine { get; set; }
    public event Action? Changed;
    public bool Paused => paused;
    public bool SkipNext => skipNext;
    public DateTime? LastClean { get; private set; }
    public string Status { get; private set; } = "Cleaning links";
    private static readonly uint[] PrivateFormats = [
        Native.RegisterClipboardFormat("ExcludeClipboardContentFromMonitorProcessing"),
        Native.RegisterClipboardFormat("CanIncludeInClipboardHistory"),
        Native.RegisterClipboardFormat("CanUploadToCloudClipboard")];

    public ClipboardService(SettingsStore store)
    {
        this.store = store;
        Engine = new(store.Effective);
        window = new HwndSource(new HwndSourceParameters("fxclip clipboard listener") { Width = 0, Height = 0, WindowStyle = 0, ParentWindow = new nint(-3) });
        window.AddHook(WindowProc);
        if (!Native.AddClipboardFormatListener(window.Handle)) throw new InvalidOperationException("Clipboard notifications are unavailable.");
        foregroundCallback = (_, _, _, _, _, _, _) => window.Dispatcher.BeginInvoke(Request);
        hook = Native.SetWinEventHook(3, 3, 0, foregroundCallback, 0, 0, 0);
        if (hook == 0) throw new InvalidOperationException("Foreground notifications are unavailable.");
        retry = new DispatcherTimer(TimeSpan.FromMilliseconds(30), DispatcherPriority.Background, (_, _) => Tick(), window.Dispatcher);
        retry.Stop();
        Request();
    }

    private nint WindowProc(nint hwnd, int message, nint wParam, nint lParam, ref bool handled)
    {
        if (message == 0x031D) Request();
        return 0;
    }

    public void Request()
    {
        attempts = 0;
        Tick();
    }
    public void TogglePause()
    {
        paused = !paused;
        if (paused) RestoreClean();
        Status = paused ? "Paused" : "Cleaning links";
        Request();
        Changed?.Invoke();
    }
    public void ToggleSkip() { skipNext = !skipNext; Changed?.Invoke(); }

    private void Tick()
    {
        if (busy) return;
        busy = true;
        retry.Stop();
        var success = false;
        try { success = InspectAndApply(); }
        finally { busy = false; }
        if (!success && ++attempts < 10) retry.Start();
        else if (!success) { Status = "Clipboard busy · waiting for the next copy"; Changed?.Invoke(); }
    }

    private bool InspectAndApply()
    {
        if (!Native.OpenClipboard(window.Handle)) return false;
        try
        {
            var sequence = Native.GetClipboardSequenceNumber();
            if (sequence != seen)
            {
                clip = null;
                if (paused) { seen = sequence; return true; }
                if (skipNext) { seen = sequence; skipNext = false; Changed?.Invoke(); return true; }
                if (!CanRead(out var rich)) { seen = sequence; return true; }
                var data = Native.GetClipboardData(13);
                if (data == 0) return false;
                var memory = Native.GlobalLock(data);
                if (memory == 0) return false;
                string text;
                try
                {
                    var size = Native.GlobalSize(data);
                    if (size > 32 * 1024 * 1024) { seen = sequence; return true; }
                    text = Marshal.PtrToStringUni(memory, checked((int)size / 2))!.Split('\0')[0];
                }
                finally { Native.GlobalUnlock(data); }
                if (sequence != Native.GetClipboardSequenceNumber()) return false;
                seen = sequence;
                if (rich && !Cleaner.IsBareUrl(text)) return true;
                var result = Engine.Clean(text);
                clip = new(sequence, text, result.Text);
                if (result.Removed > 0)
                {
                    store.Record(result.Removed);
                    LastClean = DateTime.Now;
                }
            }
            if (!paused) ApplyLocked(ForegroundExe());
            Status = paused ? "Paused" : "Cleaning links";
            Changed?.Invoke();
            return true;
        }
        finally { Native.CloseClipboard(); }
    }

    private static bool CanRead(out bool rich)
    {
        rich = false;
        if (!Native.IsClipboardFormatAvailable(13)) return false;
        // Conservative whitelist: never flatten files, images, objects or unknown payloads.
        for (uint format = Native.EnumClipboardFormats(0); format != 0; format = Native.EnumClipboardFormats(format))
        {
            if (format is 1 or 7 or 13 or 16 || PrivateFormats.Contains(format)) continue;
            var name = new StringBuilder(256);
            Native.GetClipboardFormatName(format, name, name.Capacity);
            if (name.ToString() is "HTML Format" or "Rich Text Format" or "Rich Text Format Without Objects") { rich = true; continue; }
            return false;
        }
        return true;
    }

    private static string ForegroundExe()
    {
        Native.GetWindowThreadProcessId(Native.GetForegroundWindow(), out var pid);
        try { using var process = Process.GetProcessById((int)pid); return process.ProcessName + ".exe"; }
        catch (Exception e) when (e is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception) { return ""; }
    }

    private void ApplyLocked(string? app)
    {
        var current = clip;
        if (current is null || Native.GetClipboardSequenceNumber() != current.Sequence) return;
        var wanted = app is null ? current.Clean : Engine.Preview(current.Clean, app);
        if (wanted == current.Text) return;
        var preview = wanted != current.Clean;
        // Allocate everything before emptying: allocation failure leaves the original intact.
        var blocks = new List<(uint Format, nint Memory)>();
        try
        {
            blocks.Add((13, Allocate(Encoding.Unicode.GetBytes(wanted + "\0"))));
            if (preview)
                foreach (var format in PrivateFormats) blocks.Add((format, Allocate(new byte[4])));
            // Clipboard is locked, so another app cannot write between this check and EmptyClipboard.
            if (Native.GetClipboardSequenceNumber() != current.Sequence || !Native.EmptyClipboard()) return;
            // Privacy markers precede preview text, and every marker must succeed.
            foreach (var block in blocks.OrderBy(b => b.Format == 13))
            {
                if (Native.SetClipboardData(block.Format, block.Memory) == 0)
                {
                    // If a privacy marker failed, publish the clean text instead of a preview.
                    var clean = Allocate(Encoding.Unicode.GetBytes(current.Clean + "\0"));
                    if (Native.SetClipboardData(13, clean) == 0) Native.GlobalFree(clean);
                    seen = Native.GetClipboardSequenceNumber();
                    clip = null;
                    return;
                }
                var index = blocks.FindIndex(b => b.Memory == block.Memory);
                blocks[index] = (block.Format, 0); // ownership transferred to Windows
            }
            // Read our sequence while still holding the lock, before any later external copy.
            var ours = Native.GetClipboardSequenceNumber();
            clip = new(ours, wanted, current.Clean);
            seen = ours;
        }
        finally { foreach (var block in blocks) if (block.Memory != 0) Native.GlobalFree(block.Memory); }
    }

    private static nint Allocate(byte[] bytes)
    {
        var handle = Native.GlobalAlloc(0x0042, (nuint)bytes.Length);
        if (handle == 0) throw new OutOfMemoryException();
        var memory = Native.GlobalLock(handle);
        if (memory == 0) { Native.GlobalFree(handle); throw new OutOfMemoryException(); }
        try { Marshal.Copy(bytes, 0, memory, bytes.Length); }
        finally { Native.GlobalUnlock(handle); }
        return handle;
    }

    public void RestoreClean()
    {
        for (var attempt = 0; attempt < 10; attempt++)
        {
            if (Native.OpenClipboard(window.Handle))
            {
                try { ApplyLocked(null); }
                finally { Native.CloseClipboard(); }
                return;
            }
            Thread.Sleep(25);
        }
    }
    public void Dispose()
    {
        retry.Stop();
        RestoreClean();
        Native.UnhookWinEvent(hook);
        Native.RemoveClipboardFormatListener(window.Handle);
        window.Dispose();
    }
}
