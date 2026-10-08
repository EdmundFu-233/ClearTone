using System.Reflection;
using ClearTone.Core.Models;
using ClearTone.Core.Persistence;
using ClearTone.Core.Security;
using ClearTone.Providers.Netease;
using ClearTone.Shell;
using Xunit;

namespace ClearTone.Tests;

public class AppStateLoginLoadTests : IDisposable
{
    public AppStateLoginLoadTests() => Cleanup();

    public void Dispose() => Cleanup();

    private static void Cleanup()
    {
        CredentialStore.Shared.Delete(CredentialKey.NeteaseCookie);
        CredentialStore.Shared.Delete(CredentialKey.NeteaseUserID);
        PersistenceStore.Shared.ClearCachedAccount();
        PersistenceStore.Shared.ClearCachedLikedSongs();
        PersistenceStore.Shared.ClearCachedUserPlaylists();
    }

    private static AccountInfo MakeAccount() => new()
    {
        UserID = "86080189",
        Nickname = "测试",
    };

    private static Song MakeSong(string id) => new()
    {
        Id = id,
        Title = $"歌-{id}",
        Source = SongSource.Netease,
    };

    private static Playlist MakePlaylist(string id) => new()
    {
        Id = id,
        Name = "我喜欢的音乐",
        Source = SongSource.Netease,
    };

    private static void RaiseSessionExpired()
    {
        var field = typeof(NeteaseProvider).GetField(
            nameof(NeteaseProvider.SessionExpired),
            BindingFlags.Instance | BindingFlags.NonPublic);
        Assert.NotNull(field);
        var handler = (Action?)field!.GetValue(NeteaseProvider.Shared);
        handler?.Invoke();
    }

    [Fact]
    public async Task TestDidLoginLoadsLibraryData()
    {
        var likedIDCalls = 0;
        var likedSongCalls = 0;
        var playlistCalls = 0;
        var provider = new StubMusicProvider();
        provider.LikedSongIDsHandler = ct =>
        {
            Interlocked.Increment(ref likedIDCalls);
            return Task.FromResult(new List<string> { "s1" });
        };
        provider.LikedSongsHandler = ct =>
        {
            Interlocked.Increment(ref likedSongCalls);
            return Task.FromResult(new List<Song> { MakeSong("s1") });
        };
        provider.UserPlaylistsHandler = ct =>
        {
            Interlocked.Increment(ref playlistCalls);
            return Task.FromResult(new List<Playlist> { MakePlaylist("p1") });
        };
        var state = new AppState(provider);

        await state.DidLoginAsync(MakeAccount());

        Assert.True(state.IsLoggedIn);
        Assert.Equal(1, likedIDCalls);
        Assert.Equal(1, likedSongCalls);
        Assert.Equal(1, playlistCalls);
        Assert.True(state.IsLiked("s1"));
        Assert.Contains(state.UserPlaylists, playlist => playlist.Id == "p1");
    }

    [Fact]
    public async Task TestRestoreLoginStateLoadsLibraryData()
    {
        CredentialStore.Shared.Save("MUSIC_U=unit-test", CredentialKey.NeteaseCookie);
        var likedIDCalls = 0;
        var playlistCalls = 0;
        var provider = new StubMusicProvider();
        provider.AccountInfoHandler = ct => Task.FromResult<AccountInfo?>(MakeAccount());
        provider.LikedSongIDsHandler = ct =>
        {
            Interlocked.Increment(ref likedIDCalls);
            return Task.FromResult(new List<string> { "s1" });
        };
        provider.UserPlaylistsHandler = ct =>
        {
            Interlocked.Increment(ref playlistCalls);
            return Task.FromResult(new List<Playlist> { MakePlaylist("p1") });
        };
        var state = new AppState(provider);

        await state.RestoreLoginStateAsync();

        Assert.True(state.IsLoggedIn);
        Assert.Equal(1, likedIDCalls);
        Assert.Equal(1, playlistCalls);
    }

    [Fact]
    public async Task TestRestoreWithoutAccountLoadsNothing()
    {
        var likedIDCalls = 0;
        var playlistCalls = 0;
        var provider = new StubMusicProvider();
        provider.LikedSongIDsHandler = ct =>
        {
            Interlocked.Increment(ref likedIDCalls);
            return Task.FromResult(new List<string> { "s1" });
        };
        provider.UserPlaylistsHandler = ct =>
        {
            Interlocked.Increment(ref playlistCalls);
            return Task.FromResult(new List<Playlist> { MakePlaylist("p1") });
        };
        var state = new AppState(provider);

        await state.RestoreLoginStateAsync();

        Assert.False(state.IsLoggedIn);
        Assert.Equal(0, likedIDCalls);
        Assert.Equal(0, playlistCalls);
    }

    [Fact]
    public async Task TestNotLoggedInDoesNotFetchLibrary()
    {
        var likedIDCalls = 0;
        var likedSongCalls = 0;
        var playlistCalls = 0;
        var provider = new StubMusicProvider();
        provider.LikedSongIDsHandler = ct =>
        {
            Interlocked.Increment(ref likedIDCalls);
            return Task.FromResult(new List<string> { "s1" });
        };
        provider.LikedSongsHandler = ct =>
        {
            Interlocked.Increment(ref likedSongCalls);
            return Task.FromResult(new List<Song> { MakeSong("s1") });
        };
        provider.UserPlaylistsHandler = ct =>
        {
            Interlocked.Increment(ref playlistCalls);
            return Task.FromResult(new List<Playlist> { MakePlaylist("p1") });
        };
        var state = new AppState(provider);

        await state.LoadLikedSongsAsync();
        await state.LoadUserPlaylistsAsync();

        Assert.Equal(0, likedIDCalls);
        Assert.Equal(0, likedSongCalls);
        Assert.Equal(0, playlistCalls);
        Assert.False(state.IsLoggedIn);
    }

    [Fact]
    public void TestApplyAccountResetsNeedsReLogin()
    {
        var state = new AppState(new StubMusicProvider());
        state.NeedsReLogin = true;

        state.ApplyAccount(MakeAccount());

        Assert.False(state.NeedsReLogin);
        Assert.True(state.IsLoggedIn);
        Assert.True(state.CanPerformWrite);
    }

    [Fact]
    public async Task TestReLoginAfterSessionExpiryClearsNeedsReLogin()
    {
        var provider = new StubMusicProvider();
        var state = new AppState(provider);
        await state.DidLoginAsync(MakeAccount());
        Assert.True(state.CanPerformWrite);

        RaiseSessionExpired();

        Assert.True(state.NeedsReLogin);
        Assert.False(state.IsLoggedIn);
        Assert.False(state.CanPerformWrite);

        await state.DidLoginAsync(MakeAccount());

        Assert.False(state.NeedsReLogin);
        Assert.True(state.CanPerformWrite);
    }

    [Fact]
    public async Task TestSessionExpiryDropsPreviousAccountPlaylists()
    {
        var provider = new StubMusicProvider();
        provider.UserPlaylistsHandler = ct =>
            Task.FromResult(new List<Playlist> { MakePlaylist("p1") });
        var state = new AppState(provider);
        await state.DidLoginAsync(MakeAccount());
        Assert.Equal(new[] { "p1" }, state.UserPlaylists.Select(playlist => playlist.Id));

        RaiseSessionExpired();

        Assert.True(state.NeedsReLogin);
        Assert.Empty(state.UserPlaylists);
    }

    [Fact]
    public async Task TestPerformLogoutClearsUserPlaylists()
    {
        var logoutCalls = 0;
        var provider = new StubMusicProvider();
        provider.UserPlaylistsHandler = ct =>
            Task.FromResult(new List<Playlist> { MakePlaylist("p1") });
        provider.LogoutHandler = ct =>
        {
            Interlocked.Increment(ref logoutCalls);
            return Task.CompletedTask;
        };
        var state = new AppState(provider);
        await state.DidLoginAsync(MakeAccount());
        Assert.Single(state.UserPlaylists);

        await state.PerformLogoutAsync();

        Assert.Equal(1, logoutCalls);
        Assert.False(state.IsLoggedIn);
        Assert.Empty(state.UserPlaylists);
    }

    [Fact]
    public void DataContextKeyChangeIsBroadcastOnLoginAndLogout()
    {
        var provider = new StubMusicProvider();
        var state = new AppState(provider);
        var raised = new List<string?>();
        state.PropertyChanged += (_, e) => raised.Add(e.PropertyName);

        var before = state.DataContextKey;
        state.ApplyAccount(new AccountInfo { UserID = "42", Nickname = "tester" });

        Assert.Contains(nameof(AppState.DataContextKey), raised);
        Assert.Contains(nameof(AppState.CurrentAccountGeneration), raised);
        Assert.NotEqual(before, state.DataContextKey);

        raised.Clear();
        var afterLogin = state.DataContextKey;
        state.PerformLogoutAsync().GetAwaiter().GetResult();

        Assert.Contains(nameof(AppState.DataContextKey), raised);
        Assert.NotEqual(afterLogin, state.DataContextKey);
        Assert.False(state.IsLoggedIn);
    }

}
