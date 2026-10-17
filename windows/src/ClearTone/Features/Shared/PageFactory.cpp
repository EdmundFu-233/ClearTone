#include "Features/Shared/PageFactory.h"

#include "Features/Shared/PlaceholderView.h"

#include <QPointer>

namespace ct {

namespace {

QHash<int, PageFactory::Factory>& pageFactories()
{
    static QHash<int, PageFactory::Factory> factories;
    return factories;
}

QHash<int, PageFactory::Factory>& overlayFactories()
{
    static QHash<int, PageFactory::Factory> factories;
    return factories;
}

QHash<int, QPointer<QWidget>>& pageCache()
{
    static QHash<int, QPointer<QWidget>> cache;
    return cache;
}

QHash<int, QPointer<QWidget>>& overlayCache()
{
    static QHash<int, QPointer<QWidget>> cache;
    return cache;
}

} // namespace

void PageFactory::registerPage(Page page, Factory factory)
{
    pageFactories().insert(static_cast<int>(page), std::move(factory));
}

void PageFactory::registerOverlay(OverlayKind kind, Factory factory)
{
    overlayFactories().insert(static_cast<int>(kind), std::move(factory));
}

QWidget* PageFactory::resolve(Page page)
{
    const int key = static_cast<int>(page);
    if (QWidget* cached = pageCache().value(key)) return cached;
    QWidget* widget = nullptr;
    const auto factory = pageFactories().constFind(key);
    if (factory != pageFactories().constEnd()) {
        widget = (*factory)();
    } else {
        widget = new PlaceholderView(page::displayName(page));
    }
    pageCache().insert(key, widget);
    if (auto* pageView = dynamic_cast<IPageView*>(widget)) {
        pageView->onActivated();
    }
    return widget;
}

QWidget* PageFactory::resolveOverlay(OverlayKind kind)
{
    const int key = static_cast<int>(kind);
    if (QWidget* cached = overlayCache().value(key)) return cached;
    QWidget* widget = nullptr;
    const auto factory = overlayFactories().constFind(key);
    if (factory != overlayFactories().constEnd()) {
        widget = (*factory)();
    } else {
        QString title;
        switch (kind) {
        case OverlayKind::NowPlaying:
            title = QStringLiteral("正在播放");
            break;
        case OverlayKind::Queue:
            title = QStringLiteral("播放队列");
            break;
        case OverlayKind::Login:
            title = QStringLiteral("登录");
            break;
        }
        widget = new PlaceholderView(title);
    }
    overlayCache().insert(key, widget);
    return widget;
}

QList<Page> PageFactory::registeredPages()
{
    QList<Page> pages;
    for (auto iterator = pageFactories().constBegin(); iterator != pageFactories().constEnd(); ++iterator) {
        pages.append(static_cast<Page>(iterator.key()));
    }
    return pages;
}

QList<OverlayKind> PageFactory::registeredOverlays()
{
    QList<OverlayKind> overlays;
    for (auto iterator = overlayFactories().constBegin(); iterator != overlayFactories().constEnd(); ++iterator) {
        overlays.append(static_cast<OverlayKind>(iterator.key()));
    }
    return overlays;
}

void PageFactory::invalidate(Page page)
{
    const int key = static_cast<int>(page);
    if (QWidget* widget = pageCache().take(key)) {
        widget->deleteLater();
    }
}

void PageFactory::invalidateOverlay(OverlayKind kind)
{
    const int key = static_cast<int>(kind);
    if (QWidget* widget = overlayCache().take(key)) {
        widget->deleteLater();
    }
}

void PageFactory::clearAll()
{
    auto pages = std::move(pageCache());
    pageCache().clear();
    for (const QPointer<QWidget>& widget : pages) {
        if (widget) delete widget.data();
    }
    auto overlays = std::move(overlayCache());
    overlayCache().clear();
    for (const QPointer<QWidget>& widget : overlays) {
        if (widget) delete widget.data();
    }
}

} // namespace ct
