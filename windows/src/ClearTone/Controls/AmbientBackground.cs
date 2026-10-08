using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Threading;
using ClearTone.DesignSystem;

namespace ClearTone.Controls;

public class AmbientBackground : Control
{
    private readonly DispatcherTimer _timer;
    private double _t;

    private static readonly Color Accent = Color.Parse("#EF6A67");
    private static readonly Color Violet = Color.Parse("#7A6AF0");
    private static readonly Color Teal = Color.Parse("#3FB6C9");

    public AmbientBackground()
    {
        ClipToBounds = true;
        _timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(40) };
        _timer.Tick += (_, _) =>
        {
            _t += 0.016;
            InvalidateVisual();
        };
        PropertyChanged += (_, args) =>
        {
            if (args.Property != IsVisibleProperty) return;
            if (IsVisible) _timer.Start();
            else _timer.Stop();
        };
    }

    public override void Render(DrawingContext context)
    {
        var bounds = Bounds;
        if (bounds.Width <= 1 || bounds.Height <= 1) return;
        context.FillRectangle(new SolidColorBrush(CTColors.ImmersiveBase), new Rect(bounds.Size));

        var w = bounds.Width;
        var h = bounds.Height;
        DrawBlob(context, Accent, w * (0.30 + 0.08 * Math.Sin(_t * 0.53)), h * (0.28 + 0.06 * Math.Cos(_t * 0.61)), w * 0.42);
        DrawBlob(context, Violet, w * (0.72 + 0.07 * Math.Cos(_t * 0.47 + 1.7)), h * (0.36 + 0.07 * Math.Sin(_t * 0.71 + 0.9)), w * 0.38);
        DrawBlob(context, Teal, w * (0.52 + 0.09 * Math.Sin(_t * 0.39 + 3.1)), h * (0.74 + 0.06 * Math.Cos(_t * 0.55 + 2.2)), w * 0.36);
    }

    private static void DrawBlob(DrawingContext context, Color color, double cx, double cy, double radius)
    {
        var soft = new RadialGradientBrush
        {
            Center = new RelativePoint(0.5, 0.5, RelativeUnit.Relative),
            GradientOrigin = new RelativePoint(0.5, 0.5, RelativeUnit.Relative),
            RadiusX = new RelativeScalar(0.5, RelativeUnit.Relative),
            RadiusY = new RelativeScalar(0.5, RelativeUnit.Relative),
            GradientStops =
            {
                new GradientStop(Color.FromArgb(56, color.R, color.G, color.B), 0),
                new GradientStop(Color.FromArgb(0, color.R, color.G, color.B), 1),
            },
        };
        context.DrawEllipse(soft, null, new Point(cx, cy), radius, radius);
        var core = new RadialGradientBrush
        {
            Center = new RelativePoint(0.5, 0.5, RelativeUnit.Relative),
            GradientOrigin = new RelativePoint(0.5, 0.5, RelativeUnit.Relative),
            RadiusX = new RelativeScalar(0.5, RelativeUnit.Relative),
            RadiusY = new RelativeScalar(0.5, RelativeUnit.Relative),
            GradientStops =
            {
                new GradientStop(Color.FromArgb(36, color.R, color.G, color.B), 0),
                new GradientStop(Color.FromArgb(0, color.R, color.G, color.B), 1),
            },
        };
        context.DrawEllipse(core, null, new Point(cx, cy), radius * 0.55, radius * 0.55);
    }
}
