using System.Reflection;
using Avalonia.Headless.XUnit;
using ClearTone.Features.Shared;
using ClearTone.Shell;
using Xunit;

namespace ClearTone.Tests;

public class ViewSmokeTests
{
    public static TheoryData<Type> ViewTypes()
    {
        var data = new TheoryData<Type>();
        foreach (var type in typeof(PageFactory).Assembly.GetTypes())
        {
            if (type.IsAbstract || !typeof(Avalonia.Controls.Control).IsAssignableFrom(type)) continue;
            var isView = type.GetCustomAttributes(typeof(PageViewAttribute), false).Length > 0
                || type.GetCustomAttributes(typeof(OverlayViewAttribute), false).Length > 0;
            if (isView) data.Add(type);
        }
        return data;
    }

    [AvaloniaTheory]
    [MemberData(nameof(ViewTypes))]
    public void EveryViewConstructs(Type viewType)
    {
        var instance = Activator.CreateInstance(viewType);
        Assert.NotNull(instance);
    }

    [AvaloniaFact]
    public void EveryPageHasARegisteredView()
    {
        var registered = typeof(PageFactory).Assembly.GetTypes()
            .Where(type => type.GetCustomAttributes(typeof(PageViewAttribute), false).Length > 0)
            .Select(type => ((PageViewAttribute)type.GetCustomAttributes(typeof(PageViewAttribute), false)[0]).Page)
            .ToHashSet();
        foreach (var page in Enum.GetValues<Page>())
        {
            Assert.Contains(page, registered);
        }
    }

    [AvaloniaFact]
    public void EveryOverlayHasARegisteredView()
    {
        var registered = typeof(PageFactory).Assembly.GetTypes()
            .Where(type => type.GetCustomAttributes(typeof(OverlayViewAttribute), false).Length > 0)
            .Select(type => ((OverlayViewAttribute)type.GetCustomAttributes(typeof(OverlayViewAttribute), false)[0]).Kind)
            .ToHashSet();
        foreach (var kind in Enum.GetValues<OverlayKind>())
        {
            Assert.Contains(kind, registered);
        }
    }
}
