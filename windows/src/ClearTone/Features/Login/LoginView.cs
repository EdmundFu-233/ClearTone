using System.ComponentModel;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using ClearTone.Core.Models;
using ClearTone.Core.Security;
using ClearTone.DesignSystem;
using ClearTone.Features.Shared;
using ClearTone.Providers.Netease;
using ClearTone.Shell;

namespace ClearTone.Features.Login;

[OverlayView(OverlayKind.Login)]
public sealed class LoginView : UserControl
{
    private static AppState App => AppState.Shared;
    private static NeteaseProvider Provider => NeteaseProvider.Shared;

    private static readonly FontFamily IconFont = new("Segoe MDL2 Assets, Segoe Fluent Icons");

    private readonly Image _qrImage = new()
    {
        Width = 220,
        Height = 220,
        Stretch = Stretch.Uniform,
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
    };

    private readonly ProgressBar _spinner = new()
    {
        IsIndeterminate = true,
        Width = 150,
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
    };

    private readonly TextBlock _statusText = new()
    {
        Text = L10n.Login.WaitingScan,
        Classes = { "secondary" },
        HorizontalAlignment = HorizontalAlignment.Center,
        TextAlignment = TextAlignment.Center,
    };

    private readonly TextBlock _errorText = new()
    {
        Foreground = CTColors.AccentBrush,
        TextWrapping = TextWrapping.Wrap,
        TextAlignment = TextAlignment.Center,
        HorizontalAlignment = HorizontalAlignment.Center,
        IsVisible = false,
    };

    private readonly Button _retryButton = new()
    {
        Content = L10n.Common.Retry,
        Classes = { "accent" },
        HorizontalAlignment = HorizontalAlignment.Center,
        IsVisible = false,
    };

    private CancellationTokenSource? _cts;
    private int _generation;
    private bool _running;

    public LoginView()
    {
        var title = new TextBlock
        {
            Text = L10n.Login.Title,
            FontSize = 18,
            FontWeight = FontWeight.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
        };

        var close = new Button
        {
            Content = "\uE711",
            Classes = { "toolbar" },
            FontFamily = IconFont,
            FontSize = 14,
        };
        ToolTip.SetTip(close, L10n.Common.Close);
        close.Click += (_, _) =>
        {
            App.IsLoginPresented = false;
            Cancel();
        };

        var header = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
        header.Children.Add(title);
        Grid.SetColumn(close, 1);
        header.Children.Add(close);

        var qrFrame = new Border
        {
            Width = 240,
            Height = 240,
            CornerRadius = new CornerRadius(CTRadius.Medium),
            Background = CTColors.OverlayBrush,
            HorizontalAlignment = HorizontalAlignment.Center,
            Child = new Grid { Children = { _qrImage, _spinner } },
        };

        var prompt = new TextBlock
        {
            Text = L10n.Login.ScanPrompt,
            Classes = { "secondary" },
            TextWrapping = TextWrapping.Wrap,
            TextAlignment = TextAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Center,
        };

        var stack = new StackPanel { Spacing = CTSpacing.Lg };
        stack.Children.Add(header);
        stack.Children.Add(qrFrame);
        stack.Children.Add(_statusText);
        stack.Children.Add(_errorText);
        stack.Children.Add(_retryButton);
        stack.Children.Add(prompt);
        Content = stack;

        _retryButton.Click += (_, _) => BeginLogin();
        App.PropertyChanged += OnAppPropertyChanged;
    }

    protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnAttachedToVisualTree(e);
        if (App.IsLoginPresented && !_running)
        {
            BeginLogin();
        }
    }

    protected override void OnDetachedFromVisualTree(VisualTreeAttachmentEventArgs e)
    {
        Cancel();
        base.OnDetachedFromVisualTree(e);
    }

    private void OnAppPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName != nameof(AppState.IsLoginPresented)) return;
        if (App.IsLoginPresented)
        {
            BeginLogin();
        }
        else
        {
            Cancel();
        }
    }

    private void BeginLogin()
    {
        Cancel();
        var cts = new CancellationTokenSource();
        _cts = cts;
        _generation += 1;
        var generation = _generation;
        _running = true;
        _errorText.IsVisible = false;
        _retryButton.IsVisible = false;
        _spinner.IsVisible = true;
        _statusText.Text = L10n.Login.WaitingScan;
        SetQRCode(null);
        _ = RunAsync(cts.Token, generation);
    }

    private void Cancel()
    {
        _cts?.Cancel();
        _cts = null;
        _running = false;
        _generation += 1;
    }

    private async Task RunAsync(CancellationToken ct, int generation)
    {
        try
        {
            while (!ct.IsCancellationRequested && generation == _generation)
            {
                var key = await Provider.FetchQRCodeKeyAsync(ct);
                var source = await Provider.FetchQRCodeImageAsync(key, ct);
                var bitmap = await LoadQRCodeAsync(source, ct);
                if (ct.IsCancellationRequested || generation != _generation) return;

                if (bitmap is null)
                {
                    ShowError("二维码加载失败");
                    return;
                }

                SetQRCode(bitmap);
                _spinner.IsVisible = false;
                _statusText.Text = L10n.Login.WaitingScan;

                var completed = await PollAsync(key, ct, generation);
                if (completed || ct.IsCancellationRequested || generation != _generation) return;

                SetQRCode(null);
                _spinner.IsVisible = true;
                _statusText.Text = L10n.Login.Expired;
                try
                {
                    await Task.Delay(TimeSpan.FromSeconds(1), ct);
                }
                catch (OperationCanceledException)
                {
                    return;
                }
            }
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception error)
        {
            if (generation == _generation && !ct.IsCancellationRequested)
            {
                ShowError(error.CtUserMessage());
            }
        }
        finally
        {
            if (generation == _generation) _running = false;
        }
    }

    private async Task<bool> PollAsync(string key, CancellationToken ct, int generation)
    {
        while (!ct.IsCancellationRequested && generation == _generation)
        {
            var status = await Provider.CheckQRCodeStatusAsync(key, ct);
            if (ct.IsCancellationRequested || generation != _generation) return true;

            switch (status)
            {
                case QRLoginStatus.WaitingScan:
                    _statusText.Text = L10n.Login.WaitingScan;
                    break;
                case QRLoginStatus.ScannedWaitingConfirm:
                    _statusText.Text = L10n.Login.Scanned;
                    break;
                case QRLoginStatus.Success success:
                    _statusText.Text = L10n.Login.Success;
                    return await CompleteLoginAsync(success.Cookie, ct, generation);
                case QRLoginStatus.Expired:
                    _statusText.Text = L10n.Login.Expired;
                    return false;
                case QRLoginStatus.Failed failed:
                    ShowError($"{L10n.Login.Failed}: {failed.Reason}");
                    return true;
            }

            try
            {
                await Task.Delay(TimeSpan.FromSeconds(2), ct);
            }
            catch (OperationCanceledException)
            {
                return true;
            }
        }
        return true;
    }

    private async Task<bool> CompleteLoginAsync(string cookie, CancellationToken ct, int generation)
    {
        var normalized = NeteaseCookieNormalizer.Normalize(cookie);
        AccountInfo? account;
        try
        {
            account = await Provider.FetchAccountInfoAsync(normalized, ct);
        }
        catch (OperationCanceledException)
        {
            return true;
        }
        catch (Exception error)
        {
            if (generation == _generation && !ct.IsCancellationRequested)
            {
                ShowError($"{L10n.Login.Failed}: {error.CtUserMessage()}");
            }
            return true;
        }

        if (generation != _generation || ct.IsCancellationRequested) return true;

        if (account is null)
        {
            ShowError(L10n.Login.Failed);
            return true;
        }

        CredentialStore.Shared.Save(
            normalized.Length > 0 ? normalized : cookie,
            CredentialKey.NeteaseCookie);

        try
        {
            await App.DidLoginAsync(account);
        }
        catch (Exception error)
        {
            if (generation == _generation) ShowError(error.CtUserMessage());
            return true;
        }

        if (generation == _generation)
        {
            App.IsLoginPresented = false;
        }
        return true;
    }

    private void ShowError(string message)
    {
        _errorText.Text = message;
        _errorText.IsVisible = true;
        _retryButton.IsVisible = true;
        _spinner.IsVisible = false;
    }

    private void SetQRCode(Bitmap? bitmap)
    {
        _qrImage.Source = bitmap;
    }

    private static async Task<Bitmap?> LoadQRCodeAsync(string source, CancellationToken ct)
    {
        if (source.StartsWith("data:", StringComparison.OrdinalIgnoreCase))
        {
            var comma = source.IndexOf(',');
            if (comma < 0) return null;
            try
            {
                var bytes = Convert.FromBase64String(source[(comma + 1)..]);
                using var stream = new MemoryStream(bytes);
                return new Bitmap(stream);
            }
            catch
            {
                return null;
            }
        }

        if (source.StartsWith("http://", StringComparison.OrdinalIgnoreCase) ||
            source.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
        {
            return await CoverImageLoader.Shared.LoadAsync(source, 440, ct).ConfigureAwait(true);
        }

        return null;
    }
}
