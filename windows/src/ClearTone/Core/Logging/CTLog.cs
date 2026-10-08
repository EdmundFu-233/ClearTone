using System.Text;
using System.Text.RegularExpressions;

namespace ClearTone.Core.Logging;

public static class CTLog
{
    private static readonly string SecretKeys = string.Join("|", new[]
    {
        "MUSIC_U", "MUSIC_A", "MUSIC_R", "MUSIC_H", "__csrf", "__remember_me",
        "NMTID", "cookie", "set-cookie", "token", "access_token", "refresh_token",
        "key", "password", "pwd", "auth", "authorization", "secret", "session",
    });

    private static readonly (Regex Pattern, string Template)[] Rules =
    {
        (new Regex(@"\b((?:authorization|auth)\s*[=:]\s*)[^\n;,""'}]+", RegexOptions.IgnoreCase | RegexOptions.Compiled), "$1***"),
        (new Regex("\"((?:" + SecretKeys + "))\"\\s*:\\s*(?:\"[^\"]*\"|[^,}\\s]+)", RegexOptions.IgnoreCase | RegexOptions.Compiled), "\"$1\":\"***\""),
        (new Regex(@"\b((?:" + SecretKeys + @")\s*[=:]\s*)[^;,\s&}""']+", RegexOptions.IgnoreCase | RegexOptions.Compiled), "$1***"),
    };

    public static readonly LogChannel General = new("general");
    public static readonly LogChannel Network = new("network");
    public static readonly LogChannel Playback = new("playback");
    public static readonly LogChannel Helper = new("helper");
    public static readonly LogChannel Render = new("render");
    public static readonly LogChannel Security = new("security");

    public static string Sanitize(string message)
    {
        var result = message;
        foreach (var (pattern, template) in Rules)
        {
            result = pattern.Replace(result, template);
        }
        return result;
    }

    public static string Redact(string? value)
    {
        if (string.IsNullOrEmpty(value)) return "<empty>";
        if (value.Length <= 8) return "***";
        return $"{value[..4]}...{value[^4..]}";
    }
}

public sealed class LogChannel
{
    private readonly string _category;
    private static readonly object FileLock = new();
    private static readonly string? LogFile = ResolveLogFile();

    internal LogChannel(string category) => _category = category;

    public void Info(string message) => Write("INFO", message);
    public void Warn(string message) => Write("WARN", message);
    public void Error(string message) => Write("ERROR", message);
    public void Debug(string message) => Write("DEBUG", message);

    private void Write(string level, string message)
    {
        var safe = CTLog.Sanitize(message);
        var line = $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} [{level}] [{_category}] {safe}";
        System.Diagnostics.Debug.WriteLine(line);
        if (LogFile is null) return;
        try
        {
            lock (FileLock)
            {
                File.AppendAllText(LogFile, line + Environment.NewLine, Encoding.UTF8);
            }
        }
        catch
        {
        }
    }

    private static string? ResolveLogFile()
    {
        try
        {
            var root = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "ClearTone", "logs");
            Directory.CreateDirectory(root);
            return Path.Combine(root, "cleartone.log");
        }
        catch
        {
            return null;
        }
    }
}
