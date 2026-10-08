using System.Text.RegularExpressions;
using ClearTone.Core.Models;

namespace ClearTone.Providers.Netease;

public static class LRCParser
{
    private static readonly Regex TimePattern = new(@"\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]", RegexOptions.Compiled);
    private static readonly Regex YrcLinePattern = new(@"\[(\d+),(\d+)\]([^\[]*)", RegexOptions.Compiled);
    private static readonly Regex YrcWordPattern = new(@"([^(]+)\((\d+),(\d+),\d+\)", RegexOptions.Compiled);

    public static List<LyricLine> Parse(string lrc, string? translation = null, string? romanization = null)
    {
        var mainLines = ParseLrc(lrc);
        var transLines = translation is null ? new List<LyricLine>() : ParseLrc(translation);
        var romaLines = romanization is null ? new List<LyricLine>() : ParseLrc(romanization);

        var merged = new Dictionary<double, LyricLine>();
        foreach (var line in mainLines)
        {
            merged[line.Time] = line;
        }
        foreach (var line in transLines)
        {
            if (merged.TryGetValue(line.Time, out var existing)) existing.Translation = line.Text;
        }
        foreach (var line in romaLines)
        {
            if (merged.TryGetValue(line.Time, out var existing)) existing.Romanization = line.Text;
        }

        return merged.OrderBy(pair => pair.Key).Select(pair => pair.Value).ToList();
    }

    public static List<LyricLine> ParseYRC(string yrc, string? translation = null, string? romanization = null)
    {
        var lines = new List<LyricLine>();
        foreach (Match match in YrcLinePattern.Matches(yrc))
        {
            if (match.Groups.Count < 4) continue;
            var startMs = double.TryParse(match.Groups[1].Value, out var start) ? start : 0;
            var content = match.Groups[3].Value;
            var time = startMs / 1000.0;
            var words = ParseYRCWords(content);
            var line = new LyricLine
            {
                Time = time,
                Text = string.Concat(words.Select(word => word.Text)),
                Words = words,
            };
            lines.Add(line);
        }

        if (!string.IsNullOrEmpty(translation))
        {
            var translationMap = new Dictionary<double, string>();
            foreach (var line in ParseLrc(translation))
            {
                translationMap[line.Time] = line.Text;
            }
            foreach (var line in lines)
            {
                if (translationMap.TryGetValue(line.Time, out var text)) line.Translation = text;
            }
        }

        if (!string.IsNullOrEmpty(romanization))
        {
            var romanizationMap = new Dictionary<double, string>();
            foreach (var line in ParseLrc(romanization))
            {
                romanizationMap[line.Time] = line.Text;
            }
            foreach (var line in lines)
            {
                if (romanizationMap.TryGetValue(line.Time, out var text)) line.Romanization = text;
            }
        }

        return lines.OrderBy(line => line.Time).ToList();
    }

    private static List<LyricWord> ParseYRCWords(string content)
    {
        var words = new List<LyricWord>();
        foreach (Match match in YrcWordPattern.Matches(content))
        {
            if (match.Groups.Count < 4) continue;
            var text = match.Groups[1].Value;
            var startMs = double.TryParse(match.Groups[2].Value, out var start) ? start : 0;
            var durationMs = double.TryParse(match.Groups[3].Value, out var duration) ? duration : 0;
            words.Add(new LyricWord
            {
                Time = startMs / 1000.0,
                Duration = durationMs / 1000.0,
                Text = text,
            });
        }
        return words;
    }

    private static List<LyricLine> ParseLrc(string lrc)
    {
        var lines = new List<LyricLine>();
        foreach (var rawLine in lrc.Split('\n'))
        {
            var line = rawLine.TrimEnd('\r');
            var matches = TimePattern.Matches(line);
            if (matches.Count == 0) continue;

            var textEnd = 0;
            foreach (Match match in matches)
            {
                textEnd = Math.Max(textEnd, match.Index + match.Length);
            }
            var text = line[textEnd..].Trim();

            foreach (Match match in matches)
            {
                var minutes = double.TryParse(match.Groups[1].Value, out var mm) ? mm : 0;
                var seconds = double.TryParse(match.Groups[2].Value, out var ss) ? ss : 0;
                var fraction = 0.0;
                if (match.Groups[3].Success)
                {
                    var fractionText = match.Groups[3].Value;
                    var parsed = double.TryParse(fractionText, out var value) ? value : 0;
                    fraction = parsed / Math.Pow(10, fractionText.Length);
                }
                lines.Add(new LyricLine
                {
                    Time = minutes * 60 + seconds + fraction,
                    Text = text,
                });
            }
        }

        return lines.OrderBy(line => line.Time).ToList();
    }

    public static int? CurrentLineIndex(IReadOnlyList<LyricLine> lines, double time, double offset = 0)
    {
        if (lines.Count == 0) return null;
        var adjusted = time + offset;
        var low = 0;
        var high = lines.Count - 1;
        int? result = null;

        while (low <= high)
        {
            var mid = (low + high) / 2;
            if (lines[mid].Time <= adjusted)
            {
                result = mid;
                low = mid + 1;
            }
            else
            {
                high = mid - 1;
            }
        }
        return result;
    }
}
