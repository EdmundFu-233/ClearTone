using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using ClearTone.Core.Logging;
using ClearTone.Core.Models;

namespace ClearTone.Core.Security;

public enum CredentialKey
{
    NeteaseCookie,
    NeteaseUserID,
    HelperAuthToken,
}

public sealed class CredentialStore
{
    public static readonly CredentialStore Shared = new();

    private readonly object _gate = new();
    private readonly Dictionary<string, string> _values = new(StringComparer.Ordinal);
    private readonly string _path;
    private bool _loaded;

    public static string StorageRoot => ClearTone.Core.Persistence.StoragePaths.Root;

    public CredentialStore(string? path = null)
    {
        _path = path ?? Path.Combine(StorageRoot, "credentials.json");
    }

    public string? Load(CredentialKey key)
    {
        lock (_gate)
        {
            EnsureLoaded();
            return _values.TryGetValue(NameOf(key), out var value) ? value : null;
        }
    }

    public void Save(string value, CredentialKey key)
    {
        lock (_gate)
        {
            EnsureLoaded();
            _values[NameOf(key)] = value;
            Persist();
        }
    }

    public void Delete(CredentialKey key)
    {
        lock (_gate)
        {
            EnsureLoaded();
            if (_values.Remove(NameOf(key)))
            {
                Persist();
            }
        }
    }

    public bool Has(CredentialKey key)
    {
        lock (_gate)
        {
            EnsureLoaded();
            return _values.ContainsKey(NameOf(key));
        }
    }

    private static string NameOf(CredentialKey key) => key switch
    {
        CredentialKey.NeteaseCookie => "netease_cookie",
        CredentialKey.NeteaseUserID => "netease_user_id",
        _ => "helper_auth_token",
    };

    private void EnsureLoaded()
    {
        if (_loaded) return;
        _loaded = true;
        try
        {
            if (!File.Exists(_path)) return;
            var json = JsonDocument.Parse(File.ReadAllBytes(_path));
            if (!json.RootElement.TryGetProperty("values", out var values) ||
                values.ValueKind != JsonValueKind.Object)
            {
                return;
            }
            foreach (var property in values.EnumerateObject())
            {
                var raw = property.Value.GetString();
                if (raw is null) continue;
                var decoded = Unprotect(raw);
                if (decoded is not null) _values[property.Name] = decoded;
            }
        }
        catch (Exception error)
        {
            CTLog.Security.Warn($"读取凭据失败：{error.CtUserMessage()}");
        }
    }

    private void Persist()
    {
        try
        {
            var directory = Path.GetDirectoryName(_path);
            if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);

            var payload = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (var pair in _values)
            {
                payload[pair.Key] = Protect(pair.Value);
            }
            var json = JsonSerializer.Serialize(new Dictionary<string, object> { ["values"] = payload });
            var temp = _path + ".tmp";
            File.WriteAllBytes(temp, Encoding.UTF8.GetBytes(json));
            File.Move(temp, _path, overwrite: true);
            RestrictPermissions(_path);
        }
        catch (Exception error)
        {
            CTLog.Security.Warn($"写入凭据失败：{error.CtUserMessage()}");
        }
    }

    private static void RestrictPermissions(string path)
    {
        if (OperatingSystem.IsWindows()) return;
        try
        {
            File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
        }
        catch
        {
        }
    }

    private static string Protect(string value)
    {
        var bytes = Encoding.UTF8.GetBytes(value);
        if (OperatingSystem.IsWindows())
        {
            try
            {
                var protectedBytes = ProtectedData.Protect(bytes, null, DataProtectionScope.CurrentUser);
                return "dpapi:" + Convert.ToBase64String(protectedBytes);
            }
            catch (Exception error)
            {
                CTLog.Security.Warn($"凭据加密失败，退回明文存储：{error.CtUserMessage()}");
            }
        }
        return "plain:" + Convert.ToBase64String(bytes);
    }

    private static string? Unprotect(string raw)
    {
        try
        {
            if (raw.StartsWith("dpapi:", StringComparison.Ordinal))
            {
                if (!OperatingSystem.IsWindows()) return null;
                var bytes = ProtectedData.Unprotect(
                    Convert.FromBase64String(raw["dpapi:".Length..]), null, DataProtectionScope.CurrentUser);
                return Encoding.UTF8.GetString(bytes);
            }
            if (raw.StartsWith("plain:", StringComparison.Ordinal))
            {
                return Encoding.UTF8.GetString(Convert.FromBase64String(raw["plain:".Length..]));
            }
            return null;
        }
        catch (Exception error)
        {
            CTLog.Security.Warn($"凭据解密失败：{error.CtUserMessage()}");
            return null;
        }
    }
}
