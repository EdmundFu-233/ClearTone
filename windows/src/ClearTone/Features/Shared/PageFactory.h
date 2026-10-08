#pragma once

#include "App/AppState.h"

#include <QHash>
#include <QWidget>

#include <functional>

namespace ct {

enum class OverlayKind {
    NowPlaying,
    Queue,
    Login,
};

class IPageView {
public:
    virtual ~IPageView() = default;
    virtual void onActivated() {}
};

class PageFactory {
public:
    using Factory = std::function<QWidget*()>;

    static void registerPage(Page page, Factory factory);
    static void registerOverlay(OverlayKind kind, Factory factory);
    static QWidget* resolve(Page page);
    static QWidget* resolveOverlay(OverlayKind kind);
    static void invalidate(Page page);
    static void invalidateOverlay(OverlayKind kind);

    // 内省（ViewSmoke 测试用）
    static QList<Page> registeredPages();
    static QList<OverlayKind> registeredOverlays();
};

} // namespace ct

#define CT_REGISTER_PAGE(pageEnum, Type)                                                          \
    namespace {                                                                                   \
    const bool ctRegisteredPage_##Type = [] {                                                     \
        ::ct::PageFactory::registerPage(pageEnum, [] { return static_cast<QWidget*>(new Type()); }); \
        return true;                                                                              \
    }();                                                                                          \
    }

#define CT_REGISTER_OVERLAY(kindEnum, Type)                                                       \
    namespace {                                                                                   \
    const bool ctRegisteredOverlay_##Type = [] {                                                  \
        ::ct::PageFactory::registerOverlay(kindEnum, [] { return static_cast<QWidget*>(new Type()); }); \
        return true;                                                                              \
    }();                                                                                          \
    }
