using System.Text.Json;
using System.Text.Json.Nodes;

namespace Fxclip.Engine;

public sealed record ParamSet(string[] Params, string[] Prefixes);
public sealed record Site(string Id, string Name, string[] Hosts, string[] Params, bool? StripRefPath);
public sealed record PreviewRule(string Id, string Name, string[] From, string To, string[] Apps);
public sealed record AppRule(string Id, string Name, string[] BundleIDs, string[]? Linux = null, string[]? Windows = null)
{
    public bool Matches(string identifier) => BundleIDs.Contains(identifier, StringComparer.Ordinal)
        || (Linux ?? []).Concat(Windows ?? []).Contains(identifier, StringComparer.OrdinalIgnoreCase);
}
public sealed record Trackers(ParamSet Everywhere, Site[] Sites);
public sealed record SkipHost(string Host, bool Subdomains)
{
    public static string Canonical(string host)
    {
        var canonical = host.ToLowerInvariant().TrimEnd('.');
        // Compare IDNs in one form, without ever round-tripping the copied URL.
        try { return new System.Globalization.IdnMapping().GetAscii(canonical).ToLowerInvariant(); }
        catch (ArgumentException) { return canonical; }
    }
    public bool Covers(string host) => Canonical(host) == Canonical(Host)
        || (Subdomains && Canonical(host).EndsWith("." + Canonical(Host), StringComparison.Ordinal));
}
public sealed record PreviewSetting(bool Enabled, string[] Apps, string? TargetHost = null);

public sealed class UserSettings
{
    public int Version { get; set; } = 1;
    public bool TrackersEverywhere { get; set; } = true;
    public bool PreviewDefaultsEnabled { get; set; } = true;
    public HashSet<string> DisabledSites { get; set; } = [];
    public List<SkipHost> NeverClean { get; set; } = [];
    public Dictionary<string, PreviewSetting> Previews { get; set; } = [];
    public List<AppRule> AddedApps { get; set; } = [];

    public static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true };

    // Swift decodeIfPresent treats absent AND null top-level keys as defaults.
    public static UserSettings Parse(string json)
    {
        var node = JsonNode.Parse(json) as JsonObject ?? throw new JsonException("Expected settings object.");
        var hasPreviewDefaults = node.ContainsKey("previewDefaultsEnabled");
        foreach (var key in node.Where(p => p.Value is null).Select(p => p.Key).ToArray()) node.Remove(key);
        var settings = node.Deserialize<UserSettings>(Json) ?? throw new JsonException();
        if (settings.DisabledSites.Any(s => s is null)) throw new JsonException("Invalid site.");
        foreach (var h in settings.NeverClean)
            if (h is null || h.Host is null) throw new JsonException("Invalid host.");
        foreach (var p in settings.Previews.Values)
            if (p is null || p.Apps is null || p.Apps.Any(a => a is null)) throw new JsonException("Invalid preview.");
        foreach (var a in settings.AddedApps)
            if (a is null || a.Id is null || a.Name is null || a.BundleIDs is null || a.BundleIDs.Any(id => id is null) || (a.Linux ?? []).Any(id => id is null) || (a.Windows ?? []).Any(id => id is null)) throw new JsonException("Invalid app.");
        // These fields are mandatory inside the nested Swift Codable types.
        if (node["previews"] is JsonObject previews)
            foreach (var p in previews.Select(p => p.Value))
                if (p is not JsonObject obj || !obj.ContainsKey("enabled") || !obj.ContainsKey("apps")) throw new JsonException("Incomplete preview.");
        if (node["neverClean"] is JsonArray hosts)
            foreach (var h in hosts)
                if (h is not JsonObject obj || !obj.ContainsKey("host") || !obj.ContainsKey("subdomains")) throw new JsonException("Incomplete host.");
        if (!hasPreviewDefaults)
            settings.PreviewDefaultsEnabled = !(settings.Previews.TryGetValue("x", out var x) && !x.Enabled
                && settings.Previews.TryGetValue("instagram", out var instagram) && !instagram.Enabled);
        return settings;
    }
    public string ToJson() => JsonSerializer.Serialize(this, Json);
}

public sealed record Rules(int Version, Trackers Trackers, PreviewRule[] Previews, AppRule[] Apps, SkipHost[]? NeverClean)
{
    // A provider is a plain ASCII DNS host, never a URL. Only outer ASCII whitespace is trimmed.
    public static string? CanonicalPreviewHost(string raw)
    {
        var host = raw.Trim(' ', '\t', '\r', '\n', '\v', '\f');
        if (host.EndsWith('.')) host = host[..^1];
        if (host.Length > 253) return null;
        var labels = host.Split('.');
        if (labels.Length < 2 || labels.Any(label => label.Length is < 1 or > 63
            || label[0] == '-' || label[^1] == '-'
            || label.Any(c => !(c is >= 'a' and <= 'z' or >= 'A' and <= 'Z' or >= '0' and <= '9' or '-')))) return null;
        return host.ToLowerInvariant();
    }

    public static Rules BuiltIn()
    {
        using var stream = typeof(Rules).Assembly.GetManifestResourceStream("Fxclip.rules.json")!;
        return JsonSerializer.Deserialize<Rules>(stream, UserSettings.Json)!;
    }
    public Rules Applying(UserSettings user) => this with
    {
        Trackers = new(user.TrackersEverywhere ? Trackers.Everywhere : new([], []),
            Trackers.Sites.Where(s => !user.DisabledSites.Contains(s.Id)).ToArray()),
        NeverClean = user.NeverClean.ToArray(),
        Apps = Apps.Concat(user.AddedApps.Where(a => !Apps.Any(b => b.Id == a.Id))).ToArray(),
        Previews = Previews.Where(p => user.Previews.TryGetValue(p.Id, out var s) ? s.Enabled : user.PreviewDefaultsEnabled)
            .Select(p => user.Previews.TryGetValue(p.Id, out var s)
                ? p with { Apps = s.Apps, To = s.TargetHost is { } raw ? CanonicalPreviewHost(raw) ?? p.To : p.To } : p).ToArray()
    };
}
