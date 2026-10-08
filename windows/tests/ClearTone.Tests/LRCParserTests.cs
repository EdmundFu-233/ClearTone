using ClearTone.Core.Models;
using ClearTone.Providers.Netease;
using Xunit;

namespace ClearTone.Tests;

public class LRCParserTests
{
    [Fact]
    public void TestBasicLRC()
    {
        const string lrc = "[00:01.00]第一行\n[00:05.50]第二行\n[00:10.00]第三行";
        var lines = LRCParser.Parse(lrc);
        Assert.Equal(3, lines.Count);
        Assert.Equal(1.0, lines[0].Time, 3);
        Assert.Equal(5.5, lines[1].Time, 3);
        Assert.Equal("第一行", lines[0].Text);
    }

    [Fact]
    public void TestDuplicateTimestamps()
    {
        const string lrc = "[00:01.00]同一时间\n[00:01.00]重复时间\n[00:02.00]下一行";
        var lines = LRCParser.Parse(lrc);
        Assert.Equal(2, lines.Count);
        Assert.Equal("重复时间", lines[0].Text);
        Assert.Equal("下一行", lines[1].Text);
    }

    [Fact]
    public void TestMalformedLines()
    {
        const string lrc = "[invalid]无效行\n[00:01.00]正常行\n[]\n[00:02.00]";
        var lines = LRCParser.Parse(lrc);
        Assert.Equal(2, lines.Count);
    }

    [Fact]
    public void TestTranslationMerge()
    {
        const string lrc = "[00:01.00]你好";
        const string trans = "[00:01.00]Hello";
        var lines = LRCParser.Parse(lrc, trans);
        Assert.Equal(1, lines.Count);
        Assert.Equal("Hello", lines[0].Translation);
    }

    [Fact]
    public void TestBinarySearch()
    {
        var lines = new List<LyricLine>
        {
            new() { Time = 1.0, Text = "a" },
            new() { Time = 5.0, Text = "b" },
            new() { Time = 10.0, Text = "c" },
            new() { Time = 20.0, Text = "d" },
        };

        Assert.Null(LRCParser.CurrentLineIndex(lines, 0));
        Assert.Equal((int?)0, LRCParser.CurrentLineIndex(lines, 1.0));
        Assert.Equal((int?)0, LRCParser.CurrentLineIndex(lines, 3.0));
        Assert.Equal((int?)1, LRCParser.CurrentLineIndex(lines, 5.0));
        Assert.Equal((int?)2, LRCParser.CurrentLineIndex(lines, 15.0));
        Assert.Equal((int?)3, LRCParser.CurrentLineIndex(lines, 25.0));
    }

    [Fact]
    public void TestBinarySearchWithOffset()
    {
        var lines = new List<LyricLine>
        {
            new() { Time = 5.0, Text = "a" },
            new() { Time = 10.0, Text = "b" },
        };

        Assert.Equal((int?)0, LRCParser.CurrentLineIndex(lines, 7.0, -2.0));
        Assert.Equal((int?)0, LRCParser.CurrentLineIndex(lines, 3.0, 2.0));
    }

    [Fact]
    public void TestYRC()
    {
        const string yrc = "[0,1000]我(0,200,0)们(200,300,0)";
        var lines = LRCParser.ParseYRC(yrc);
        Assert.Equal(1, lines.Count);
        Assert.Equal(2, lines[0].Words!.Count);
        Assert.Equal("我们", lines[0].Text);
    }

    [Fact]
    public void TestYRCMergesRomanization()
    {
        const string yrc = "[0,1000]我(0,200,0)们(200,300,0)";
        const string trans = "[00:00.00]We";
        const string roma = "[00:00.00]wo men";
        var lines = LRCParser.ParseYRC(yrc, trans, roma);
        Assert.Equal(1, lines.Count);
        Assert.Equal("We", lines[0].Translation);
        Assert.Equal("wo men", lines[0].Romanization);
    }
}
