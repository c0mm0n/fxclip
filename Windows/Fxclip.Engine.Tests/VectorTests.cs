using System.Text.Json;
using Fxclip.Engine;
using Xunit;
using Cleaner = Fxclip.Engine.Engine;

namespace Fxclip.Engine.Tests;

public class VectorTests
{
    private static string Shared(string file)
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null)
        {
            var path = Path.Combine(dir.FullName, "Shared", file);
            if (File.Exists(path)) return path;
            dir = dir.Parent;
        }
        throw new FileNotFoundException("Run tests from the repository checkout.");
    }

    public static IEnumerable<object[]> Vectors()
    {
        using var doc = JsonDocument.Parse(File.ReadAllText(Shared("vectors.json")));
        foreach (var v in doc.RootElement.GetProperty("vectors").EnumerateArray())
            yield return [v.GetProperty("input").GetString()!, v.GetProperty("clean").GetString()!, v.GetProperty("telegram").GetString()!];
    }

    [Theory]
    [MemberData(nameof(Vectors))]
    public void SharedVector(string input, string clean, string telegram)
    {
        var engine = new Cleaner(Rules.BuiltIn());
        var result = engine.Clean(input);
        Assert.Equal(clean, result.Text);
        Assert.Equal(telegram, engine.Preview(result.Text, "Telegram.exe"));
        Assert.Equal(clean, engine.Preview(result.Text, "notepad.exe"));
    }

    public static IEnumerable<object[]> SettingsVectors()
    {
        using var doc = JsonDocument.Parse(File.ReadAllText(Shared("settings_vectors.json")));
        foreach (var group in doc.RootElement.GetProperty("groups").EnumerateArray())
            foreach (var c in group.GetProperty("cases").EnumerateArray())
                yield return [group.GetProperty("name").GetString()!, group.GetProperty("settings").GetRawText(),
                    c.GetProperty("input").GetString()!, c.GetProperty("app").GetString() ?? "", c.GetProperty("output").GetString()!];
    }

    [Theory]
    [MemberData(nameof(SettingsVectors))]
    public void SharedSettingsVector(string group, string json, string input, string app, string expected)
    {
        Assert.NotEmpty(group);
        var settings = UserSettings.Parse(json);
        var engine = new Cleaner(Rules.BuiltIn().Applying(settings));
        var clean = engine.Clean(input).Text;
        Assert.Equal(expected, app.Length == 0 ? clean : engine.Preview(clean, app));
        var roundTrip = new Cleaner(Rules.BuiltIn().Applying(UserSettings.Parse(settings.ToJson())));
        Assert.Equal(clean, roundTrip.Clean(input).Text);
    }

    [Theory]
    [InlineData("https://example.com/?q=a+b%2Bc==&utm_source=x#Keep%20This", "https://example.com/?q=a+b%2Bc==#Keep%20This", 1)]
    [InlineData("https://example.com/?utm_%FF=x&fbclid=a", "https://example.com/", 2)]
    [InlineData("https://amazon.com/dp/A/ref=x?tag=z", "https://amazon.com/dp/A", 2)]
    [InlineData("https://amazon.com/dp/A/ref=x?#f", "https://amazon.com/dp/A?#f", 1)]
    public void RawBytesAndCounts(string input, string expected, int count)
    {
        var result = new Cleaner(Rules.BuiltIn()).Clean(input);
        Assert.Equal(expected, result.Text);
        Assert.Equal(count, result.Removed);
    }

    [Theory]
    [InlineData("  https://x.com/a  ", true)]
    [InlineData("A https://x.com/a", false)]
    [InlineData("https://x.com/a https://x.com/b", false)]
    public void BareUrl(string text, bool expected) => Assert.Equal(expected, Cleaner.IsBareUrl(text));

    [Theory]
    [InlineData("{\"disabledSites\":[null]}")]
    [InlineData("{\"addedApps\":[{\"id\":\"a\",\"name\":\"A\",\"bundleIDs\":[null]}]}")]
    [InlineData("{\"previews\":{\"x\":{\"enabled\":true,\"apps\":[null]}}}")]
    [InlineData("{\"neverClean\":[{\"host\":\"example.com\"}]}")]
    public void MalformedNestedSettingsAreRejected(string json) => Assert.Throws<JsonException>(() => UserSettings.Parse(json));

    [Fact]
    public void MissingAndNullSettingsUseDefaults()
    {
        var s = UserSettings.Parse("{\"trackersEverywhere\":null,\"previews\":{\"x\":{\"enabled\":false,\"apps\":[]}}}");
        Assert.True(s.TrackersEverywhere);
        Assert.False(s.Previews["x"].Enabled);
        Assert.Throws<JsonException>(() => UserSettings.Parse("{\"previews\":{\"x\":{}}}"));
    }
}
