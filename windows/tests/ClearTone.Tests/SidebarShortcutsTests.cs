using ClearTone.Shell;
using Xunit;

namespace ClearTone.Tests;

public class SidebarShortcutsTests
{
    [Fact]
    public void FirstNinePagesUseOneThroughNine()
    {
        for (var index = 0; index < 9; index++)
        {
            Assert.Equal((char)('1' + index), SidebarShortcuts.KeyForIndex(index)!.Value);
        }
    }

    [Fact]
    public void TenthPageReusesZeroInsteadOfTen()
    {
        Assert.Equal('0', SidebarShortcuts.KeyForIndex(9)!.Value);
    }

    [Fact]
    public void EverySidebarPageHasAKey()
    {
        var pages = PageExtensions.SidebarPages;
        Assert.True(pages.Length >= 10);
        for (var index = 0; index < pages.Length; index++)
        {
            Assert.True(SidebarShortcuts.KeyForIndex(index).HasValue);
        }
    }

    [Fact]
    public void OutOfRangeIndexReturnsNull()
    {
        Assert.Null(SidebarShortcuts.KeyForIndex(-1));
        Assert.Null(SidebarShortcuts.KeyForIndex(10));
        Assert.Null(SidebarShortcuts.KeyForIndex(999));
    }

    [Fact]
    public void DigitKeysAreUniqueSingleCharacters()
    {
        Assert.Equal(10, SidebarShortcuts.DigitKeys.Length);
        Assert.Equal(
            SidebarShortcuts.DigitKeys.Length,
            SidebarShortcuts.DigitKeys.Distinct().Count());
        Assert.All(SidebarShortcuts.DigitKeys, key => Assert.True(char.IsAsciiDigit(key)));
    }
}
