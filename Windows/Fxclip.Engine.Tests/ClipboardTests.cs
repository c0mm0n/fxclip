using Fxclip;
using Xunit;
using Cleaner = Fxclip.Engine.Engine;

namespace Fxclip.Engine.Tests;

public class ClipboardTests
{
    [Theory]
    [InlineData("Chromium internal source URL")]
    [InlineData("Ole Private Data")]
    [InlineData("DataObject")]
    [InlineData("text/x-moz-url")]
    [InlineData("UniformResourceLocatorW")]
    [InlineData("HTML Format")]
    [InlineData("Rich Text Format")]
    [InlineData("Locale")]
    public void BrowserMetadataRequiresOneBareUrl(string name)
    {
        var policy = ClipboardPolicy.Read([new(13), new(50000, name)]);
        Assert.True(policy.Allowed);
        Assert.True(policy.BareUrlOnly);
        Assert.True(Cleaner.IsBareUrl("https://example.com/?utm_source=browser"));
        Assert.False(Cleaner.IsBareUrl("Read https://example.com/?utm_source=browser"));
    }

    [Fact]
    public void PlainTextAllowsProse()
    {
        var policy = ClipboardPolicy.Read([new(13), new(1), new(7)]);
        Assert.True(policy.Allowed);
        Assert.False(policy.BareUrlOnly);
    }

    [Theory]
    [InlineData(2, "")]
    [InlineData(3, "")]
    [InlineData(8, "")]
    [InlineData(14, "")]
    [InlineData(15, "")]
    [InlineData(17, "")]
    [InlineData(50000, "FileGroupDescriptorW")]
    [InlineData(50000, "FileName")]
    [InlineData(50000, "FileNameW")]
    [InlineData(50000, "FileName(W)")]
    [InlineData(50000, "PNG")]
    [InlineData(50000, "image/jpeg")]
    public void FilesAndImagesAreNeverRead(uint id, string name) =>
        Assert.False(ClipboardPolicy.Read([new(13), new(id, name)]).Allowed);

    [Fact]
    public void MissingUnicodeAndExcludedSourcesAreNeverRead()
    {
        Assert.False(ClipboardPolicy.Read([new(1)]).Allowed);
        Assert.False(ClipboardPolicy.Read([new(13), new(50000, ClipboardPolicy.Exclude)]).Allowed);
    }

    [Theory]
    [InlineData(true, false)]
    [InlineData(false, true)]
    [InlineData(true, true)]
    [InlineData(false, false)]
    public void SourcePrivacySurvivesCleanPreviewFallbackAndRestore(bool history, bool cloud)
    {
        var privacy = new ClipboardPrivacy(history, cloud);
        foreach (var path in new[] { "clean", "preview", "fallback", "restore" })
        {
            var markers = privacy.Markers(path == "preview").ToArray();
            Assert.Equal(history || path == "preview", markers.Contains(ClipboardPolicy.History));
            Assert.Equal(cloud || path == "preview", markers.Contains(ClipboardPolicy.Cloud));
            Assert.Equal(path == "preview", markers.Contains(ClipboardPolicy.Exclude));
        }
    }

    [Theory]
    [InlineData(42, "preview", true)]
    [InlineData(43, "preview", false)]
    [InlineData(0, "preview", false)]
    [InlineData(42, "new copy", false)]
    public void ClosedWriteRequiresOwnerAndExactText(int owner, string actual, bool expected) =>
        Assert.Equal(expected, ClipboardPolicy.IsOwnWrite(42, owner, "preview", actual));

    [Fact]
    public void OwnWriteSequenceAdvanceDoesNotSupersedeRestore()
    {
        var pending = new PendingRestoration(10, DateTimeOffset.UtcNow);
        Assert.False(pending.SupersededBy(11, ownWrite: true));
        Assert.True(pending.SupersededBy(11, ownWrite: false));
        Assert.False(pending.SupersededBy(10, ownWrite: false));
    }

    [Fact]
    public void BusyRestoreRetriesWithoutBlockingAndStaysPendingWhilePaused()
    {
        var start = DateTimeOffset.UtcNow;
        var pending = new PendingRestoration(10, start);
        Assert.Equal(TimeSpan.FromMilliseconds(200), pending.Delay(start.AddSeconds(1)));
        Assert.Equal(TimeSpan.FromMilliseconds(1000), pending.Delay(start.AddSeconds(11)));
        Assert.False(pending.SupersededBy(10, ownWrite: false));
    }

    [Fact]
    public void FrameHostResolvesFirstChildWithDifferentProcess()
    {
        Assert.Equal(25u, ForegroundProcess.Resolve(10, "ApplicationFrameHost.exe", [10, 0, 25, 30]));
        Assert.Equal(10u, ForegroundProcess.Resolve(10, "ApplicationFrameHost.exe", [10, 0]));
        Assert.Equal(10u, ForegroundProcess.Resolve(10, "Telegram.exe", [25]));
    }
}
