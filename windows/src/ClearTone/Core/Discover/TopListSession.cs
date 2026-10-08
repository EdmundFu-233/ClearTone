using ClearTone.Core.Logging;
using ClearTone.Core.Models;
using ClearTone.Providers.Netease;
using CommunityToolkit.Mvvm.ComponentModel;

namespace ClearTone.Core.Discover;

public sealed class TopListSession : ObservableObject
{
    private readonly object _gate = new();
    private readonly IMusicSocialProvider _source;

    private List<TopList> _lists = new();
    private bool _isLoading;
    private string? _errorMessage;

    private int _token;
    private CancellationTokenSource? _cts;

    public TopListSession(IMusicSocialProvider? source = null)
    {
        _source = source ?? (IMusicSocialProvider)NeteaseProvider.Shared;
    }

    public IReadOnlyList<TopList> Lists
    {
        get { lock (_gate) return _lists; }
    }

    public bool IsLoading
    {
        get { lock (_gate) return _isLoading; }
    }

    public string? ErrorMessage
    {
        get { lock (_gate) return _errorMessage; }
    }

    public async Task LoadAsync(CancellationToken ct = default)
    {
        int token;
        CancellationToken pageToken;
        lock (_gate)
        {
            _token++;
            token = _token;
            _cts?.Cancel();
            _cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            pageToken = _cts.Token;
            _isLoading = _lists.Count == 0;
            _errorMessage = null;
            OnPropertyChanged(nameof(IsLoading));
            OnPropertyChanged(nameof(ErrorMessage));
        }
        try
        {
            var loaded = await _source.FetchTopListsAsync(pageToken).ConfigureAwait(false);
            lock (_gate)
            {
                if (token != _token || pageToken.IsCancellationRequested) return;
                _lists = loaded;
                OnPropertyChanged(nameof(Lists));
            }
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception error)
        {
            lock (_gate)
            {
                if (token != _token || pageToken.IsCancellationRequested) return;
                _errorMessage = error.CtUserMessage();
                OnPropertyChanged(nameof(ErrorMessage));
                CTLog.General.Error($"加载榜单目录失败: {CTLog.Sanitize(error.Message)}");
            }
        }
        finally
        {
            lock (_gate)
            {
                if (token == _token)
                {
                    _isLoading = false;
                    OnPropertyChanged(nameof(IsLoading));
                }
            }
        }
    }
}
