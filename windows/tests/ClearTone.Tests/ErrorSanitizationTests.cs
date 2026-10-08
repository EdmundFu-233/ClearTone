using System.Net.Http;
using System.Net.Sockets;
using ClearTone.Core.Logging;
using ClearTone.Core.Models;
using Xunit;

namespace ClearTone.Tests;

public class ErrorSanitizationTests
{
    [Fact]
    public void TestJSONShapedCredentialsAreRedacted()
    {
        var output = CTLog.Sanitize("{\"MUSIC_U\":\"abc123def\",\"MUSIC_A\":\"99887766\"}");
        Assert.DoesNotContain("abc123def", output);
        Assert.DoesNotContain("99887766", output);
        Assert.Contains("MUSIC_U", output);
    }

    [Fact]
    public void TestQueryShapedCredentialsAreRedacted()
    {
        var output = CTLog.Sanitize("MUSIC_U=1a2b3c4d5e&other=keep");
        Assert.DoesNotContain("1a2b3c4d5e", output);
        Assert.Contains("other=keep", output);
    }

    [Fact]
    public void TestCookieHeaderIsRedacted()
    {
        var output = CTLog.Sanitize("Cookie: MUSIC_U=xyz; __csrf=qqq; MTgI4.json");
        Assert.DoesNotContain("xyz", output);
        Assert.DoesNotContain("qqq", output);
        Assert.Contains("MTgI4.json", output);
    }

    [Fact]
    public void TestBearerTokenValueWithSpacesIsFullyRedacted()
    {
        const string jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abcdef";
        var output = CTLog.Sanitize($"authorization=Bearer {jwt}");
        Assert.DoesNotContain(jwt, output);
        Assert.DoesNotContain("Bearer eyJ", output);
    }

    [Fact]
    public void TestPreviouslyMissedKeysAreCovered()
    {
        foreach (var key in new[] { "MUSIC_A", "MUSIC_R", "__remember_me", "NMTID", "password", "secret" })
        {
            var output = CTLog.Sanitize($"{key}=s3cr3t-value");
            Assert.DoesNotContain("s3cr3t-value", output);
        }
    }

    [Fact]
    public void TestNormalMessagesAndLookalikeWordsAreUntouched()
    {
        const string message = "加载歌单失败：接口错误 (400)：参数不对";
        Assert.Equal(message, CTLog.Sanitize(message));

        foreach (var lookalike in new[] { "cacheKey=abc", "monkey=def", "hotkey=1", "keyboard=zzz" })
        {
            Assert.Equal(lookalike, CTLog.Sanitize(lookalike));
        }
    }

    [Fact]
    public void TestNetworkErrorsMapToStableChineseMessages()
    {
        Assert.Equal(
            MusicErrorKind.NetworkUnavailable,
            MusicException.From(new HttpRequestException(HttpRequestError.NameResolutionError)).Kind);
        Assert.Equal(
            MusicErrorKind.NetworkUnavailable,
            MusicException.From(new SocketException((int)SocketError.NetworkDown)).Kind);
        Assert.Equal(
            MusicErrorKind.HelperProcessTimeout,
            MusicException.From(new TimeoutException()).Kind);
    }

    [Fact(Skip = "Apple-only: URLError/helperBacked platform split does not exist on Windows; HttpRequestException/SocketException mapping is covered instead")]
    public void TestURLErrorMappingDistinguishesHelperBackedPlatforms()
    {
    }

    [Fact]
    public void TestCancellationIsNotSwallowedIntoUnknownError()
    {
        Assert.Equal(MusicErrorKind.Cancelled, MusicException.From(new OperationCanceledException()).Kind);
    }

    [Fact]
    public void TestMusicErrorPassesThrough()
    {
        Assert.Equal(MusicException.RateLimited(), MusicException.From(MusicException.RateLimited()));
        Assert.Equal(
            MusicException.ApiError(400, "x"),
            MusicException.From(MusicException.ApiError(400, "x")));
    }

    [Fact]
    public void TestUnknownErrorDoesNotLeakLocalizedDescription()
    {
        var mapped = MusicException.From(new InvalidOperationException("The operation couldn't be completed."));
        Assert.Equal(MusicErrorKind.Unknown, mapped.Kind);
        Assert.DoesNotContain("couldn", mapped.Message);
    }

    [Fact]
    public void TestRetryableClassification()
    {
        Assert.True(MusicException.NetworkUnavailable().IsRetryable);
        Assert.True(MusicException.RateLimited().IsRetryable);
        Assert.True(MusicException.ApiError(502, "").IsRetryable);
        Assert.True(MusicException.ApiError(429, "").IsRetryable);
        Assert.False(MusicException.ApiError(400, "").IsRetryable);
        Assert.False(MusicException.NotLoggedIn().IsRetryable);
        Assert.False(MusicException.Cancelled().IsRetryable);
    }

    [Fact]
    public void TestUserFacingMessageIsSanitized()
    {
        var error = MusicException.ApiError(400, "invalid cookie {\"MUSIC_U\":\"leaked-token\"}");
        Assert.DoesNotContain("leaked-token", error.UserFacingMessage);
    }

    [Fact]
    public void TestErrorProtocolUserMessagePrefersMusicErrorText()
    {
        Exception error = MusicException.NotLoggedIn();
        Assert.Equal(MusicException.NotLoggedIn().Message, error.CtUserMessage());
        Assert.False(string.IsNullOrEmpty(error.CtUserMessage()));
    }

    [Fact]
    public void TestRequestTimeoutIsNeutralAndRetryable()
    {
        Assert.Equal("请求超时，请稍后重试", MusicException.RequestTimeout().Message);
        Assert.True(MusicException.RequestTimeout().IsRetryable);
        Assert.Equal("请求超时，请稍后重试", MusicException.RequestTimeout().UserFacingMessage);
    }
}
