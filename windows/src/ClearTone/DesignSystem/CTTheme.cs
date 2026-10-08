using Avalonia;
using Avalonia.Media;
using Avalonia.Styling;

namespace ClearTone.DesignSystem;

public static class CTColors
{
    public static readonly Color ImmersiveBase = Color.FromRgb(0x12, 0x12, 0x17);

    public static readonly Color DarkBackground = Color.Parse("#111216");
    public static readonly Color DarkPanel = Color.Parse("#191B21");
    public static readonly Color DarkOverlay = Color.Parse("#22252D");
    public static readonly Color DarkTextPrimary = Color.Parse("#F4F4F6");
    public static readonly Color DarkTextSecondary = Color.Parse("#A6ABB7");
    public static readonly Color DarkAccent = Color.Parse("#EF6A67");

    public static readonly Color LightBackground = Color.Parse("#F5F4F1");
    public static readonly Color LightPanel = Color.Parse("#FFFFFF");
    public static readonly Color LightOverlay = Color.Parse("#EEEEEC");
    public static readonly Color LightTextPrimary = Color.Parse("#20232A");
    public static readonly Color LightTextSecondary = Color.Parse("#626976");
    public static readonly Color LightAccent = Color.Parse("#C84045");

    public static bool IsDark => Application.Current?.ActualThemeVariant == ThemeVariant.Dark;

    public static Color Background => IsDark ? DarkBackground : LightBackground;
    public static Color Panel => IsDark ? DarkPanel : LightPanel;
    public static Color Overlay => IsDark ? DarkOverlay : LightOverlay;
    public static Color TextPrimary => IsDark ? DarkTextPrimary : LightTextPrimary;
    public static Color TextSecondary => IsDark ? DarkTextSecondary : LightTextSecondary;
    public static Color Accent => IsDark ? DarkAccent : LightAccent;

    public static IBrush BackgroundBrush => new SolidColorBrush(Background);
    public static IBrush PanelBrush => new SolidColorBrush(Panel);
    public static IBrush OverlayBrush => new SolidColorBrush(Overlay);
    public static IBrush TextPrimaryBrush => new SolidColorBrush(TextPrimary);
    public static IBrush TextSecondaryBrush => new SolidColorBrush(TextSecondary);
    public static IBrush AccentBrush => new SolidColorBrush(Accent);
}

public static class CTSpacing
{
    public const double Xs = 4;
    public const double Sm = 8;
    public const double Md = 12;
    public const double Lg = 16;
    public const double Xl = 24;
    public const double Xxl = 32;
}

public static class CTRadius
{
    public const double Small = 6;
    public const double Medium = 10;
    public const double Large = 14;
}

public static class CTTypography
{
    public const double PageTitle = 30;
    public const double SectionTitle = 20;
    public const double Body = 14;
    public const double Caption = 12;
}

public static class CTFormatting
{
    public static string Time(double seconds)
    {
        if (!double.IsFinite(seconds) || seconds < 0) seconds = 0;
        var total = (int)Math.Floor(seconds);
        var minutes = total / 60;
        var secs = total % 60;
        if (minutes >= 60)
        {
            var hours = minutes / 60;
            minutes %= 60;
            return $"{hours}:{minutes:D2}:{secs:D2}";
        }
        return $"{minutes}:{secs:D2}";
    }

    public static string Count(int value)
    {
        if (value >= 100_000_000) return $"{value / 100_000_000.0:0.#}亿";
        if (value >= 10_000) return $"{value / 10_000.0:0.#}万";
        return value.ToString();
    }
}
