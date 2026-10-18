using System;
using System.Collections.Generic;
using System.Linq;

namespace Fxclip;

internal readonly record struct ClipboardFormat(uint Id, string Name = "");
internal readonly record struct ClipboardReadPolicy(bool Allowed, bool BareUrlOnly);
internal readonly record struct ClipboardPrivacy(bool NoHistory, bool NoCloud)
{
    public IEnumerable<string> Markers(bool preview)
    {
        if (preview) yield return ClipboardPolicy.Exclude;
        if (preview || NoHistory) yield return ClipboardPolicy.History;
        if (preview || NoCloud) yield return ClipboardPolicy.Cloud;
    }
}

// Pure decisions shared by the native listener and its cross-platform tests.
internal static class ClipboardPolicy
{
    public const string Exclude = "ExcludeClipboardContentFromMonitorProcessing";
    public const string History = "CanIncludeInClipboardHistory";
    public const string Cloud = "CanUploadToCloudClipboard";

    public static ClipboardReadPolicy Read(IEnumerable<ClipboardFormat> source)
    {
        var formats = source.ToArray();
        if (!formats.Any(f => f.Id == 13) || formats.Any(f => f.Name.Equals(Exclude, StringComparison.OrdinalIgnoreCase) || IsFileOrImage(f)))
            return new(false, false);
        return new(true, formats.Any(f => f.Id is not (1 or 7 or 13)
            && f.Name is not (History or Cloud)));
    }

    private static bool IsFileOrImage(ClipboardFormat format)
    {
        var name = format.Name;
        return format.Id is 2 or 3 or 8 or 14 or 15 or 17
            || name.Equals("PNG", StringComparison.OrdinalIgnoreCase)
            || name.StartsWith("image/", StringComparison.OrdinalIgnoreCase)
            || name.StartsWith("FileGroupDescriptor", StringComparison.OrdinalIgnoreCase)
            || name.StartsWith("FileName", StringComparison.OrdinalIgnoreCase)
            || name.Equals("FileContents", StringComparison.OrdinalIgnoreCase)
            || name.Equals("FileDrop", StringComparison.OrdinalIgnoreCase)
            || name.Equals("Shell IDList Array", StringComparison.OrdinalIgnoreCase);
    }

    public static bool IsOwnWrite(nint window, nint owner, string expected, string? actual) =>
        window != 0 && owner == window && string.Equals(expected, actual, StringComparison.Ordinal);
}

internal sealed record PendingRestoration(uint Sequence, DateTimeOffset Started)
{
    public bool SupersededBy(uint sequence, bool ownWrite) => sequence != Sequence && !ownWrite;
    // Stay pending while paused, backing off after ten seconds. Quit waits at most ten seconds.
    public TimeSpan Delay(DateTimeOffset now) => TimeSpan.FromMilliseconds((now - Started).TotalSeconds < 10 ? 200 : 1000);
}

internal static class ForegroundProcess
{
    public static uint Resolve(uint foreground, string exe, IEnumerable<uint> children) =>
        exe.Equals("ApplicationFrameHost.exe", StringComparison.OrdinalIgnoreCase)
            ? children.FirstOrDefault(pid => pid != 0 && pid != foreground, foreground) : foreground;
}
