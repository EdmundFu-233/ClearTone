namespace ClearTone.Core.Security;

public static class NeteaseCookieNormalizer
{
    private static readonly HashSet<string> AttributeNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "expires", "max-age", "path", "domain", "secure",
        "httponly", "samesite", "priority", "comment", "version",
    };

    public static string Normalize(string raw)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var pairs = new List<string>();

        foreach (var segment in raw.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var item = segment.Trim();
            if (item.Length == 0) continue;
            var separator = item.IndexOf('=');
            if (separator < 0) continue;
            var name = item[..separator].Trim();
            var value = item[(separator + 1)..].Trim();

            if (name.Length == 0 || value.Length == 0) continue;
            if (AttributeNames.Contains(name)) continue;
            if (!seen.Add(name)) continue;
            pairs.Add($"{name}={value}");
        }

        return string.Join("; ", pairs);
    }

    public static string Normalized(string raw)
    {
        var result = Normalize(raw);
        return result == raw.Trim() ? raw : result;
    }
}
