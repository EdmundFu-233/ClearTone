using System.Diagnostics;
using System.Net.Http;
using ClearTone.Core.Logging;
using ClearTone.Core.Models;

namespace ClearTone.Core.Networking;

public abstract record HelperState
{
    public sealed record Stopped : HelperState;
    public sealed record Starting : HelperState;
    public sealed record Running(int Port) : HelperState;
    public sealed record Failed(string Message) : HelperState;
}

public sealed class HelperProcessManager : IDisposable
{
    public static readonly HelperProcessManager Shared = new();

    private readonly object _gate = new();
    private readonly HttpClient _healthClient;
    private Process? _process;
    private int _port;
    private string _authToken = "";
    private Task? _startupTask;
    private CancellationTokenSource? _monitorCts;
    private Timer? _restartTimer;
    private volatile bool _stopping;

    private HelperProcessManager()
    {
        var handler = new SocketsHttpHandler
        {
            UseProxy = false,
            ConnectTimeout = TimeSpan.FromSeconds(2),
        };
        _healthClient = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(2) };
    }

    public HelperState State { get; private set; } = new HelperState.Stopped();
    public string? LastError { get; private set; }
    public string AuthToken => _authToken;

    public event Action? StateChanged;

    public static string RuntimeRoot
    {
        get
        {
            var overrideRoot = Environment.GetEnvironmentVariable("CLEARTONE_HELPER_ROOT");
            if (!string.IsNullOrEmpty(overrideRoot)) return overrideRoot;
            return Path.Combine(AppContext.BaseDirectory, "helper");
        }
    }

    private static string? DevRuntimeRoot
    {
        get
        {
            var dir = new DirectoryInfo(AppContext.BaseDirectory);
            for (var i = 0; i < 8 && dir is not null; i++)
            {
                var candidate = Path.Combine(dir.FullName, "ClearTone", "Resources", "HelperRuntime");
                if (Directory.Exists(candidate)) return candidate;
                dir = dir.Parent;
            }
            return null;
        }
    }

    public static string ResolveRuntimeDirectory()
    {
        var bundled = RuntimeRoot;
        if (Directory.Exists(bundled)) return bundled;
        return DevRuntimeRoot ?? bundled;
    }

    public static string ResolveNodeBinary(string runtimeDir)
    {
        var nodeOverride = Environment.GetEnvironmentVariable("CLEARTONE_HELPER_NODE");
        if (!string.IsNullOrEmpty(nodeOverride) && File.Exists(nodeOverride)) return nodeOverride;

        var candidates = OperatingSystem.IsWindows()
            ? new[] { Path.Combine(runtimeDir, "bin", "node.exe"), Path.Combine(runtimeDir, "bin", "node") }
            : new[] { Path.Combine(runtimeDir, "bin", "node"), Path.Combine(runtimeDir, "bin", "node.exe") };
        foreach (var candidate in candidates)
        {
            if (File.Exists(candidate)) return candidate;
        }
        return candidates[0];
    }

    public async Task StartIfNeededAsync(CancellationToken ct = default)
    {
        await StartAsync(ct).ConfigureAwait(false);
    }

    public Task StartAsync(CancellationToken ct = default)
    {
        lock (_gate)
        {
            if (_startupTask is not null) return _startupTask;
            if (State is not (HelperState.Stopped or HelperState.Failed)) return Task.CompletedTask;

            var task = PerformStartAsync(ct);
            _startupTask = task;
            _ = task.ContinueWith(_ =>
            {
                lock (_gate) _startupTask = null;
            }, CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
            return task;
        }
    }

    private void SetState(HelperState state)
    {
        State = state;
        StateChanged?.Invoke();
    }

    private async Task PerformStartAsync(CancellationToken ct)
    {
        SetState(new HelperState.Starting());
        LastError = null;

        var runtimeDir = ResolveRuntimeDirectory();
        if (!Directory.Exists(runtimeDir))
        {
            var msg = $"辅助进程运行时未找到: {runtimeDir}。请先运行 scripts/setup-helper.sh 或 windows/scripts/fetch-node-win.sh";
            SetState(new HelperState.Failed(msg));
            LastError = msg;
            throw MusicException.HelperProcessUnavailable();
        }

        var nodeBinary = ResolveNodeBinary(runtimeDir);
        var apiDir = Path.Combine(runtimeDir, "api");
        var apiScript = Path.Combine(apiDir, "app.js");
        if (!File.Exists(nodeBinary) || !File.Exists(apiScript))
        {
            var msg = "辅助进程文件不完整（缺少 node 或 app.js）";
            SetState(new HelperState.Failed(msg));
            LastError = msg;
            throw MusicException.HelperProcessUnavailable();
        }

        _port = Random.Shared.Next(21000, 29001);
        _authToken = Guid.NewGuid().ToString();

        var logDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "ClearTone", "logs");
        Directory.CreateDirectory(logDir);
        var logPath = Path.Combine(logDir, "helper.log");
        RotateLogIfNeeded(logPath);
        var logLock = new object();

        var psi = new ProcessStartInfo
        {
            FileName = nodeBinary,
            Arguments = QuoteArg(apiScript),
            WorkingDirectory = apiDir,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        psi.Environment["PORT"] = _port.ToString();
        psi.Environment["CT_AUTH_TOKEN"] = _authToken;
        psi.Environment["HOST"] = "127.0.0.1";
        psi.Environment["NODE_ENV"] = "production";
        psi.Environment["http_proxy"] = "";
        psi.Environment["https_proxy"] = "";
        psi.Environment["HTTP_PROXY"] = "";
        psi.Environment["HTTPS_PROXY"] = "";
        psi.Environment["no_proxy"] = "";
        psi.Environment["NO_PROXY"] = "";

        var proc = new Process { StartInfo = psi, EnableRaisingEvents = true };
        void AppendLog(string? line)
        {
            if (line is null) return;
            try
            {
                lock (logLock)
                {
                    File.AppendAllText(logPath, CTLog.Sanitize(line) + Environment.NewLine);
                }
            }
            catch
            {
            }
        }
        proc.OutputDataReceived += (_, e) => AppendLog(e.Data);
        proc.ErrorDataReceived += (_, e) => AppendLog(e.Data);

        proc.Exited += (_, _) =>
        {
            if (_stopping) return;
            lock (_gate)
            {
                if (!ReferenceEquals(_process, proc)) return;
            }
            var code = TryGetExitCode(proc);
            CTLog.Helper.Warn($"辅助进程意外退出，code: {code}");
            SetState(new HelperState.Failed($"辅助进程意外退出 (code {code})"));
            Cleanup();
            ScheduleRestart(TimeSpan.FromSeconds(1));
        };

        try
        {
            if (!proc.Start())
            {
                throw new InvalidOperationException("进程未启动");
            }
            proc.BeginOutputReadLine();
            proc.BeginErrorReadLine();
            lock (_gate) _process = proc;
        }
        catch (Exception error)
        {
            var message = error.CtUserMessage();
            SetState(new HelperState.Failed($"启动失败: {message}"));
            LastError = message;
            throw MusicException.HelperProcessUnavailable();
        }

        try
        {
            await WaitForHealthyAsync(TimeSpan.FromSeconds(15), ct).ConfigureAwait(false);
            SetState(new HelperState.Running(_port));
            CTLog.Helper.Info($"辅助进程启动成功，端口 {_port}");
            StartHealthMonitoring();
        }
        catch
        {
            StopProcess();
            SetState(new HelperState.Failed("健康检查超时"));
            LastError = "本地服务启动超时，请重试";
            throw MusicException.HelperProcessTimeout();
        }
    }

    private static int TryGetExitCode(Process proc)
    {
        try
        {
            return proc.ExitCode;
        }
        catch
        {
            return -1;
        }
    }

    private static string QuoteArg(string value) => $"\"{value}\"";

    public void Stop()
    {
        _monitorCts?.Cancel();
        _monitorCts = null;
        _restartTimer?.Dispose();
        _restartTimer = null;
        StopProcess();
    }

    public async Task RestartAsync(CancellationToken ct = default)
    {
        StopProcess();
        await Task.Delay(500, ct).ConfigureAwait(false);
        await StartAsync(ct).ConfigureAwait(false);
    }

    private void StopProcess()
    {
        _stopping = true;
        try
        {
            Process? proc;
            lock (_gate)
            {
                proc = _process;
            }
            if (proc is not null)
            {
                try
                {
                    if (!proc.HasExited)
                    {
                        proc.Kill(entireProcessTree: false);
                        if (!proc.WaitForExit(2000))
                        {
                            proc.Kill(entireProcessTree: true);
                            proc.WaitForExit(1000);
                        }
                    }
                }
                catch (Exception error)
                {
                    CTLog.Helper.Warn($"终止辅助进程失败: {error.CtUserMessage()}");
                }
                proc.Dispose();
            }
            Cleanup();
        }
        finally
        {
            _stopping = false;
        }
        _restartTimer?.Dispose();
        _restartTimer = null;
        SetState(new HelperState.Stopped());
        CTLog.Helper.Info("辅助进程已停止");
    }

    private void Cleanup()
    {
        lock (_gate)
        {
            _process = null;
        }
        _port = 0;
        _authToken = "";
    }

    public static string PercentEncodedQuery(IReadOnlyDictionary<string, string> query)
    {
        return string.Join("&", query
            .OrderBy(pair => pair.Key, StringComparer.Ordinal)
            .Select(pair => $"{Uri.EscapeDataString(pair.Key)}={Uri.EscapeDataString(pair.Value)}"));
    }

    public Uri MakeURL(string path, IReadOnlyDictionary<string, string>? query = null)
    {
        if (State is not HelperState.Running running) throw MusicException.HelperProcessUnavailable();
        var url = $"http://127.0.0.1:{running.Port}{path}";
        if (query is { Count: > 0 })
        {
            url += "?" + PercentEncodedQuery(query);
        }
        return new Uri(url);
    }

    public void ApplyAuth(HttpRequestMessage request)
    {
        request.Headers.TryAddWithoutValidation("X-CT-Token", _authToken);
    }

    private async Task WaitForHealthyAsync(TimeSpan timeout, CancellationToken ct)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            ct.ThrowIfCancellationRequested();
            if (await CheckHealthAsync().ConfigureAwait(false)) return;
            await Task.Delay(300, ct).ConfigureAwait(false);
        }
        throw MusicException.HelperProcessTimeout();
    }

    private async Task<bool> CheckHealthAsync()
    {
        var port = _port;
        if (port <= 0) return false;
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, $"http://127.0.0.1:{port}/ct_health");
            request.Headers.TryAddWithoutValidation("X-CT-Token", _authToken);
            using var response = await _healthClient.SendAsync(request).ConfigureAwait(false);
            return (int)response.StatusCode == 200;
        }
        catch
        {
            return false;
        }
    }

    private void StartHealthMonitoring()
    {
        _monitorCts?.Cancel();
        var cts = new CancellationTokenSource();
        _monitorCts = cts;
        _ = Task.Run(async () =>
        {
            while (!cts.IsCancellationRequested)
            {
                try
                {
                    await Task.Delay(TimeSpan.FromSeconds(15), cts.Token).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    return;
                }
                var processAlive = IsProcessAlive();
                var healthy = await CheckHealthAsync().ConfigureAwait(false);
                if (!processAlive || !healthy)
                {
                    CTLog.Helper.Warn($"辅助进程异常 (alive={processAlive}, healthy={healthy})，尝试重启");
                    SetState(new HelperState.Failed("辅助进程异常退出"));
                    RestartFromMonitor();
                    return;
                }
            }
        });
    }

    private bool IsProcessAlive()
    {
        lock (_gate)
        {
            try
            {
                return _process is { HasExited: false };
            }
            catch
            {
                return false;
            }
        }
    }

    private void RestartFromMonitor()
    {
        _monitorCts?.Cancel();
        _monitorCts = null;
        StopProcess();
        ScheduleRestart(TimeSpan.FromMilliseconds(500), resumeMonitoringOnFailure: true);
    }

    private void ScheduleRestart(TimeSpan delay, bool resumeMonitoringOnFailure = false)
    {
        _restartTimer?.Dispose();
        _restartTimer = new Timer(_ =>
        {
            _restartTimer?.Dispose();
            _restartTimer = null;
            _ = Task.Run(async () =>
            {
                try
                {
                    await StartAsync().ConfigureAwait(false);
                }
                catch (Exception error)
                {
                    CTLog.Helper.Error($"健康检查自动重启失败: {error.CtUserMessage()}");
                    SetState(new HelperState.Failed("辅助进程异常退出"));
                    if (resumeMonitoringOnFailure) StartHealthMonitoring();
                }
            });
        }, null, delay, Timeout.InfiniteTimeSpan);
    }

    private static void RotateLogIfNeeded(string path, long maxBytes = 5 * 1024 * 1024)
    {
        try
        {
            var info = new FileInfo(path);
            if (!info.Exists || info.Length <= maxBytes) return;
            var rotated = path + ".1";
            if (File.Exists(rotated)) File.Delete(rotated);
            File.Move(path, rotated);
        }
        catch
        {
        }
    }

    public void Dispose()
    {
        Stop();
        _healthClient.Dispose();
    }
}
