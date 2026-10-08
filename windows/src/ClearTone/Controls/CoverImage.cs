using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using ClearTone.DesignSystem;

namespace ClearTone.Controls;

public class CoverImage : Border
{
    public static readonly StyledProperty<string?> CoverUrlProperty =
        AvaloniaProperty.Register<CoverImage, string?>(nameof(CoverUrl));

    public static readonly StyledProperty<int> DecodeWidthProperty =
        AvaloniaProperty.Register<CoverImage, int>(nameof(DecodeWidth), 0);

    public static readonly StyledProperty<Stretch> StretchProperty =
        AvaloniaProperty.Register<CoverImage, Stretch>(nameof(Stretch), Stretch.UniformToFill);

    private readonly Image _image;
    private CancellationTokenSource? _cts;

    public CoverImage()
    {
        ClipToBounds = true;
        _image = new Image { Stretch = Stretch.UniformToFill };
        Child = _image;
        Background = new SolidColorBrush(Color.Parse("#33808080"));
    }

    public string? CoverUrl
    {
        get => GetValue(CoverUrlProperty);
        set => SetValue(CoverUrlProperty, value);
    }

    public int DecodeWidth
    {
        get => GetValue(DecodeWidthProperty);
        set => SetValue(DecodeWidthProperty, value);
    }

    public Stretch Stretch
    {
        get => GetValue(StretchProperty);
        set
        {
            SetValue(StretchProperty, value);
            _image.Stretch = value;
        }
    }

    public Bitmap? CurrentBitmap => _image.Source as Bitmap;

    protected override void OnPropertyChanged(AvaloniaPropertyChangedEventArgs change)
    {
        base.OnPropertyChanged(change);
        if (change.Property == CoverUrlProperty)
        {
            Refresh();
        }
    }

    private void Refresh()
    {
        _cts?.Cancel();
        var url = CoverUrl;
        var width = DecodeWidth;
        if (string.IsNullOrEmpty(url))
        {
            _image.Source = null;
            return;
        }
        var cts = new CancellationTokenSource();
        _cts = cts;
        var token = cts.Token;
        _ = LoadAsync(url, width, token);
    }

    private async Task LoadAsync(string url, int width, CancellationToken ct)
    {
        var bitmap = await CoverImageLoader.Shared.LoadAsync(url, width, ct).ConfigureAwait(true);
        if (ct.IsCancellationRequested) return;
        if (CoverUrl != url) return;
        _image.Source = bitmap;
    }
}
