using System.Text;
using System.Text.RegularExpressions;

namespace Fxclip.Engine;

public sealed class Engine(Rules rules)
{
    public Rules Rules { get; } = rules;
    private static readonly Regex Urls = new("https?://[^\\s<>\"'`]+", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    private static readonly Regex RefPath = new(@"/ref=[^/]*$", RegexOptions.CultureInvariant);
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);

    public static bool IsBareUrl(string text)
    {
        var trimmed = text.Trim();
        var m = Urls.Match(trimmed);
        return m.Success && m.Index == 0 && m.Length == trimmed.Length;
    }

    public (string Text, int Removed) Clean(string text)
    {
        var removed = 0;
        var result = MapUrls(text, url => CleanUrl(url, ref removed));
        return (result, removed);
    }

    private string CleanUrl(string url, ref int removed)
    {
        var host = Host(url);
        if (host is null || (Rules.NeverClean ?? []).Any(h => h.Covers(host))) return url;
        var hash = url.IndexOf('#');
        var fragment = hash < 0 ? "" : url[hash..];
        var beforeHash = hash < 0 ? url : url[..hash];
        var q = beforeHash.IndexOf('?');
        var basis = q < 0 ? beforeHash : beforeHash[..q];
        string[] segments = q < 0 || q == beforeHash.Length - 1 ? [] : beforeHash[(q + 1)..].Split('&');
        var sites = Rules.Trackers.Sites.Where(s => s.Hosts.Any(d => host == d || host.EndsWith("." + d, StringComparison.Ordinal))).ToArray();
        var changedPath = sites.Any(s => s.StripRefPath == true) && RefPath.IsMatch(basis);
        if (changedPath) basis = RefPath.Replace(basis, "");
        var local = sites.SelectMany(s => s.Params).ToHashSet(StringComparer.Ordinal);
        var global = Rules.Trackers.Everywhere;
        var kept = segments.Where(segment =>
        {
            var equal = segment.IndexOf('=');
            var raw = equal < 0 ? segment : segment[..equal];
            var name = PercentDecode(raw) ?? raw;
            return !global.Params.Contains(name, StringComparer.Ordinal) && !local.Contains(name)
                && !global.Prefixes.Any(p => name.StartsWith(p, StringComparison.OrdinalIgnoreCase));
        }).ToArray();
        if (kept.Length == segments.Length && !changedPath) return url;
        removed += segments.Length - kept.Length + (changedPath ? 1 : 0);
        return basis + (kept.Length == 0 ? "" : "?" + string.Join('&', kept)) + fragment;
    }

    public PreviewRule[] PreviewsFor(string identifier)
    {
        var ids = Rules.Apps.Where(a => a.Matches(identifier)).Select(a => a.Id).ToHashSet(StringComparer.Ordinal);
        return Rules.Previews.Where(p => p.Apps.Any(ids.Contains)).ToArray();
    }

    public string Preview(string text, string identifier)
    {
        var active = PreviewsFor(identifier);
        if (active.Length == 0) return text;
        return MapUrls(text, url =>
        {
            var schemeLength = url.StartsWith("https://", StringComparison.OrdinalIgnoreCase) ? 8 : 7;
            var slash = url.IndexOf('/', schemeLength);
            if (slash < 0) return url;
            var host = url[schemeLength..slash].ToLowerInvariant();
            var rule = active.FirstOrDefault(p => p.From.Contains(host, StringComparer.Ordinal));
            return rule is null ? url : "https://" + rule.To + url[slash..];
        });
    }

    private static string MapUrls(string text, Func<string, string> map)
    {
        var output = text;
        foreach (Match match in Urls.Matches(text).Reverse())
        {
            var end = match.Index + match.Length;
            var parens = 0;
            var brackets = 0;
            foreach (var ch in match.Value)
            {
                if (ch == '(') parens++;
                if (ch == ')') parens--;
                if (ch == '[') brackets++;
                if (ch == ']') brackets--;
            }
            while (end > match.Index)
            {
                var last = output[end - 1];
                if (last == ')' && parens < 0) parens++;
                else if (last == ']' && brackets < 0) brackets++;
                else if (!".,;:!?".Contains(last)) break;
                end--;
            }
            output = output[..match.Index] + map(output[match.Index..end]) + output[end..];
        }
        return output;
    }

    // Extract just the host. Never round-trip through System.Uri: it changes raw URLs.
    public static string? Host(string url)
    {
        var scheme = url.IndexOf("://", StringComparison.Ordinal);
        if (scheme < 0) return null;
        var end = url.IndexOfAny(['/', '?', '#'], scheme + 3);
        var authority = end < 0 ? url[(scheme + 3)..] : url[(scheme + 3)..end];
        var at = authority.LastIndexOf('@');
        if (at >= 0) authority = authority[(at + 1)..];
        if (authority.StartsWith('['))
        {
            var close = authority.IndexOf(']');
            return close < 0 ? null : authority[..(close + 1)].ToLowerInvariant();
        }
        var colon = authority.LastIndexOf(':');
        if (colon >= 0)
        {
            if (authority[(colon + 1)..].Any(c => c is < '0' or > '9')) return null;
            authority = authority[..colon];
        }
        var decoded = PercentDecode(authority);
        return string.IsNullOrEmpty(decoded) || decoded.Any(c => char.IsWhiteSpace(c) || "\\[]".Contains(c)) ? null : decoded.ToLowerInvariant();
    }

    private static string? PercentDecode(string raw)
    {
        try
        {
            var output = new StringBuilder();
            for (var i = 0; i < raw.Length; i++)
            {
                if (raw[i] != '%') { output.Append(raw[i]); continue; }
                var bytes = new List<byte>();
                while (i < raw.Length && raw[i] == '%')
                {
                    if (i + 2 >= raw.Length || !byte.TryParse(raw.AsSpan(i + 1, 2), System.Globalization.NumberStyles.HexNumber, null, out var b)) return null;
                    bytes.Add(b);
                    i += 3;
                }
                i--;
                output.Append(StrictUtf8.GetString(bytes.ToArray()));
            }
            return output.ToString();
        }
        catch (DecoderFallbackException) { return null; }
    }
}
