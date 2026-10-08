using System.Net.Http;
using System.Net.Sockets;
using ClearTone.Core.Logging;

namespace ClearTone.Core.Models;

public enum MusicErrorKind
{
    NotLoggedIn,
    SessionExpired,
    NetworkUnavailable,
    RateLimited,
    SongUnavailable,
    NoPlayableURL,
    ApiError,
    HelperProcessUnavailable,
    HelperProcessTimeout,
    HelperAuthFailed,
    RequestTimeout,
    InvalidResponse,
    Cancelled,
    UnsupportedFormat,
    FileNotFound,
    Unknown,
}

public sealed class MusicException : Exception, IEquatable<MusicException>
{
    public MusicErrorKind Kind { get; }
    public int Code { get; }
    private readonly string? _detail;

    public MusicException(MusicErrorKind kind, string? detail = null, int code = 0)
        : base(BuildMessage(kind, detail, code))
    {
        Kind = kind;
        Code = code;
        _detail = detail;
    }

    public bool IsHelperBacked => true;

    public string UserFacingMessage => CTLog.Sanitize(Message);

    public bool IsRetryable => Kind switch
    {
        MusicErrorKind.NetworkUnavailable => true,
        MusicErrorKind.RateLimited => true,
        MusicErrorKind.HelperProcessTimeout => true,
        MusicErrorKind.HelperProcessUnavailable => true,
        MusicErrorKind.RequestTimeout => true,
        MusicErrorKind.ApiError => Code == 429 || (Code >= 500 && Code <= 599),
        _ => false,
    };

    public static MusicException NotLoggedIn() => new(MusicErrorKind.NotLoggedIn);
    public static MusicException SessionExpired() => new(MusicErrorKind.SessionExpired);
    public static MusicException NetworkUnavailable() => new(MusicErrorKind.NetworkUnavailable);
    public static MusicException RateLimited() => new(MusicErrorKind.RateLimited);
    public static MusicException NoPlayableURL() => new(MusicErrorKind.NoPlayableURL);
    public static MusicException HelperProcessUnavailable() => new(MusicErrorKind.HelperProcessUnavailable);
    public static MusicException HelperProcessTimeout() => new(MusicErrorKind.HelperProcessTimeout);
    public static MusicException HelperAuthFailed() => new(MusicErrorKind.HelperAuthFailed);
    public static MusicException RequestTimeout() => new(MusicErrorKind.RequestTimeout);
    public static MusicException InvalidResponse() => new(MusicErrorKind.InvalidResponse);
    public static MusicException Cancelled() => new(MusicErrorKind.Cancelled);
    public static MusicException FileNotFound() => new(MusicErrorKind.FileNotFound);
    public static MusicException SongUnavailable(string reason) => new(MusicErrorKind.SongUnavailable, reason);
    public static MusicException ApiError(int code, string message) => new(MusicErrorKind.ApiError, message, code);
    public static MusicException UnsupportedFormat(string format) => new(MusicErrorKind.UnsupportedFormat, format);
    public static MusicException Unknown(string detail) => new(MusicErrorKind.Unknown, detail);

    public static MusicException From(Exception error)
    {
        if (error is MusicException music) return music;

        if (error is OperationCanceledException)
        {
            if (error is TaskCanceledException tce)
            {
                if (tce.InnerException is TimeoutException) return HelperProcessTimeout();
                if (!tce.CancellationToken.IsCancellationRequested) return HelperProcessTimeout();
            }
            return Cancelled();
        }

        if (error is TimeoutException) return HelperProcessTimeout();

        if (error is HttpRequestException http)
        {
            return http.HttpRequestError switch
            {
                HttpRequestError.ConnectionError => HelperProcessUnavailable(),
                HttpRequestError.NameResolutionError => NetworkUnavailable(),
                HttpRequestError.SecureConnectionError => NetworkUnavailable(),
                HttpRequestError.HttpProtocolError => InvalidResponse(),
                HttpRequestError.ProxyTunnelError => NetworkUnavailable(),
                _ => Unknown($"{error.GetType().Name}"),
            };
        }

        if (error is SocketException socket)
        {
            return socket.SocketErrorCode switch
            {
                SocketError.ConnectionRefused => HelperProcessUnavailable(),
                SocketError.NetworkDown or SocketError.NetworkUnreachable or SocketError.HostUnreachable => NetworkUnavailable(),
                SocketError.TimedOut => HelperProcessTimeout(),
                _ => Unknown($"{error.GetType().Name}"),
            };
        }

        if (error is FileNotFoundException or DirectoryNotFoundException) return FileNotFound();

        if (error is System.Security.SecurityException) return Unknown(error.GetType().Name);

        return Unknown($"{error.GetType().Name}");
    }

    private static string BuildMessage(MusicErrorKind kind, string? detail, int code) => kind switch
    {
        MusicErrorKind.NotLoggedIn => "尚未登录，请先登录网易云账号",
        MusicErrorKind.SessionExpired => "登录状态已过期，请重新登录",
        MusicErrorKind.NetworkUnavailable => "网络不可用，请检查网络连接",
        MusicErrorKind.RateLimited => "请求过于频繁，请稍后再试",
        MusicErrorKind.SongUnavailable => $"歌曲不可用：{detail}",
        MusicErrorKind.NoPlayableURL => "无法获取播放地址，可能没有播放权限",
        MusicErrorKind.ApiError => $"接口错误 ({code})：{detail}",
        MusicErrorKind.HelperProcessUnavailable => "本地服务不可用，请尝试重启应用",
        MusicErrorKind.HelperProcessTimeout => "本地服务响应超时",
        MusicErrorKind.HelperAuthFailed => "本地服务鉴权失败",
        MusicErrorKind.RequestTimeout => "请求超时，请稍后重试",
        MusicErrorKind.InvalidResponse => "服务器返回数据格式异常",
        MusicErrorKind.Cancelled => "操作已取消",
        MusicErrorKind.UnsupportedFormat => $"不支持的音频格式：{detail}",
        MusicErrorKind.FileNotFound => "文件不存在",
        _ => detail ?? "未知错误",
    };

    public bool Equals(MusicException? other) =>
        other is not null && Kind == other.Kind && Code == other.Code && Message == other.Message;

    public override bool Equals(object? obj) => Equals(obj as MusicException);

    public override int GetHashCode() => HashCode.Combine(Kind, Code, Message);
}

public static class ErrorExtensions
{
    public static string CtUserMessage(this Exception error) =>
        error is MusicException music ? music.UserFacingMessage : CTLog.Sanitize(error.Message);
}
