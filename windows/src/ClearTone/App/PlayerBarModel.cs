using ClearTone.Core.Models;
using ClearTone.DesignSystem;
using ClearTone.Playback;
using ClearTone.Shell;
using CommunityToolkit.Mvvm.ComponentModel;

namespace ClearTone.Shell;

public sealed class PlayerBarModel : ObservableObject
{
    private readonly PlayerController _player = PlayerController.Shared;

    public PlayerBarModel()
    {
        _player.PropertyChanged += (_, _) => Refresh();
        _player.TimeUpdated += _ => RefreshTime();
        AudioCacheManager.Shared.StateChanged += () =>
        {
            OnPropertyChanged(nameof(SourceText));
            OnPropertyChanged(nameof(QualityLabel));
        };
        AppState.Shared.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName is nameof(AppState.LikesVersion) or nameof(AppState.CurrentPage))
            {
                Refresh();
            }
        };
    }

    public PlayerController Player => _player;

    public string Title => _player.CurrentSong?.Title ?? "未在播放";

    public string Artist => _player.CurrentSong?.ArtistNames ?? L10n.Common.AppName;

    public string? CoverUrl => _player.CurrentSong?.CoverURL;

    public string PlayPauseGlyph => _player.PlaybackState.IsPlayIntentActive ? "\uE769" : "\uE768";

    public string PlayPauseTooltip => _player.PlaybackState.IsPlayIntentActive ? L10n.Common.Pause : L10n.Common.Play;

    public string ModeGlyph => _player.Queue.Mode switch
    {
        PlayMode.Sequential => "\uE8EE",
        PlayMode.LoopAll => "\uE8EE",
        PlayMode.LoopOne => "\uE8ED",
        _ => "\uE8B1",
    };

    public string ModeLabel => _player.Queue.Mode.DisplayName();

    public string LikeGlyph => IsLiked ? "\uEB52" : "\uEB51";

    public Avalonia.Media.IBrush LikeForeground => IsLiked
        ? new Avalonia.Media.SolidColorBrush(CTColors.Accent)
        : new Avalonia.Media.SolidColorBrush(CTColors.TextSecondary);

    public void NotifyLike() => OnPropertyChanged(nameof(LikeGlyph));

    public void RefreshRate()
    {
        OnPropertyChanged(nameof(IsRateAdjusted));
        OnPropertyChanged(nameof(RateLabel));
    }

    public bool IsLiked
    {
        get
        {
            var song = _player.CurrentSong;
            return song is not null && AppState.Shared.IsLiked(song.Id);
        }
    }

    public double ProgressPercent
    {
        get
        {
            var duration = _player.Duration;
            if (duration <= 0) return 0;
            return Math.Clamp(_player.CurrentTime / duration * 100, 0, 100);
        }
    }

    public string CurrentTimeText => CTFormatting.Time(_player.CurrentTime);

    public string DurationText => CTFormatting.Time(_player.Duration);

    public double VolumePercent => Math.Clamp(_player.Volume * 100, 0, 100);

    public bool IsMuted => _player.IsMuted;

    public string QualityLabel
    {
        get
        {
            var song = _player.CurrentSong;
            if (song is null) return "";
            return _player.EffectiveQualityFor(song.Id).DisplayName();
        }
    }

    public bool IsRateAdjusted => _player.IsRateAdjusted;

    public string RateLabel => _player.PlaybackRateLabel;

    public string? SourceText => _player.PlayingSource?.Text;

    private void Refresh() => OnPropertyChanged((string?)null);

    private void RefreshTime()
    {
        OnPropertyChanged(nameof(ProgressPercent));
        OnPropertyChanged(nameof(CurrentTimeText));
    }
}
