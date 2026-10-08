using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using ClearTone.DesignSystem;

namespace ClearTone.Features.Shared;

public sealed class PlaceholderView : UserControl
{
    public PlaceholderView(string title, string? subtitle = null)
    {
        Content = new StackPanel
        {
            Spacing = CTSpacing.Sm,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Children =
            {
                new TextBlock
                {
                    Text = title,
                    FontSize = 20,
                    FontWeight = FontWeight.SemiBold,
                    HorizontalAlignment = HorizontalAlignment.Center,
                    Foreground = CTColors.TextPrimaryBrush,
                },
                new TextBlock
                {
                    Text = subtitle ?? "正在开发中",
                    HorizontalAlignment = HorizontalAlignment.Center,
                    Foreground = CTColors.TextSecondaryBrush,
                },
            },
        };
    }
}
