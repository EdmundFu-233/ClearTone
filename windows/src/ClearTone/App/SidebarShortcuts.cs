namespace ClearTone.Shell;

public static class SidebarShortcuts
{
    public static readonly char[] DigitKeys = { '1', '2', '3', '4', '5', '6', '7', '8', '9', '0' };

    public static char? KeyForIndex(int index) =>
        index >= 0 && index < DigitKeys.Length ? DigitKeys[index] : null;
}
