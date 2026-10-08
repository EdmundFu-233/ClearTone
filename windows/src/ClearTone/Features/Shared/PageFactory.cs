using Avalonia.Controls;
using ClearTone.Shell;

namespace ClearTone.Features.Shared;

[AttributeUsage(AttributeTargets.Class, Inherited = false)]
public sealed class PageViewAttribute : Attribute
{
    public Page Page { get; }

    public PageViewAttribute(Page page) => Page = page;
}

public enum OverlayKind
{
    NowPlaying,
    Queue,
    Login,
}

[AttributeUsage(AttributeTargets.Class, Inherited = false)]
public sealed class OverlayViewAttribute : Attribute
{
    public OverlayKind Kind { get; }

    public OverlayViewAttribute(OverlayKind kind) => Kind = kind;
}

public interface IPageView
{
    void OnActivated();
}

public static class PageFactory
{
    private static readonly Dictionary<Page, Type> PageTypes = new();
    private static readonly Dictionary<OverlayKind, Type> OverlayTypes = new();
    private static readonly Dictionary<Page, Control> Cache = new();
    private static readonly Dictionary<OverlayKind, Control> OverlayCache = new();
    private static bool _scanned;

    private static void Scan()
    {
        if (_scanned) return;
        _scanned = true;
        foreach (var type in typeof(PageFactory).Assembly.GetTypes())
        {
            if (type.IsAbstract || !typeof(Control).IsAssignableFrom(type)) continue;
            if (type.GetCustomAttributes(typeof(PageViewAttribute), false) is { Length: > 0 } pageAttributes)
            {
                var attribute = (PageViewAttribute)pageAttributes[0];
                PageTypes[attribute.Page] = type;
            }
            if (type.GetCustomAttributes(typeof(OverlayViewAttribute), false) is { Length: > 0 } overlayAttributes)
            {
                var attribute = (OverlayViewAttribute)overlayAttributes[0];
                OverlayTypes[attribute.Kind] = type;
            }
        }
    }

    public static Control Resolve(Page page)
    {
        if (Cache.TryGetValue(page, out var cached)) return cached;
        Scan();
        Control control;
        if (PageTypes.TryGetValue(page, out var type))
        {
            control = (Control)Activator.CreateInstance(type)!;
        }
        else
        {
            control = new PlaceholderView(page.DisplayName());
        }
        Cache[page] = control;
        if (control is IPageView pageView)
        {
            pageView.OnActivated();
        }
        return control;
    }

    public static Control ResolveOverlay(OverlayKind kind)
    {
        if (OverlayCache.TryGetValue(kind, out var cached)) return cached;
        Scan();
        Control control;
        if (OverlayTypes.TryGetValue(kind, out var type))
        {
            control = (Control)Activator.CreateInstance(type)!;
        }
        else
        {
            control = new PlaceholderView(kind switch
            {
                OverlayKind.NowPlaying => "正在播放",
                OverlayKind.Queue => "播放队列",
                _ => "登录",
            });
        }
        OverlayCache[kind] = control;
        return control;
    }

    public static void Invalidate(Page page) => Cache.Remove(page);

    public static void InvalidateOverlay(OverlayKind kind) => OverlayCache.Remove(kind);
}
