using ClearTone.Core.Security;
using ClearTone.Providers.Netease;
using Xunit;

namespace ClearTone.Tests;

public class NeteaseCookieNormalizerTests
{
    private static readonly string RealWorldSample = string.Join("; ", new[]
    {
        "MUSIC_R_T=1439570921116",
        "Max-Age=2147483647",
        "Expires=Mon, 18 Oct 2094 00:19:44 GMT",
        "Path=/openapi/clientlog",
        "MUSIC_A_T=1439570921113",
        "__csrf=b3e16df935cbc74e23017ffc0e6ea12c",
        "MUSIC_U=005BA38F62CFF322CC7F662320D503E7CE5BBC41",
        "MUSIC_SNS=",
        "Max-Age=0",
    });

    [Fact]
    public void TestDropsCookieAttributes()
    {
        var result = NeteaseCookieNormalizer.Normalize(RealWorldSample);
        foreach (var attribute in new[] { "Expires=", "Max-Age=", "Path=" })
        {
            Assert.DoesNotContain(attribute, result);
        }
    }

    [Fact]
    public void TestKeepsRealCredentials()
    {
        var result = NeteaseCookieNormalizer.Normalize(RealWorldSample);
        Assert.Contains("__csrf=b3e16df935cbc74e23017ffc0e6ea12c", result);
        Assert.Contains("MUSIC_U=005BA38F62CFF322CC7F662320D503E7CE5BBC41", result);
    }

    [Fact]
    public void TestDropsEmptyValues()
    {
        var result = NeteaseCookieNormalizer.Normalize(RealWorldSample);
        Assert.DoesNotContain("MUSIC_SNS", result);
    }

    [Fact]
    public void TestDeduplicatesRepeatedNames()
    {
        const string raw = "MUSIC_R_U=AAAA; MUSIC_U=BBBB; Path=/x; MUSIC_R_U=CCCC";
        var result = NeteaseCookieNormalizer.Normalize(raw);
        Assert.Equal("MUSIC_R_U=AAAA; MUSIC_U=BBBB", result);
    }

    [Fact]
    public void TestRealWorldCookieShrinksToSixEntries()
    {
        var raw = string.Join("; ", new[]
        {
            "MUSIC_R_T=1", "Max-Age=2147483647", "Expires=Mon, 18 Oct 2094 00:19:44 GMT", "Path=/openapi/clientlog",
            "MUSIC_A_T=2", "Max-Age=2147483647", "Expires=Mon, 18 Oct 2094 00:19:44 GMT", "Path=/eapi/clientlog",
            "MUSIC_R_U=R", "Max-Age=15552000", "Expires=Sun, 28 Mar 2027 21:05:37 GMT", "Path=/eapi/login/token/refresh",
            "__csrf=CSRF", "Max-Age=1296010", "Expires=Wed, 14 Oct 2026 21:05:47 GMT", "Path=/",
            "MUSIC_R_U=R", "Max-Age=15552000", "Expires=Sun, 28 Mar 2027 21:05:37 GMT", "Path=/api/login/token/refresh",
            "MUSIC_U=U", "Max-Age=15552000", "Expires=Sun, 28 Mar 2027 21:05:37 GMT", "Path=/",
            "MUSIC_SNS=", "Max-Age=0", "Expires=Tue, 29 Sep 2026 21:05:37 GMT", "Path=/",
        });
        var result = NeteaseCookieNormalizer.Normalize(raw);
        var pairs = result.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        Assert.Equal(5, pairs.Length);
        Assert.Equal("MUSIC_R_T=1; MUSIC_A_T=2; MUSIC_R_U=R; __csrf=CSRF; MUSIC_U=U", result);
    }

    [Fact]
    public void TestValueContainingEqualsIsPreserved()
    {
        Assert.Equal(
            "TOKEN=a=b=c; X=1",
            NeteaseCookieNormalizer.Normalize("TOKEN=a=b=c; X=1"));
    }

    [Fact]
    public void TestAlreadyNormalizedInputIsUnchanged()
    {
        const string clean = "MUSIC_U=U; __csrf=C";
        Assert.Equal(clean, NeteaseCookieNormalizer.Normalize(clean));
    }

    [Fact]
    public void TestNormalizeIsIdempotent()
    {
        var once = NeteaseCookieNormalizer.Normalize(RealWorldSample);
        var twice = NeteaseCookieNormalizer.Normalize(once);
        Assert.Equal(once, twice);
    }

    [Fact]
    public void TestEmptyAndGarbageInputProduceEmptyString()
    {
        Assert.Equal("", NeteaseCookieNormalizer.Normalize(""));
        Assert.Equal("", NeteaseCookieNormalizer.Normalize("   "));
        Assert.Equal("", NeteaseCookieNormalizer.Normalize(";;;"));
        Assert.Equal("", NeteaseCookieNormalizer.Normalize("no-equals-sign"));
    }

    [Fact]
    public void TestAttributeNamesAreCaseInsensitive()
    {
        var result = NeteaseCookieNormalizer.Normalize("A=1; expires=x; MAX-AGE=1; Path=/; b=2");
        Assert.Equal("A=1; b=2", result);
    }

    [Fact]
    public void TestLoadLoginCookieDoesNotRecurseInForever()
    {
        var cookie = NeteaseProvider.LoadLoginCookie();
        if (cookie is not null)
        {
            Assert.DoesNotContain("Expires=", cookie);
            Assert.DoesNotContain("Path=", cookie);
            Assert.DoesNotContain("Max-Age=", cookie);
        }
    }
}
