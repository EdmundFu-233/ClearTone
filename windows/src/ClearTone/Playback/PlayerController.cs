using Avalonia.Threading;
using ClearTone.Core.Logging;
using ClearTone.Core.Models;
using ClearTone.Core.Persistence;
using ClearTone.Providers.Netease;
using CommunityToolkit.Mvvm.ComponentModel;
using LibVLCSharp.Shared;

namespace ClearTone.Playback;

public sealed class PlayerController : ObservableObject
{
    public static readonly float[] AvailableRates = { 0.5f, 0.75f, 1.0f, 1.25f, 1.5f, 1.75f, 2.0f };

    public static readonly PlayerController Shared = new();

    public static string RateLabel(float rate)
    {
        if (Math.Abs(rate - 1.0) > 0.01)
        {
            var text = ((float)Math.Round(rate * 100) / 100).ToString("0.00");
            while (text.EndsWith('0')) text = text[..^1];
            if (text.EndsWith('.')) text = text[..^1];
            return text + "×";
        }
        return "1×";
    }

    internal static float ResolveRestoredPlaybackRate(float value)
    {
        if (AvailableRates.Contains(value)) return value;
        return AvailableRates.OrderBy(rate => Math.Abs(rate - value)).First();
    }

    private PlaybackState _playbackState = new PlaybackState.Idle();
    private double _duration;
    private float _volume = PlaybackVolumePolicy.DefaultVolume();
    private bool _isMuted;
    private Song? _currentSong;
    private double _currentTime;
    private double _bufferedTime;
    private QualityLevel _preferredQuality = SongQualityPolicy.AutoLevel;
    private QualityLevel _requestedQuality = SongQualityPolicy.AutoLevel;
    private bool _isAccountVIP;
    private AudioQuality? _actualQuality;
    private bool _isCurrentFromCache;
    private float _playbackRate = 1.0f;
    private DateTimeOffset? _sleepTimerEndDate;
    private double _sleepTimerRemaining;

    private IMusicProvider _provider = NeteaseProvider.Shared;
    private LibVLC? _libVlc;
    private MediaPlayer? _mediaPlayer;
    private Media? _activeMedia;
    private readonly List<Action> _mediaHandlerRemovals = new();

    private ulong _generation;
    private int _consecutiveFailures;
    private const int MaxConsecutiveFailures = 3;
    private string _retrySongID = "";
    private int _sameSongRetries;
    private CancellationTokenSource? _loadCts;
    private CancellationTokenSource? _autoAdvanceCts;
    private CancellationTokenSource? _sleepTimerCts;
    private ulong _seekToken;
    private bool _isUserSeeking;
    private bool _isLoadInFlight;
    private double? _pendingRestoreTime;
    private Uri? _pendingUrl;
    private bool _pendingAutoplay = true;
    private DateTimeOffset _lastProgressSaveAt = DateTimeOffset.MinValue;
    private static readonly TimeSpan ProgressSaveInterval = TimeSpan.FromSeconds(5);
    private Task? _pendingLoadTask;

    private const string SongQualityOverridesKey = "songQualityOverrides";
    private const int MaxSongQualityOverrides = 200;

    private PlayerController()
    {
        RecentlyPlayed = PersistenceStore.Shared.LoadRecentSongs();
        SongQualityOverrides = LoadSongQualityOverrides();
        var restored = LoadPersistedState();
        var settings = PersistenceStore.Shared.LoadSetting<AppSettings>("appSettings");
        PreferredQuality = settings?.PreferredQuality ?? SongQualityPolicy.AutoLevel;
        RequestedQuality = SongQualityPolicy.EffectiveGlobalLevel(PreferredQuality, IsAccountVIP);
        if (restored && settings?.ResumePlaybackOnLaunch == true)
        {
            BeginRestoredPlayback(autoplay: false);
        }
    }

    public PlaybackState PlaybackState
    {
        get => _playbackState;
        private set => SetProperty(ref _playbackState, value);
    }

    public double Duration
    {
        get => _duration;
        private set => SetProperty(ref _duration, value);
    }

    public float Volume
    {
        get => _volume;
        set
        {
            if (SetProperty(ref _volume, value)) ApplyVolumeToPlayer();
        }
    }

    public bool IsMuted
    {
        get => _isMuted;
        set
        {
            if (SetProperty(ref _isMuted, value)) ApplyVolumeToPlayer();
        }
    }

    public PlayQueue Queue { get; private set; } = new();

    public Song? CurrentSong
    {
        get => _currentSong;
        private set => SetProperty(ref _currentSong, value);
    }

    public List<Song> RecentlyPlayed { get; private set; }

    public QualityLevel PreferredQuality
    {
        get => _preferredQuality;
        private set => SetProperty(ref _preferredQuality, value);
    }

    public QualityLevel RequestedQuality
    {
        get => _requestedQuality;
        private set => SetProperty(ref _requestedQuality, value);
    }

    public bool IsAccountVIP
    {
        get => _isAccountVIP;
        private set => SetProperty(ref _isAccountVIP, value);
    }

    public AudioQuality? ActualQuality
    {
        get => _actualQuality;
        private set
        {
            if (SetProperty(ref _actualQuality, value)) OnPropertyChanged(nameof(PlayingSource));
        }
    }

    public bool IsCurrentFromCache
    {
        get => _isCurrentFromCache;
        private set
        {
            if (SetProperty(ref _isCurrentFromCache, value)) OnPropertyChanged(nameof(PlayingSource));
        }
    }

    public List<SongQualityOverride> SongQualityOverrides { get; private set; }

    public float PlaybackRate
    {
        get => _playbackRate;
        private set
        {
            if (SetProperty(ref _playbackRate, value))
            {
                OnPropertyChanged(nameof(IsRateAdjusted));
                OnPropertyChanged(nameof(PlaybackRateLabel));
            }
        }
    }

    public DateTimeOffset? SleepTimerEndDate
    {
        get => _sleepTimerEndDate;
        private set => SetProperty(ref _sleepTimerEndDate, value);
    }

    public double SleepTimerRemaining
    {
        get => _sleepTimerRemaining;
        private set => SetProperty(ref _sleepTimerRemaining, value);
    }

    public double CurrentTime
    {
        get => _currentTime;
        private set => SetProperty(ref _currentTime, value);
    }

    public double BufferedTime
    {
        get => _bufferedTime;
        private set => SetProperty(ref _bufferedTime, value);
    }

    public event Action<double>? TimeUpdated;

    public PlayingSourceInfo? PlayingSource
    {
        get
        {
            var song = CurrentSong;
            if (song is null) return null;
            var meta = AudioCacheManager.Shared.Meta(song.Id);
            return PlayingSourceFormatter.Describe(
                ActualQuality,
                RequestedQuality,
                IsCurrentFromCache,
                meta?.FormatName,
                meta?.BitrateKbps,
                AudioCacheManager.Shared.CachingSongIDs.Contains(song.Id));
        }
    }

    public bool IsRateAdjusted => Math.Abs(PlaybackRate - 1.0f) > 0.01f;

    public string PlaybackRateLabel => IsRateAdjusted ? RateLabel(PlaybackRate) : "";

    public bool CurrentSongUsesOverride =>
        CurrentSong is { } song && QualityOverrideFor(song.Id) is not null;

    internal Action<Action>? PostOverride { get; set; }
    internal Action<Uri>? PlaybackStartOverride { get; set; }
    internal Task? PendingLoadTask => _pendingLoadTask;

    private void Post(Action action)
    {
        if (PostOverride is { } custom)
        {
            custom(action);
            return;
        }
        try
        {
            if (Dispatcher.UIThread.CheckAccess()) action();
            else Dispatcher.UIThread.Post(action);
        }
        catch
        {
            action();
        }
    }

    public void SetProvider(IMusicProvider provider) => _provider = provider;

    // MARK: - 播放控制

    public void PlaySongs(IReadOnlyList<Song> songs, int startAt = 0)
    {
        if (songs.Count == 0)
        {
            ClearQueue();
            return;
        }
        Queue.Replace(songs, startAt);
        NotifyQueueChanged();
        PlayCurrent();
    }

    public void PlayCurrent()
    {
        if (Queue.CurrentItem is not { } item) return;
        PlaySong(item.Song);
    }

    public void PlaySong(Song song)
    {
        _consecutiveFailures = 0;
        _sameSongRetries = 0;
        _retrySongID = song.Id;
        RecordHistory(song);
        BeginPlay(song, null, autoplay: true);
    }

    private void RecordHistory(Song song)
    {
        var history = RecentlyPlayed.Where(existing => existing.Id != song.Id).ToList();
        history.Insert(0, song);
        if (history.Count > 100) history = history.Take(100).ToList();
        RecentlyPlayed = history;
        PersistenceWriter.Shared.ScheduleRecent(history);
    }

    private void BeginPlay(Song song, double? restoreTime, bool autoplay)
    {
        _generation += 1;
        var generation = _generation;
        CancelAutoAdvance();
        _loadCts?.Cancel();
        _loadCts = new CancellationTokenSource();
        var ct = _loadCts.Token;
        if (_retrySongID != song.Id)
        {
            _retrySongID = song.Id;
            _sameSongRetries = 0;
        }
        _isUserSeeking = false;
        ActualQuality = null;
        IsCurrentFromCache = false;
        DetachCurrentMedia();
        AudioCacheManager.Shared.SetCurrentCachedSong(null);

        PlaybackState = autoplay ? new PlaybackState.Loading(song.Id) : new PlaybackState.Paused(song.Id);
        CurrentSong = song;
        Duration = song.Duration;
        CurrentTime = restoreTime ?? 0;
        BufferedTime = 0;
        _pendingRestoreTime = restoreTime;
        _pendingAutoplay = autoplay;
        _pendingUrl = null;
        PersistState();
        _isLoadInFlight = true;
        _pendingLoadTask = LoadAndPlayAsync(song, generation, ct);
    }

    private async Task LoadAndPlayAsync(Song song, ulong generation, CancellationToken ct)
    {
        try
        {
            var playable = await ResolvePlayableAsync(song, ct).ConfigureAwait(false);
            Post(() => OnPlayableResolved(playable, song, generation, ct));
        }
        catch (Exception error)
        {
            Post(() => OnPlayableFailed(error, song, generation, ct));
        }
    }

    private async Task<PlayableURL> ResolvePlayableAsync(Song song, CancellationToken ct)
    {
        if (song.Source == SongSource.Local)
        {
            if (string.IsNullOrEmpty(song.LocalFileURL))
            {
                throw MusicException.FileNotFound();
            }
            var localUrl = new Uri(song.LocalFileURL);
            if (!File.Exists(localUrl.LocalPath)) throw MusicException.FileNotFound();
            return new PlayableURL
            {
                Url = localUrl,
                Quality = new AudioQuality { Level = QualityLevel.Unknown, IsActual = true },
            };
        }

        var overridden = QualityOverrideFor(song.Id);
        var level = SongQualityPolicy.EffectiveLevel(overridden, RequestedQuality);
        if (SongQualityPolicy.UseLocalCache(overridden is not null) &&
            AudioCacheManager.Shared.CachedItem(song.Id) is { } cached)
        {
            AudioCacheManager.Shared.SetCurrentCachedSong(song.Id);
            return new PlayableURL
            {
                Url = cached.Url,
                Quality = new AudioQuality
                {
                    Level = QualityLevel.Unknown,
                    Bitrate = cached.BitrateKbps,
                    IsActual = true,
                    Codec = cached.FormatName,
                },
                IsCached = true,
            };
        }

        var remote = await _provider.FetchPlayableURLAsync(song.Id, level, ct).ConfigureAwait(false);
        if (remote.Quality.Bitrate is null)
        {
            remote.Quality.Bitrate = SongQualityPolicy.DerivedBitrateKbps(remote.SizeBytes, song.Duration);
        }
        if (SongQualityPolicy.ShouldWriteCache(overridden is not null, remote.IsPreview))
        {
            AudioCacheManager.Shared.CacheInBackground(song.Id, remote.Url, song.Duration);
        }
        return remote;
    }

    private void OnPlayableResolved(PlayableURL playable, Song song, ulong generation, CancellationToken ct)
    {
        if (generation != _generation || ct.IsCancellationRequested) return;
        if (PlaybackState.SongId != song.Id) return;
        _isLoadInFlight = false;
        ActualQuality = playable.Quality;
        IsCurrentFromCache = playable.IsCached;
        CTLog.Playback.Info($"播放源: {(playable.IsCached ? "缓存" : "在线")} id={song.Id} 质量={playable.Quality.Level.DisplayName()}");
        if (_pendingAutoplay)
        {
            StartPlayback(playable.Url, song, generation);
        }
        else
        {
            _pendingUrl = playable.Url;
        }
    }

    private void OnPlayableFailed(Exception error, Song song, ulong generation, CancellationToken ct)
    {
        if (generation == _generation) _isLoadInFlight = false;
        if (generation != _generation || ct.IsCancellationRequested) return;
        HandlePlayError(error, song);
    }

    private void StartPlayback(Uri url, Song song, ulong generation)
    {
        DetachCurrentMedia();
        if (PlaybackStartOverride is { } custom)
        {
            PlaybackState = new PlaybackState.Loading(song.Id);
            custom(url);
            return;
        }
        try
        {
            EnsurePlayer();
        }
        catch (Exception error)
        {
            HandlePlayError(MusicException.Unknown(error.Message), song);
            return;
        }
        ApplyVolumeToPlayer();
        PlaybackState = new PlaybackState.Loading(song.Id);
        var media = new Media(_libVlc!, url);
        _activeMedia = media;
        AttachMediaEvents(generation, song.Id);
        _mediaPlayer!.Play(media);
        _mediaPlayer.SetRate(PlaybackRate);
    }

    private void EnsurePlayer()
    {
        if (_mediaPlayer is not null) return;
        LibVLCSharp.Shared.Core.Initialize();
        _libVlc ??= new LibVLC();
        _mediaPlayer = new MediaPlayer(_libVlc);
        ApplyVolumeToPlayer();
    }

    private void AttachMediaEvents(ulong generation, string songId)
    {
        void Add<T>(Action<EventHandler<T>> add, Action<EventHandler<T>> remove, EventHandler<T> handler)
            where T : EventArgs
        {
            add(handler);
            _mediaHandlerRemovals.Add(() => remove(handler));
        }

        Add<EventArgs>(
            handler => _mediaPlayer!.Playing += handler,
            handler => _mediaPlayer!.Playing -= handler,
            (_, _) => Post(() => OnVlcPlaying(generation, songId)));
        Add<EventArgs>(
            handler => _mediaPlayer!.Paused += handler,
            handler => _mediaPlayer!.Paused -= handler,
            (_, _) => Post(() => OnVlcPaused(generation, songId)));
        Add<EventArgs>(
            handler => _mediaPlayer!.EndReached += handler,
            handler => _mediaPlayer!.EndReached -= handler,
            (_, _) => Post(() => OnVlcEndReached(generation, songId)));
        Add<EventArgs>(
            handler => _mediaPlayer!.EncounteredError += handler,
            handler => _mediaPlayer!.EncounteredError -= handler,
            (_, _) => Post(() => OnVlcError(generation, songId)));
        Add<MediaPlayerTimeChangedEventArgs>(
            handler => _mediaPlayer!.TimeChanged += handler,
            handler => _mediaPlayer!.TimeChanged -= handler,
            (_, args) => Post(() => OnVlcTimeChanged(generation, args.Time / 1000.0)));
        Add<MediaPlayerLengthChangedEventArgs>(
            handler => _mediaPlayer!.LengthChanged += handler,
            handler => _mediaPlayer!.LengthChanged -= handler,
            (_, args) => Post(() => OnVlcLengthChanged(generation, args.Length / 1000.0)));
        Add<MediaPlayerBufferingEventArgs>(
            handler => _mediaPlayer!.Buffering += handler,
            handler => _mediaPlayer!.Buffering -= handler,
            (_, args) => Post(() => OnVlcBuffering(generation, songId, args.Cache)));
    }

    private void RemoveMediaHandlers()
    {
        foreach (var removal in _mediaHandlerRemovals)
        {
            try
            {
                removal();
            }
            catch
            {
            }
        }
        _mediaHandlerRemovals.Clear();
    }

    private void DetachCurrentMedia()
    {
        if (_mediaPlayer is not null)
        {
            RemoveMediaHandlers();
            try
            {
                _mediaPlayer.Stop();
            }
            catch
            {
            }
        }
        _activeMedia?.Dispose();
        _activeMedia = null;
    }

    private void TeardownPlayer()
    {
        DetachCurrentMedia();
        _mediaPlayer?.Dispose();
        _mediaPlayer = null;
    }

    private void ApplyVolumeToPlayer()
    {
        if (_mediaPlayer is null) return;
        var output = PlaybackVolumePolicy.Resolve(Volume, IsMuted);
        _mediaPlayer.Volume = (int)Math.Round(output.Volume * 100);
        _mediaPlayer.Mute = output.IsMuted;
    }

    // MARK: - VLC 事件

    private void OnVlcPlaying(ulong generation, string songId)
    {
        if (generation != _generation) return;
        if (PlaybackState.SongId != songId) return;
        _consecutiveFailures = 0;

        if (_mediaPlayer is { Length: > 0 } player)
        {
            var actual = player.Length / 1000.0;
            if (double.IsFinite(actual) && actual > 1 && Math.Abs(actual - Duration) > 0.5)
            {
                CTLog.Playback.Info($"时长校正: {Duration:F0}s → {actual:F0}s");
                Duration = actual;
            }
        }

        if (_pendingRestoreTime is { } restoreTime && restoreTime > 1 && Duration > 0 && restoreTime < Duration)
        {
            var target = Math.Min(restoreTime, Math.Max(Duration - 0.5, 0));
            _isUserSeeking = true;
            _mediaPlayer!.Time = (long)(target * 1000);
            _isUserSeeking = false;
            CurrentTime = restoreTime;
            TimeUpdated?.Invoke(restoreTime);
        }
        _pendingRestoreTime = null;

        PlaybackState = _pendingAutoplay
            ? new PlaybackState.Playing(songId)
            : new PlaybackState.Paused(songId);
        UpdateNowPlayingInfo();
    }

    private void OnVlcPaused(ulong generation, string songId)
    {
        if (generation != _generation) return;
        if (PlaybackState.SongId != songId) return;
        if (PlaybackState is PlaybackState.Failed) return;
        if (_pendingAutoplay) return;
        PlaybackState = new PlaybackState.Paused(songId);
    }

    private void OnVlcEndReached(ulong generation, string songId)
    {
        if (generation != _generation) return;
        if (PlaybackState.SongId != songId) return;
        PlaybackState = new PlaybackState.Ended(songId);
        HandleTrackEnded();
    }

    private void OnVlcError(ulong generation, string songId)
    {
        if (generation != _generation) return;
        if (CurrentSong is not { } song || song.Id != songId) return;
        HandlePlayError(MusicException.Unknown("播放中断"), song);
    }

    private void OnVlcTimeChanged(ulong generation, double seconds)
    {
        if (generation != _generation) return;
        if (_isUserSeeking || CurrentSong is null) return;
        if (!double.IsFinite(seconds)) return;
        CurrentTime = seconds;
        TimeUpdated?.Invoke(seconds);
        PersistProgressThrottled();
    }

    private void OnVlcLengthChanged(ulong generation, double seconds)
    {
        if (generation != _generation) return;
        if (PlaybackState.SongId is null) return;
        if (!double.IsFinite(seconds) || seconds <= 1) return;
        if (Math.Abs(seconds - Duration) > 0.5) Duration = seconds;
    }

    private void OnVlcBuffering(ulong generation, string songId, float cache)
    {
        if (generation != _generation) return;
        if (PlaybackState.SongId != songId) return;
        if (cache < 100)
        {
            if (_pendingAutoplay && PlaybackState is not (PlaybackState.Paused or PlaybackState.Failed))
            {
                PlaybackState = new PlaybackState.Buffering(songId);
            }
        }
        else if (PlaybackState is PlaybackState.Buffering or PlaybackState.Loading)
        {
            PlaybackState = _pendingAutoplay
                ? new PlaybackState.Playing(songId)
                : new PlaybackState.Paused(songId);
        }
    }

    internal void RaisePlayingForTesting(string songId) => Post(() => OnVlcPlaying(_generation, songId));

    internal void RaiseTimeChangedForTesting(double seconds) => Post(() => OnVlcTimeChanged(_generation, seconds));

    internal void RaiseEndReachedForTesting(string songId) => Post(() => OnVlcEndReached(_generation, songId));

    internal void RaiseErrorForTesting(string songId) => Post(() => OnVlcError(_generation, songId));

    internal void RaiseBufferingForTesting(string songId, float cache) =>
        Post(() => OnVlcBuffering(_generation, songId, cache));

    // MARK: - 播放控制（续）

    public void Pause()
    {
        _pendingAutoplay = false;
        CancelAutoAdvance();
        _mediaPlayer?.SetPause(true);
        if (PlaybackState is PlaybackState.Failed)
        {
            UpdateNowPlayingPlaybackState();
            return;
        }
        if (PlaybackState.SongId is { } songId)
        {
            PlaybackState = new PlaybackState.Paused(songId);
        }
        if (CurrentSong is not null)
        {
            PersistState();
        }
        UpdateNowPlayingPlaybackState();
    }

    public void Resume()
    {
        if (PlaybackState is PlaybackState.Failed)
        {
            RetryAfterFailure();
            return;
        }
        if (IsPreparingPlayback)
        {
            _pendingAutoplay = true;
            if (PlaybackState.SongId is { } preparingID)
            {
                PlaybackState = new PlaybackState.Loading(preparingID);
            }
            UpdateNowPlayingPlaybackState();
            return;
        }
        if (CurrentSong is null)
        {
            if (Queue.CurrentItem is not null)
            {
                PlayCurrent();
            }
            else if (Queue.Items.FirstOrDefault() is { } first)
            {
                Queue.JumpTo(first.Id);
                NotifyQueueChanged();
                PlayCurrent();
            }
            return;
        }
        if (_pendingUrl is { } pending)
        {
            _pendingAutoplay = true;
            StartPlayback(pending, CurrentSong, _generation);
            UpdateNowPlayingPlaybackState();
            return;
        }
        if (_mediaPlayer is null)
        {
            BeginRestoredPlayback(autoplay: true);
            return;
        }
        if (Duration > 0 && CurrentTime >= Math.Max(Duration - 0.5, 0))
        {
            BeginPlay(CurrentSong, null, autoplay: true);
            return;
        }
        _pendingAutoplay = true;
        _mediaPlayer.SetPause(false);
        if (PlaybackState.SongId is { } songId)
        {
            PlaybackState = new PlaybackState.Playing(songId);
        }
        UpdateNowPlayingPlaybackState();
    }

    private bool IsPreparingPlayback
    {
        get
        {
            if (CurrentSong is null) return false;
            return _isLoadInFlight || PlaybackState.IsLoading;
        }
    }

    private void BeginRestoredPlayback(bool autoplay)
    {
        if (CurrentSong is not { } song) return;
        if (_mediaPlayer is not null) return;
        BeginPlay(song, CurrentTime > 0 ? CurrentTime : null, autoplay);
    }

    public void ResumeFromPersistence() => BeginRestoredPlayback(autoplay: false);

    public void TogglePlayPause()
    {
        switch (PlaybackState)
        {
            case PlaybackState.Playing or PlaybackState.Buffering:
                Pause();
                break;
            case PlaybackState.Loading:
                if (_pendingAutoplay) Pause();
                else Resume();
                break;
            case PlaybackState.Failed:
                RetryAfterFailure();
                break;
            default:
                Resume();
                break;
        }
    }

    private void RetryAfterFailure()
    {
        _consecutiveFailures = 0;
        _sameSongRetries = 0;
        if (CurrentSong is { } song)
        {
            BeginPlay(song, null, autoplay: true);
        }
        else
        {
            PlayCurrent();
        }
    }

    public void Next()
    {
        if (Queue.Next() is not { } item) return;
        NotifyQueueChanged();
        PlaySong(item.Song);
    }

    public void Previous()
    {
        if (_activeMedia is not null && CurrentTime > 3)
        {
            Seek(0);
            return;
        }
        if (Queue.Previous() is not { } item) return;
        NotifyQueueChanged();
        PlaySong(item.Song);
    }

    public void PreviewSeek(double time)
    {
        if (!double.IsFinite(time)) return;
        _isUserSeeking = true;
        CurrentTime = time;
        TimeUpdated?.Invoke(time);
    }

    public void CommitSeek(double time)
    {
        if (!double.IsFinite(time)) return;
        _isUserSeeking = true;
        CurrentTime = time;
        TimeUpdated?.Invoke(time);
        _seekToken += 1;
        if (_mediaPlayer is not null && _activeMedia is not null)
        {
            _mediaPlayer.Time = (long)(Math.Max(0, time) * 1000);
        }
        else if (_pendingUrl is not null)
        {
            _pendingRestoreTime = time;
        }
        _isUserSeeking = false;
        UpdateNowPlayingElapsedTime();
        if (CurrentSong is not null) PersistState();
    }

    public void Seek(double time) => CommitSeek(time);

    public void SeekBy(double seconds)
    {
        var upper = Duration > 0 ? Duration : double.MaxValue;
        var target = Math.Min(Math.Max(0, CurrentTime + seconds), upper);
        CommitSeek(target);
    }

    public void SetPlayMode(PlayMode mode)
    {
        Queue.Mode = mode;
        NotifyQueueChanged();
        PersistState();
    }

    public void CyclePlayMode()
    {
        var next = Queue.Mode switch
        {
            PlayMode.Sequential => PlayMode.LoopAll,
            PlayMode.LoopAll => PlayMode.LoopOne,
            PlayMode.LoopOne => PlayMode.Shuffle,
            _ => PlayMode.Sequential,
        };
        SetPlayMode(next);
    }

    public void AppendToQueue(Song song)
    {
        Queue.Append(song);
        NotifyQueueChanged();
        PersistState();
    }

    public void AppendToQueue(IReadOnlyList<Song> songs)
    {
        if (songs.Count == 0) return;
        Queue.AppendRange(songs);
        NotifyQueueChanged();
        PersistState();
    }

    public void InsertNext(Song song)
    {
        Queue.InsertNext(song);
        NotifyQueueChanged();
        PersistState();
    }

    public void InsertNext(IReadOnlyList<Song> songs)
    {
        if (songs.Count == 0) return;
        if (Queue.CurrentIndex < 0)
        {
            Queue.AppendRange(songs);
        }
        else
        {
            for (var index = songs.Count - 1; index >= 0; index--)
            {
                Queue.InsertNext(songs[index]);
            }
        }
        NotifyQueueChanged();
        PersistState();
    }

    public void RemoveFromQueue(Guid itemID)
    {
        var wasCurrent = CurrentSong is not null && Queue.CurrentItem?.Id == itemID;
        var removedLastCurrent = wasCurrent && Queue.CurrentIndex == Queue.Items.Count - 1;
        if (!Queue.Remove(itemID)) return;
        NotifyQueueChanged();
        PersistState();
        if (!wasCurrent) return;
        if (removedLastCurrent)
        {
            StopPlayback();
        }
        else if (Queue.CurrentItem is { } next)
        {
            PlaySong(next.Song);
        }
        else
        {
            StopPlayback();
        }
    }

    public void ClearQueue()
    {
        Queue.Clear();
        NotifyQueueChanged();
        StopPlayback();
    }

    public void MoveQueueItems(int fromIndex, int toIndex)
    {
        Queue.Move(fromIndex, toIndex);
        NotifyQueueChanged();
        PersistState();
    }

    public void JumpTo(Guid itemID)
    {
        if (Queue.JumpTo(itemID) && Queue.CurrentItem is { } item)
        {
            NotifyQueueChanged();
            PlaySong(item.Song);
        }
    }

    // MARK: - 音质

    public void SetRequestedQuality(QualityLevel level)
    {
        var resolved = SongQualityPolicy.EffectiveGlobalLevel(level, IsAccountVIP);
        if (PreferredQuality == level && RequestedQuality == resolved) return;
        PreferredQuality = level;
        RequestedQuality = resolved;
        PersistState();
        if (CurrentSong is { } song && PlaybackState.SongId == song.Id && QualityOverrideFor(song.Id) is null)
        {
            ReloadCurrentSongForQualityChange();
        }
    }

    public void SetAccountIsVIP(bool value)
    {
        if (value == IsAccountVIP) return;
        IsAccountVIP = value;
        var resolved = SongQualityPolicy.EffectiveGlobalLevel(PreferredQuality, IsAccountVIP);
        if (resolved == RequestedQuality) return;
        RequestedQuality = resolved;
        if (CurrentSong is { } song && PlaybackState.SongId == song.Id && QualityOverrideFor(song.Id) is null)
        {
            ReloadCurrentSongForQualityChange();
        }
    }

    public void SetQualityOverride(QualityLevel? level, string songID)
    {
        var normalized = level == QualityLevel.Unknown ? null : level;
        if (normalized == QualityOverrideFor(songID)) return;
        if (normalized is { } value)
        {
            SongQualityOverrides.RemoveAll(entry => entry.SongID == songID);
            SongQualityOverrides.Insert(0, new SongQualityOverride { SongID = songID, Level = value });
            if (SongQualityOverrides.Count > MaxSongQualityOverrides)
            {
                SongQualityOverrides.RemoveRange(MaxSongQualityOverrides, SongQualityOverrides.Count - MaxSongQualityOverrides);
            }
        }
        else
        {
            SongQualityOverrides.RemoveAll(entry => entry.SongID == songID);
        }
        SaveSongQualityOverrides();
        if (CurrentSong is { } song && song.Id == songID)
        {
            ReloadCurrentSongForQualityChange();
        }
    }

    public QualityLevel? QualityOverrideFor(string songID) =>
        SongQualityOverrides.FirstOrDefault(entry => entry.SongID == songID)?.Level;

    public QualityLevel EffectiveQualityFor(string songID) =>
        SongQualityPolicy.EffectiveLevel(QualityOverrideFor(songID), RequestedQuality);

    private void ReloadCurrentSongForQualityChange()
    {
        if (CurrentSong is not { } song) return;
        var time = CurrentTime;
        var autoplay = PlaybackState.IsPlaying || PlaybackState.IsBuffering || _pendingAutoplay;
        BeginPlay(song, time > 0 ? time : null, autoplay);
    }

    private List<SongQualityOverride> LoadSongQualityOverrides() =>
        PersistenceStore.Shared.LoadSetting<List<SongQualityOverride>>(SongQualityOverridesKey) ?? new List<SongQualityOverride>();

    private void SaveSongQualityOverrides() =>
        PersistenceStore.Shared.SaveSetting(SongQualityOverrides, SongQualityOverridesKey);

    public void SetPlaybackRate(float rate)
    {
        var clamped = Math.Min(Math.Max(rate, 0.25f), 3.0f);
        if (Math.Abs(clamped - PlaybackRate) < 0.0001f) return;
        PlaybackRate = clamped;
        if (_mediaPlayer is not null)
        {
            _mediaPlayer.SetRate(clamped);
        }
        PersistState();
        UpdateNowPlayingInfo();
    }

    // MARK: - 睡眠定时器

    public void SetSleepTimer(double minutes)
    {
        _sleepTimerCts?.Cancel();
        _sleepTimerCts = null;
        if (minutes <= 0)
        {
            SleepTimerEndDate = null;
            SleepTimerRemaining = 0;
            return;
        }
        var end = DateTimeOffset.Now.AddMinutes(minutes);
        SleepTimerEndDate = end;
        SleepTimerRemaining = minutes * 60;
        var cts = new CancellationTokenSource();
        _sleepTimerCts = cts;
        _ = Task.Run(async () =>
        {
            while (!cts.IsCancellationRequested)
            {
                var remaining = (end - DateTimeOffset.Now).TotalSeconds;
                if (remaining <= 0) break;
                try
                {
                    await Task.Delay(1000, cts.Token).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    return;
                }
                var value = remaining;
                Post(() => SleepTimerRemaining = Math.Max(0, value));
            }
            if (cts.IsCancellationRequested) return;
            Post(() =>
            {
                SleepTimerEndDate = null;
                SleepTimerRemaining = 0;
                Pause();
            });
        });
    }

    public void CancelSleepTimer() => SetSleepTimer(0);

    // MARK: - 结束 / 失败处理

    private void HandleTrackEnded()
    {
        _consecutiveFailures = 0;
        if (Queue.HandleEnded() is { } nextItem)
        {
            NotifyQueueChanged();
            PlaySong(nextItem.Song);
        }
        else
        {
            PlaybackState = new PlaybackState.Idle();
            UpdateNowPlayingPlaybackState();
        }
    }

    private void HandlePlayError(Exception error, Song song)
    {
        if (PlaybackState is PlaybackState.Failed failed && failed.SongId == song.Id) return;

        var message = error.CtUserMessage();
        PlaybackState = new PlaybackState.Failed(song.Id, message);
        CTLog.Playback.Error($"播放失败 [{song.Title}]: {message}");

        _consecutiveFailures += 1;
        if (_consecutiveFailures >= MaxConsecutiveFailures)
        {
            CTLog.Playback.Warn($"连续失败 {_consecutiveFailures} 次，停止自动切换");
            return;
        }

        var generation = _generation;
        CancelAutoAdvance();
        var cts = new CancellationTokenSource();
        _autoAdvanceCts = cts;
        _ = Task.Run(async () =>
        {
            var refreshUrl = song.Id == CurrentSong?.Id && _sameSongRetries < 1;
            if (refreshUrl)
            {
                _sameSongRetries += 1;
                try
                {
                    await Task.Delay(800, cts.Token).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    return;
                }
                Post(() =>
                {
                    if (generation != _generation) return;
                    var resumeTime = CurrentTime > 3 ? CurrentTime : (double?)null;
                    BeginPlay(song, resumeTime, autoplay: true);
                });
                return;
            }

            try
            {
                await Task.Delay(1500, cts.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return;
            }
            Post(() =>
            {
                if (generation != _generation) return;
                if (_consecutiveFailures >= MaxConsecutiveFailures) return;
                if (Queue.Next() is not { } item)
                {
                    PlaybackState = new PlaybackState.Idle();
                    UpdateNowPlayingPlaybackState();
                    return;
                }
                NotifyQueueChanged();
                BeginPlay(item.Song, null, autoplay: true);
            });
        });
    }

    private void CancelAutoAdvance()
    {
        _autoAdvanceCts?.Cancel();
        _autoAdvanceCts = null;
    }

    // MARK: - 持久化

    private PersistedQueue MakeSnapshot()
    {
        var output = PlaybackVolumePolicy.Resolve(Volume, IsMuted);
        return PersistedQueue.From(Queue, CurrentTime, output.Volume, output.IsMuted, RequestedQuality, PlaybackRate);
    }

    private void PersistState(bool structureChanged = false)
    {
        _lastProgressSaveAt = DateTimeOffset.Now;
        PersistenceWriter.Shared.Schedule(MakeSnapshot());
    }

    private void PersistProgressThrottled()
    {
        if (DateTimeOffset.Now - _lastProgressSaveAt < ProgressSaveInterval) return;
        PersistState();
    }

    public async Task PersistNowAsync()
    {
        await PersistenceWriter.Shared.PersistAndFlushAsync(MakeSnapshot(), RecentlyPlayed).ConfigureAwait(false);
    }

    private bool LoadPersistedState()
    {
        var data = PersistenceStore.Shared.LoadQueue();
        if (data is null) return false;
        Queue = data.ToPlayQueue();
        var output = PlaybackVolumePolicy.Resolve(data.Volume, data.IsMuted);
        Volume = output.Volume;
        IsMuted = output.IsMuted;
        RequestedQuality = data.RequestedQuality;
        PlaybackRate = ResolveRestoredPlaybackRate(data.PlaybackRate);
        CurrentSong = Queue.CurrentItem?.Song;
        Duration = CurrentSong?.Duration ?? 0;
        CurrentTime = data.CurrentTime;
        if (CurrentSong is { } song)
        {
            PlaybackState = new PlaybackState.Paused(song.Id);
        }
        NotifyQueueChanged();
        return CurrentSong is not null;
    }

    private void StopPlayback()
    {
        _generation += 1;
        CancelAutoAdvance();
        _loadCts?.Cancel();
        _loadCts = null;
        _pendingLoadTask = null;
        _isLoadInFlight = false;
        _isUserSeeking = false;
        TeardownPlayer();
        CurrentSong = null;
        Duration = 0;
        CurrentTime = 0;
        BufferedTime = 0;
        _pendingRestoreTime = null;
        _pendingUrl = null;
        ActualQuality = null;
        IsCurrentFromCache = false;
        AudioCacheManager.Shared.SetCurrentCachedSong(null);
        _retrySongID = "";
        _sameSongRetries = 0;
        PlaybackState = new PlaybackState.Idle();
        UpdateNowPlayingPlaybackState();
        PersistState();
    }

    private void NotifyQueueChanged() => OnPropertyChanged(nameof(Queue));

    private void UpdateNowPlayingInfo()
    {
    }

    private void UpdateNowPlayingElapsedTime()
    {
    }

    private void UpdateNowPlayingPlaybackState()
    {
    }
}
