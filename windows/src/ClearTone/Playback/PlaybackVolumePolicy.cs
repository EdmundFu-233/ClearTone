namespace ClearTone.Playback;

public static class PlaybackVolumePolicy
{
    public enum Platform
    {
        IOS,
        MacOS,
        Windows,
    }

    public sealed record Output(float Volume, bool IsMuted);

    public const float IOSDefaultVolume = 1f;
    public const float DesktopDefaultVolume = 0.8f;

    public static Platform CurrentPlatform =>
        OperatingSystem.IsIOS() ? Platform.IOS :
        OperatingSystem.IsWindows() ? Platform.Windows : Platform.MacOS;

    public static float DefaultVolume(Platform? platform = null) =>
        (platform ?? CurrentPlatform) == Platform.IOS ? IOSDefaultVolume : DesktopDefaultVolume;

    public static Output Resolve(float volume, bool isMuted, Platform? platform = null)
    {
        return (platform ?? CurrentPlatform) switch
        {
            Platform.IOS => new Output(IOSDefaultVolume, false),
            _ => new Output(volume, isMuted),
        };
    }
}
