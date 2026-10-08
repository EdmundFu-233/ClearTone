using ClearTone.Core.Models;
using ClearTone.Providers.Netease;
using CommunityToolkit.Mvvm.ComponentModel;

namespace ClearTone.Core.Lyrics;

public delegate IMusicProvider? LyricsProviderResolver(Song song);

public sealed class LyricsSession : ObservableObject
{
    private readonly object _gate = new();
    private readonly LyricsProviderResolver _resolve;

    private List<LyricLine> _lines = new();
    private bool _isLoading;
    private string? _errorMessage;
    private bool _isPureMusic;
    private bool _hasWordTiming;

    private int _token;
    private CancellationTokenSource? _cts;

    public LyricsSession(LyricsProviderResolver resolve)
    {
        _resolve = resolve;
    }

    public static LyricsSession NeteaseOnly() =>
        new(song => song.Source == SongSource.Netease ? NeteaseProvider.Shared : null);

    public IReadOnlyList<LyricLine> Lines
    {
        get { lock (_gate) return _lines; }
    }

    public bool IsLoading
    {
        get { lock (_gate) return _isLoading; }
    }

    public string? ErrorMessage
    {
        get { lock (_gate) return _errorMessage; }
    }

    public bool IsPureMusic
    {
        get { lock (_gate) return _isPureMusic; }
    }

    public bool HasWordTiming
    {
        get { lock (_gate) return _hasWordTiming; }
    }

    public void Reset()
    {
        lock (_gate)
        {
            _token++;
            _cts?.Cancel();
            _cts = null;
            _lines = new List<LyricLine>();
            _isLoading = false;
            _errorMessage = null;
            _isPureMusic = false;
            _hasWordTiming = false;
            OnPropertyChanged(nameof(Lines));
            OnPropertyChanged(nameof(IsLoading));
            OnPropertyChanged(nameof(ErrorMessage));
            OnPropertyChanged(nameof(IsPureMusic));
            OnPropertyChanged(nameof(HasWordTiming));
        }
    }

    public async Task LoadAsync(Song? song, CancellationToken ct = default)
    {
        if (ct.IsCancellationRequested) return;
        Reset();

        var provider = song is null ? null : _resolve(song);
        if (song is null || provider is null) return;

        int token;
        CancellationToken pageToken;
        lock (_gate)
        {
            token = _token;
            _cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            pageToken = _cts.Token;
            _isLoading = true;
            OnPropertyChanged(nameof(IsLoading));
        }

        try
        {
            var result = await provider.FetchLyricsAsync(song.Id, pageToken).ConfigureAwait(false);
            lock (_gate)
            {
                if (token != _token || pageToken.IsCancellationRequested) return;
                _lines = result.Lines;
                _isPureMusic = result.IsPureMusic;
                _hasWordTiming = result.HasWordTiming;
                OnPropertyChanged(nameof(Lines));
                OnPropertyChanged(nameof(IsPureMusic));
                OnPropertyChanged(nameof(HasWordTiming));
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
