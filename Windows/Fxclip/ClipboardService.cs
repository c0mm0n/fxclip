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
    private PendingRestoration? restoration;
    private int attempts;
    private bool busy;
    private bool paused;
    private bool skipNext;
    private sealed record Clip(uint Sequence, string Text, string Clean, ClipboardPrivacy Privacy, bool Owned = false);
    public Cleaner Engine { get; set; }
    public event Action? Changed;
    public bool Paused => paused;
    public bool SkipNext => skipNext;
    public DateTime? LastClean { get; private set; }
    public string Status { get; private set; } = "Cleaning links";
    private static readonly Dictionary<string, uint> PrivateFormats = new[] { ClipboardPolicy.Exclude, ClipboardPolicy.History, ClipboardPolicy.Cloud }
        .ToDictionary(name => name, Native.RegisterClipboardFormat);

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

    public void Request() { attempts = 0; Tick(); }
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
        if (restoration is not null)
        {
            retry.Interval = restoration.Delay(DateTimeOffset.UtcNow);
            retry.Start();
        }
        else if (!success && ++attempts < 10) { retry.Interval = TimeSpan.FromMilliseconds(30); retry.Start(); }
        else if (!success) { Status = paused ? "Paused" : "Clipboard busy · waiting for the next copy"; Changed?.Invoke(); }
    }

    private bool InspectAndApply()
    {
        if (!Native.OpenClipboard(window.Handle)) return false;
        try
        {
            var sequence = Native.GetClipboardSequenceNumber();
            // CloseClipboard can synthesize formats and advance the sequence after our write.
            // On the following notification, owner + exact text recognise that closed write.
            var ownWrite = false;
            if (clip is { Owned: true } current && Native.GetClipboardOwner() == window.Handle)
            {
                if (!TryReadText(out var actual)) return false;
                ownWrite = ClipboardPolicy.IsOwnWrite(window.Handle, Native.GetClipboardOwner(), current.Text, actual);
                if (ownWrite)
                {
                    sequence = Native.GetClipboardSequenceNumber();
                    clip = current with { Sequence = sequence };
                    seen = sequence;
                }
            }
            if (restoration?.SupersededBy(sequence, ownWrite) == true) restoration = null;
            if (restoration is not null) restoration = restoration with { Sequence = sequence };
            if (sequence != seen)
            {
                clip = null;
                if (paused) { seen = sequence; return true; }
                if (skipNext) { seen = sequence; skipNext = false; Changed?.Invoke(); return true; }
                // Policy is checked before GetClipboardData: excluded sources are never read.
                var policy = ClipboardPolicy.Read(Formats());
                if (!policy.Allowed) { seen = sequence; return true; }
                if (!TryReadPrivacy(out var privacy)) return false;
                if (!TryReadText(out var text)) return false;
                if (sequence != Native.GetClipboardSequenceNumber()) return false;
                seen = sequence;
                if (text is null || (policy.BareUrlOnly && !Cleaner.IsBareUrl(text))) return true;
                var result = Engine.Clean(text);
                clip = new(sequence, text, result.Text, privacy);
                if (result.Removed > 0)
                {
                    store.Record(result.Removed);
                    LastClean = DateTime.Now;
                }
            }
            var success = true;
            if (restoration is not null)
            {
                success = ApplyLocked(null);
                if (clip is null || clip.Text == clip.Clean) restoration = null;
            }
            else if (!paused) success = ApplyLocked(ForegroundExe());
            Status = paused ? "Paused" : "Cleaning links";
            Changed?.Invoke();
            return success;
        }
        finally { Native.CloseClipboard(); }
    }

    private static ClipboardFormat[] Formats()
    {
        var formats = new List<ClipboardFormat>();
        for (uint format = Native.EnumClipboardFormats(0); format != 0; format = Native.EnumClipboardFormats(format))
        {
            var name = new StringBuilder(256);
            Native.GetClipboardFormatName(format, name, name.Capacity);
            formats.Add(new(format, name.ToString()));
        }
        return formats.ToArray();
    }

    private static bool TryReadText(out string? text)
    {
        text = null;
        var data = Native.GetClipboardData(13);
        if (data == 0) return false;
        var size = Native.GlobalSize(data);
        if (size > 32 * 1024 * 1024) return true;
        var memory = Native.GlobalLock(data);
        if (memory == 0) return false;
        try { text = Marshal.PtrToStringUni(memory, checked((int)size / 2))!.Split('\0')[0]; }
        finally { Native.GlobalUnlock(data); }
        return true;
    }

    private static bool TryReadPrivacy(out ClipboardPrivacy privacy)
    {
        privacy = default;
        if (!TryZeroMarker(ClipboardPolicy.History, out var history) || !TryZeroMarker(ClipboardPolicy.Cloud, out var cloud)) return false;
        privacy = new(history, cloud);
        return true;
    }
    private static bool TryZeroMarker(string name, out bool zero)
    {
        zero = false;
        var format = PrivateFormats[name];
        if (!Native.IsClipboardFormatAvailable(format)) return true;
        var data = Native.GetClipboardData(format);
        if (data == 0 || Native.GlobalSize(data) < 4) return false;
        var memory = Native.GlobalLock(data);
        if (memory == 0) return false;
        try { zero = Marshal.ReadInt32(memory) == 0; return true; }
        finally { Native.GlobalUnlock(data); }
    }

    private static string ProcessExe(uint pid)
    {
        try { using var process = Process.GetProcessById((int)pid); return process.ProcessName + ".exe"; }
        catch (Exception e) when (e is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception) { return ""; }
    }
    private static string ForegroundExe()
    {
        var foreground = Native.GetForegroundWindow();
        Native.GetWindowThreadProcessId(foreground, out var pid);
        var exe = ProcessExe(pid);
        if (!exe.Equals("ApplicationFrameHost.exe", StringComparison.OrdinalIgnoreCase)) return exe;
        var children = new List<uint>();
        Native.EnumChildWindows(foreground, (child, _) =>
        {
            Native.GetWindowThreadProcessId(child, out var childPid);
            children.Add(childPid);
            return childPid == 0 || childPid == pid;
        }, 0);
        return ProcessExe(ForegroundProcess.Resolve(pid, exe, children));
    }

    private bool ApplyLocked(string? app)
    {
        var current = clip;
        if (current is null) return true;
        if (Native.GetClipboardSequenceNumber() != current.Sequence) return false;
        var wanted = app is null ? current.Clean : Engine.Preview(current.Clean, app);
        if (wanted == current.Text) return true;
        // Allocate both paths before emptying, including the source privacy restrictions.
        var blocks = new List<(uint Format, nint Memory)>();
        var fallback = new List<(uint Format, nint Memory)>();
        try
        {
            Prepare(blocks, wanted, current.Privacy, wanted != current.Clean);
            Prepare(fallback, current.Clean, current.Privacy, false);
            if (Native.GetClipboardSequenceNumber() != current.Sequence || !Native.EmptyClipboard()) return false;
            if (!Publish(blocks))
            {
                // Re-establish ALL source markers before publishing fallback text.
                if (!Native.EmptyClipboard() || !Publish(fallback)) { clip = null; seen = Native.GetClipboardSequenceNumber(); return true; }
                wanted = current.Clean;
            }
            var ours = Native.GetClipboardSequenceNumber();
            clip = current with { Sequence = ours, Text = wanted, Owned = true };
            seen = ours;
            return true;
        }
        finally
        {
            foreach (var block in blocks.Concat(fallback)) if (block.Memory != 0) Native.GlobalFree(block.Memory);
        }
    }
    private static void Prepare(List<(uint Format, nint Memory)> blocks, string text, ClipboardPrivacy privacy, bool preview)
    {
        foreach (var name in privacy.Markers(preview)) blocks.Add((PrivateFormats[name], Allocate(new byte[4])));
        blocks.Add((13, Allocate(Encoding.Unicode.GetBytes(text + "\0"))));
    }
    private static bool Publish(List<(uint Format, nint Memory)> blocks)
    {
        // Markers always precede text. A failed restriction must never publish text.
        for (var i = 0; i < blocks.Count; i++)
        {
            var block = blocks[i];
            if (Native.SetClipboardData(block.Format, block.Memory) == 0) return false;
            blocks[i] = (block.Format, 0);
        }
        return true;
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
        if (clip is { Owned: true } current && current.Text != current.Clean)
            restoration ??= new(current.Sequence, DateTimeOffset.UtcNow);
        Request();
    }
    public async Task RestoreBeforeQuit()
    {
        paused = true;
        RestoreClean();
        var deadline = DateTimeOffset.UtcNow.AddSeconds(10);
        while (restoration is not null && DateTimeOffset.UtcNow < deadline) await Task.Delay(50);
    }
    public void Dispose()
    {
        retry.Stop();
        Native.UnhookWinEvent(hook);
        Native.RemoveClipboardFormatListener(window.Handle);
        window.Dispose();
    }
}
