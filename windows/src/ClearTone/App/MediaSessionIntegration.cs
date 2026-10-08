using Avalonia.Controls;
using Avalonia.Threading;
using ClearTone.Core.Logging;
using ClearTone.DesignSystem;
using ClearTone.Playback;

#if WINDOWS
using Windows.Media;
using Windows.Storage.Streams;
#endif

namespace ClearTone.Shell;

public static class MediaSessionIntegration
{
#if WINDOWS
    private static SystemMediaTransportControls? _controls;
    private static DateTimeOffset _lastTimelineUpdate = DateTimeOffset.MinValue;
    private static string? _thumbnailSongID;

    public static void Initialize(Window window)
    {
        try
        {
            _controls = SystemMediaTransportControls.GetForCurrentView();
            _controls.IsEnabled = true;
            _controls.IsPlayEnabled = true;
            _controls.IsPauseEnabled = true;
            _controls.IsNextEnabled = true;
            _controls.IsPreviousEnabled = true;
            _controls.IsStopEnabled = true;

            _controls.ButtonPressed += (_, args) =>
            {
                switch (args.Button)
                {
                    case SystemMediaTransportControlsButton.Play:
                        Post(() => PlayerController.Shared.Resume());
                        break;
                    case SystemMediaTransportControlsButton.Pause:
                    case SystemMediaTransportControlsButton.Stop:
                        Post(() => PlayerController.Shared.Pause());
                        break;
                    case SystemMediaTransportControlsButton.Next:
                        Post(() => PlayerController.Shared.Next());
                        break;
                    case SystemMediaTransportControlsButton.Previous:
                        Post(() => PlayerController.Shared.Previous());
                        break;
                }
            };

            _controls.PlaybackPositionChangeRequested += (_, args) =>
            {
                var seconds = args.RequestedPlaybackPosition.TotalSeconds;
                Post(() => PlayerController.Shared.CommitSeek(seconds));
            };

            PlayerController.Shared.PropertyChanged += OnPlayerPropertyChanged;
            PlayerController.Shared.TimeUpdated += OnTimeUpdated;

            RefreshMetadata();
            UpdatePlaybackStatus();
            UpdateTimeline();
            CTLog.General.Info("已接入系统媒体控制（SMTC）");
        }
        catch (Exception error)
        {
            _controls = null;
            CTLog.General.Warn($"系统媒体控制不可用（不影响播放）: {CTLog.Sanitize(error.Message)}");
        }
    }

    private static void OnPlayerPropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(PlayerController.CurrentSong):
                RefreshMetadata();
                UpdatePlaybackStatus();
                UpdateTimeline();
                break;
            case nameof(PlayerController.PlaybackState):
                UpdatePlaybackStatus();
                UpdateTimeline();
                break;
            case nameof(PlayerController.Duration):
                UpdateTimeline();
                break;
        }
    }

    private static void OnTimeUpdated(double time)
    {
        if (DateTimeOffset.Now - _lastTimelineUpdate < TimeSpan.FromSeconds(3)) return;
        _lastTimelineUpdate = DateTimeOffset.Now;
        Post(UpdateTimeline);
    }

    private static void Post(Action action)
    {
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

    private static void RefreshMetadata()
    {
        if (_controls is null) return;
        try
        {
            var song = PlayerController.Shared.CurrentSong;
            var updater = _controls.DisplayUpdater;
            updater.Type = MediaPlaybackType.Music;
            if (song is null)
            {
                updater.MusicProperties.Title = "";
                updater.MusicProperties.Artist = "";
                updater.MusicProperties.AlbumTitle = "";
                updater.Update();
                _thumbnailSongID = null;
                return;
            }
            updater.MusicProperties.Title = song.Title;
            updater.MusicProperties.Artist = song.ArtistNames;
            updater.MusicProperties.AlbumTitle = song.Album?.Name ?? "";
            updater.Update();

            if (song.CoverURL is { Length: > 0 } cover && _thumbnailSongID != song.Id)
            {
                _thumbnailSongID = song.Id;
                RefreshThumbnail(cover);
            }
            else if (song.CoverURL is null)
            {
                _thumbnailSongID = null;
            }
        }
        catch (Exception error)
        {
            CTLog.General.Debug($"更新媒体信息失败: {CTLog.Sanitize(error.Message)}");
        }
    }

    private static async void RefreshThumbnail(string url)
    {
        try
        {
            var bytes = await CoverImageLoader.Shared.LoadBytesAsync(url).ConfigureAwait(true);
            if (bytes is null || _controls is null) return;
            using var stream = new MemoryStream(bytes);
            _controls.DisplayUpdater.Thumbnail =
                RandomAccessStreamReference.CreateFromStream(stream.AsRandomAccessStream());
            _controls.DisplayUpdater.Update();
        }
        catch (Exception error)
        {
            CTLog.General.Debug($"更新媒体封面失败: {CTLog.Sanitize(error.Message)}");
        }
    }

    private static void UpdatePlaybackStatus()
    {
        if (_controls is null) return;
        try
        {
            _controls.PlaybackStatus = PlayerController.Shared.PlaybackState switch
            {
                PlaybackState.Playing => MediaPlaybackStatus.Playing,
                PlaybackState.Paused => MediaPlaybackStatus.Paused,
                PlaybackState.Loading => MediaPlaybackStatus.Changing,
                PlaybackState.Buffering => MediaPlaybackStatus.Changing,
                _ => MediaPlaybackStatus.Stopped,
            };
        }
        catch
        {
        }
    }

    private static void UpdateTimeline()
    {
        if (_controls is null) return;
        try
        {
            var player = PlayerController.Shared;
            if (player.Duration <= 0) return;
            _controls.UpdateTimelineProperties(new SystemMediaTransportControlsTimelineProperties
            {
                StartTime = TimeSpan.Zero,
                EndTime = TimeSpan.FromSeconds(player.Duration),
                Position = TimeSpan.FromSeconds(Math.Clamp(player.CurrentTime, 0, player.Duration)),
                MinSeekTime = TimeSpan.Zero,
                MaxSeekTime = TimeSpan.FromSeconds(player.Duration),
            });
        }
        catch
        {
        }
    }
#else
    public static void Initialize(Window window)
    {
    }
#endif
}
