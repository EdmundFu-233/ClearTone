#include "Features/Profile/ProfileView.h"

#include "App/AppState.h"
#include "Core/Models/JsonHelpers.h"
#include "DesignSystem/CTTheme.h"
#include "DesignSystem/CoverImage.h"
#include "Features/Shared/PageFactory.h"
#include "Features/Shared/UIComponents.h"
#include "Playback/PlayerController.h"
#include "Providers/Netease/NeteaseProvider.h"
#include "Providers/Netease/NeteaseSocialProvider.h"

#include <QFont>
#include <QFrame>
#include <QGridLayout>
#include <QHBoxLayout>
#include <QLabel>
#include <QProgressBar>
#include <QPushButton>
#include <QScrollArea>
#include <QVBoxLayout>

#include <cmath>
#include <utility>

namespace ct {

namespace {

IMusicSocialProvider& socialProvider()
{
    auto* session = AppState::shared().social();
    if (auto* social = dynamic_cast<IMusicSocialProvider*>(session)) return *social;
    return NeteaseSocialProvider::shared();
}

void clearLayout(QLayout* layout)
{
    while (QLayoutItem* item = layout->takeAt(0)) {
        if (QWidget* widget = item->widget()) widget->deleteLater();
        if (QLayout* child = item->layout()) {
            clearLayout(child);
            child->deleteLater();
        }
        delete item;
    }
}

QFrame* card(QWidget* content)
{
    auto* frame = new QFrame();
    frame->setObjectName(QStringLiteral("ctCard"));
    frame->setStyleSheet(QStringLiteral("QFrame#ctCard { background: %1; border-radius: %2px; }")
                             .arg(CTColors::panel().name())
                             .arg(CTRadius::Large));
    auto* layout = new QVBoxLayout(frame);
    layout->setContentsMargins(CTSpacing::Lg, CTSpacing::Lg, CTSpacing::Lg, CTSpacing::Lg);
    layout->addWidget(content);
    return frame;
}

QWidget* statBlock(const QString& label, const QString& value)
{
    auto* panel = new QWidget();
    auto* layout = new QVBoxLayout(panel);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(2);
    auto* valueLabel = ui::titleLabel(value, CTTypography::Body, true);
    valueLabel->setStyleSheet(
        QStringLiteral("color: %1; font-weight: 500;").arg(CTColors::textPrimary().name()));
    layout->addWidget(valueLabel);
    layout->addWidget(ui::secondaryLabel(label));
    return panel;
}

QWidget* cardGrid(const QList<QWidget*>& cards, int columns)
{
    auto* container = new QWidget();
    auto* grid = new QGridLayout(container);
    grid->setContentsMargins(0, 0, 0, 0);
    grid->setHorizontalSpacing(CTSpacing::Lg);
    grid->setVerticalSpacing(CTSpacing::Lg);
    for (int index = 0; index < cards.size(); ++index) {
        grid->addWidget(cards[index], index / columns, index % columns, Qt::AlignTop | Qt::AlignLeft);
    }
    grid->setColumnStretch(columns, 1);
    return container;
}

QWidget* subscriptionGroup(const QString& title, QWidget* content)
{
    auto* panel = new QWidget();
    auto* layout = new QVBoxLayout(panel);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(CTSpacing::Md);
    layout->addWidget(ui::titleLabel(title, CTTypography::Body, true));
    layout->addWidget(content);
    return card(panel);
}

QWidget* makeRadioCard(const RadioStation& radio)
{
    auto* card = new ui::CardButton();
    card->setFixedWidth(160);
    auto* layout = new QVBoxLayout(card);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(6);

    auto* cover = new CoverImage(card);
    cover->setFixedSize(160, 160);
    cover->setCornerRadius(CTRadius::Medium);
    cover->setCoverURL(radio.coverURL, 320);
    layout->addWidget(cover, 0, Qt::AlignHCenter);

    auto* name = ui::titleElidedLabel(radio.name, CTTypography::Body, true);
    name->setMaximumWidth(160);
    layout->addWidget(name);
    layout->addWidget(ui::secondaryElidedLabel(QStringLiteral("%1 节目").arg(radio.programCount)));

    const QString id = radio.id;
    card->onClicked = [id] { AppState::shared().openRadio(id); };
    return card;
}

QString relativeTime(const QDateTime& date)
{
    if (!date.isValid()) return QString();
    const double seconds = date.msecsTo(QDateTime::currentDateTime()) / 1000.0;
    if (seconds < 60) return QStringLiteral("刚刚");
    if (seconds < 3600) return QStringLiteral("%1 分钟前").arg(static_cast<int>(seconds / 60));
    if (seconds < 86400) return QStringLiteral("%1 小时前").arg(static_cast<int>(seconds / 3600));
    if (seconds < 172800) return QStringLiteral("昨天");
    if (seconds < 604800) return QStringLiteral("%1 天前").arg(static_cast<int>(seconds / 86400));
    return date.toLocalTime().toString(QStringLiteral("yyyy-MM-dd"));
}

QString unknownUserMessage(const std::exception& error)
{
    return MusicException::unknown(QString::fromUtf8(error.what())).userFacingMessage();
}

} // namespace

ProfileView::ProfileView(QWidget* parent)
    : QWidget(parent)
{
    setObjectName(QStringLiteral("ctProfileView"));
    setStyleSheet(QStringLiteral("QWidget#ctProfileView { background: %1; }")
                      .arg(CTColors::background().name()));

    auto* root = new QVBoxLayout(this);
    root->setContentsMargins(0, 0, 0, 0);
    root->setSpacing(0);

    auto* titleStack = new QWidget(this);
    auto* titleLayout = new QVBoxLayout(titleStack);
    titleLayout->setContentsMargins(CTSpacing::Xl, CTSpacing::Xl, CTSpacing::Xl, CTSpacing::Lg);
    titleLayout->setSpacing(CTSpacing::Xs);
    titleLayout->addWidget(ui::titleLabel(QStringLiteral("我的"), CTTypography::PageTitle, true));
    m_subtitle = ui::secondaryLabel(QStringLiteral("听歌等级与记录。"));
    titleLayout->addWidget(m_subtitle);
    root->addWidget(titleStack);

    m_body = new QWidget();
    m_bodyLayout = new QVBoxLayout(m_body);
    m_bodyLayout->setContentsMargins(CTSpacing::Xl, 0, CTSpacing::Xl, CTSpacing::Xl);
    m_bodyLayout->setSpacing(CTSpacing::Xl);
    root->addWidget(ui::scrollWrapper(m_body), 1);

    m_lastDataContextKey = AppState::shared().dataContextKey();
    m_lastCanWrite = AppState::shared().canPerformWrite();
    m_appObserver = AppState::shared().changed.subscribe([this] { scheduleAppChange(); });
    m_contextObserver = AppState::shared().dataContextChanged.subscribe([this] { scheduleAppChange(); });
    render();
}

ProfileView::~ProfileView()
{
    *m_alive = false;
    AppState::shared().changed.unsubscribe(m_appObserver);
    AppState::shared().dataContextChanged.unsubscribe(m_contextObserver);
}

void ProfileView::showEvent(QShowEvent* event)
{
    QWidget::showEvent(event);
    m_isAttached = true;
    loadAll();
}

void ProfileView::hideEvent(QHideEvent* event)
{
    QWidget::hideEvent(event);
    m_isAttached = false;
}

void ProfileView::scheduleAppChange()
{
    if (m_appChangeScheduled) return;
    m_appChangeScheduled = true;
    QMetaObject::invokeMethod(
        this,
        [this] {
            m_appChangeScheduled = false;
            handleAppChange();
        },
        Qt::QueuedConnection);
}

void ProfileView::handleAppChange()
{
    const QString key = AppState::shared().dataContextKey();
    const bool canWrite = AppState::shared().canPerformWrite();
    if (key == m_lastDataContextKey && canWrite == m_lastCanWrite) return;
    m_lastDataContextKey = key;
    m_lastCanWrite = canWrite;
    if (m_isAttached) {
        loadAll();
    } else {
        render();
    }
}

void ProfileView::loadAll()
{
    if (!AppState::shared().canPerformWrite()) {
        render();
        return;
    }
    const quint64 token = ++m_loadToken;
    resetState();
    render();
    detach(loadLevelAsync(token));
    detach(loadCountsAsync(token));
    detach(loadRecordsAsync(token));
    detach(loadSubscriptionsAsync(token));
    detach(loadMyCommentsAsync(token));
}

void ProfileView::resetState()
{
    m_level.reset();
    m_loadingLevel = false;
    m_levelError.reset();
    m_signIn.reset();
    m_signingIn = false;
    m_records.clear();
    m_loadingRecords = false;
    m_recordsError.reset();
    m_counts.reset();
    m_loadingCounts = false;
    m_countsError.reset();
    m_subArtists.clear();
    m_subAlbums.clear();
    m_subRadios.clear();
    m_subPlaylists.clear();
    m_loadingSubscriptions = false;
    m_subscriptionsError.reset();
    m_myComments.clear();
    m_loadingMyComments = false;
    m_myCommentsError.reset();
}

Task<void> ProfileView::loadLevelAsync(quint64 token)
{
    auto alive = m_alive;
    m_loadingLevel = !m_level.has_value();
    m_levelError.reset();
    render();
    try {
        const UserLevelInfo loaded = co_await socialProvider().fetchUserLevel(CancellationToken::none());
        if (!*alive || m_loadToken != token) co_return;
        m_level = loaded;
    } catch (const MusicException& error) {
        if (!*alive || m_loadToken != token) co_return;
        m_levelError = error.userFacingMessage();
    } catch (const std::exception& error) {
        if (!*alive || m_loadToken != token) co_return;
        m_levelError = unknownUserMessage(error);
    }
    if (!*alive || m_loadToken != token) co_return;
    m_loadingLevel = false;
    render();
    co_return;
}

Task<void> ProfileView::loadCountsAsync(quint64 token)
{
    auto alive = m_alive;
    m_loadingCounts = !m_counts.has_value();
    m_countsError.reset();
    render();
    try {
        const QHash<QString, int> loaded = co_await socialProvider().fetchUserCounts(CancellationToken::none());
        if (!*alive || m_loadToken != token) co_return;
        m_counts = loaded;
    } catch (const MusicException& error) {
        if (!*alive || m_loadToken != token) co_return;
        m_countsError = error.userFacingMessage();
    } catch (const std::exception& error) {
        if (!*alive || m_loadToken != token) co_return;
        m_countsError = unknownUserMessage(error);
    }
    if (!*alive || m_loadToken != token) co_return;
    m_loadingCounts = false;
    render();
    co_return;
}

Task<void> ProfileView::loadRecordsAsync(quint64 token)
{
    auto alive = m_alive;
    m_loadingRecords = m_records.isEmpty();
    m_recordsError.reset();
    render();
    try {
        const QList<ListenRecord> loaded =
            co_await socialProvider().fetchListenRecords(m_recordsWeekly, CancellationToken::none());
        if (!*alive || m_loadToken != token) co_return;
        m_records = loaded;
    } catch (const MusicException& error) {
        if (!*alive || m_loadToken != token) co_return;
        m_recordsError = error.userFacingMessage();
    } catch (const std::exception& error) {
        if (!*alive || m_loadToken != token) co_return;
        m_recordsError = unknownUserMessage(error);
    }
    if (!*alive || m_loadToken != token) co_return;
    m_loadingRecords = false;
    render();
    co_return;
}

Task<void> ProfileView::loadSubscriptionsAsync(quint64 token)
{
    auto alive = m_alive;
    m_loadingSubscriptions = true;
    m_subscriptionsError.reset();
    render();

    QList<Artist> artists;
    QList<Album> albums;
    QList<RadioStation> radios;
    QList<Playlist> playlists;
    std::optional<QString> error;

    try {
        artists = co_await socialProvider().fetchSubscribedArtists(50, CancellationToken::none());
    } catch (const MusicException& exception) {
        error = error ? error : std::optional<QString>(exception.userFacingMessage());
    } catch (const std::exception& exception) {
        error = error ? error : std::optional<QString>(unknownUserMessage(exception));
    }
    try {
        albums = co_await socialProvider().fetchSubscribedAlbums(50, CancellationToken::none());
    } catch (const MusicException& exception) {
        error = error ? error : std::optional<QString>(exception.userFacingMessage());
    } catch (const std::exception& exception) {
        error = error ? error : std::optional<QString>(unknownUserMessage(exception));
    }
    try {
        radios = co_await socialProvider().fetchSubscribedRadios(30, CancellationToken::none());
    } catch (const MusicException& exception) {
        error = error ? error : std::optional<QString>(exception.userFacingMessage());
    } catch (const std::exception& exception) {
        error = error ? error : std::optional<QString>(unknownUserMessage(exception));
    }
    try {
        playlists = co_await socialProvider().fetchSubscribedPlaylists(50, CancellationToken::none());
    } catch (const MusicException& exception) {
        error = error ? error : std::optional<QString>(exception.userFacingMessage());
    } catch (const std::exception& exception) {
        error = error ? error : std::optional<QString>(unknownUserMessage(exception));
    }

    if (!*alive || m_loadToken != token) co_return;
    m_subArtists = artists;
    m_subAlbums = albums;
    m_subRadios = radios;
    m_subPlaylists = playlists;
    m_subscriptionsError = error;
    m_loadingSubscriptions = false;
    render();
    co_return;
}

Task<void> ProfileView::loadMyCommentsAsync(quint64 token)
{
    auto alive = m_alive;
    m_loadingMyComments = m_myComments.isEmpty();
    m_myCommentsError.reset();
    render();
    try {
        const QList<MyComment> loaded =
            co_await socialProvider().fetchMyComments(30, CancellationToken::none());
        if (!*alive || m_loadToken != token) co_return;
        m_myComments = loaded;
    } catch (const MusicException& error) {
        if (!*alive || m_loadToken != token) co_return;
        m_myCommentsError = error.userFacingMessage();
    } catch (const std::exception& error) {
        if (!*alive || m_loadToken != token) co_return;
        m_myCommentsError = unknownUserMessage(error);
    }
    if (!*alive || m_loadToken != token) co_return;
    m_loadingMyComments = false;
    render();
    co_return;
}

Task<void> ProfileView::openCommentSongAsync(QString songID)
{
    auto alive = m_alive;
    if (songID.isEmpty()) co_return;
    try {
        const QByteArray data = co_await NeteaseProvider::shared().request(QStringLiteral("/song/detail"),
            {{QStringLiteral("ids"), songID}}, NeteaseProvider::loadLoginCookie(), 300,
            QStringLiteral("GET"), true, CancellationToken::none());
        if (!*alive || !m_isAttached) co_return;
        const QJsonValue json = NeteaseProvider::parseJson(data);
        const QJsonValue songs = json::prop(json, QStringLiteral("songs"));
        if (!songs.isArray() || songs.toArray().isEmpty()) co_return;
        const std::optional<Song> song = NeteaseProvider::mapSong(songs.toArray().first());
        if (!song.has_value()) co_return;
        AppState::shared().openComments(*song);
    } catch (const MusicException&) {
    } catch (const std::exception&) {
    }
    co_return;
}

Task<void> ProfileView::changeRangeAsync(bool weekly)
{
    auto alive = m_alive;
    if (m_recordsWeekly == weekly) co_return;
    m_recordsWeekly = weekly;
    m_records.clear();
    render();
    co_await loadRecordsAsync(m_loadToken);
    if (!*alive) co_return;
    co_return;
}

Task<void> ProfileView::signInAsync()
{
    auto alive = m_alive;
    if (m_signingIn || m_signIn.has_value()) co_return;
    m_signingIn = true;
    render();
    try {
        const SignInResult result = co_await socialProvider().dailySignIn(CancellationToken::none());
        if (!*alive) co_return;
        m_signIn = result;
        if (result.isSuccess()) co_await loadLevelAsync(m_loadToken);
    } catch (const MusicException& error) {
        if (!*alive) co_return;
        m_signIn = SignInResult{SignInResult::Kind::Failed, 0, error.userFacingMessage()};
    } catch (const std::exception& error) {
        if (!*alive) co_return;
        m_signIn = SignInResult{SignInResult::Kind::Failed, 0, unknownUserMessage(error)};
    }
    if (!*alive) co_return;
    m_signingIn = false;
    render();
    co_return;
}

Task<void> ProfileView::logoutAsync()
{
    auto alive = m_alive;
    try {
        co_await AppState::shared().performLogout();
    } catch (const MusicException&) {
    }
    if (!*alive) co_return;
    resetState();
    m_lastDataContextKey = AppState::shared().dataContextKey();
    render();
    co_return;
}

void ProfileView::render()
{
    const AppState& app = AppState::shared();
    if (app.isLoggedIn()) {
        const std::optional<AccountInfo> account = app.account();
        m_subtitle->setText(account && !account->nickname.isEmpty() ? account->nickname
                                                                    : QStringLiteral("已登录"));
    } else {
        m_subtitle->setText(QStringLiteral("听歌等级与记录。"));
    }

    clearLayout(m_bodyLayout);
    if (!app.canPerformWrite()) {
        m_bodyLayout->addWidget(buildLoginRequired());
        m_bodyLayout->addStretch(1);
        return;
    }

    m_bodyLayout->addWidget(buildAccountCard());
    m_bodyLayout->addWidget(buildLevelCard());
    m_bodyLayout->addWidget(buildSignInCard());
    m_bodyLayout->addWidget(buildCountsCard());
    m_bodyLayout->addWidget(buildRecordsSection());
    m_bodyLayout->addWidget(buildSubscriptionsSection());
    m_bodyLayout->addWidget(buildMyCommentsSection());
    m_bodyLayout->addStretch(1);
}

QWidget* ProfileView::buildLoginRequired()
{
    auto* panel = new QWidget();
    auto* layout = new QVBoxLayout(panel);
    layout->setContentsMargins(0, 60, 0, 60);
    layout->setSpacing(CTSpacing::Md);
    layout->setAlignment(Qt::AlignCenter);

    auto* hint = new QLabel(QStringLiteral("登录后查看听歌等级与记录"));
    hint->setStyleSheet(QStringLiteral("color: %1;").arg(CTColors::textSecondary().name()));
    hint->setAlignment(Qt::AlignCenter);
    layout->addWidget(hint, 0, Qt::AlignHCenter);

    auto* login = ui::accentButton(QStringLiteral("去登录"));
    connect(login, &QPushButton::clicked, this, [] {
        AppState::shared().setIsLoginPresented(true);
    });
    layout->addWidget(login, 0, Qt::AlignHCenter);
    return panel;
}

QWidget* ProfileView::buildAccountCard()
{
    const std::optional<AccountInfo> account = AppState::shared().account();

    auto* content = new QWidget();
    auto* layout = new QHBoxLayout(content);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(CTSpacing::Lg);

    auto* avatar = new CoverImage(content);
    avatar->setFixedSize(64, 64);
    avatar->setCornerRadius(32);
    avatar->setCoverURL(account ? account->avatarURL : std::nullopt, 128);
    layout->addWidget(avatar);

    auto* info = new QWidget(content);
    auto* infoLayout = new QVBoxLayout(info);
    infoLayout->setContentsMargins(0, 0, 0, 0);
    infoLayout->setSpacing(2);

    auto* nameRow = new QWidget(info);
    auto* nameLayout = new QHBoxLayout(nameRow);
    nameLayout->setContentsMargins(0, 0, 0, 0);
    nameLayout->setSpacing(CTSpacing::Sm);
    auto* name = ui::titleElidedLabel(account && !account->nickname.isEmpty() ? account->nickname
                                                                              : QStringLiteral("已登录"),
        CTTypography::Body, true);
    nameLayout->addWidget(name);
    if (account && account->isVIP) {
        auto* vip = new QLabel(QStringLiteral("VIP"));
        vip->setStyleSheet(QStringLiteral("color: %1; font-size: 12px;").arg(CTColors::accent().name()));
        nameLayout->addWidget(vip);
    }
    nameLayout->addStretch(1);
    infoLayout->addWidget(nameRow);

    const QString userID = account ? account->userID : QString();
    infoLayout->addWidget(ui::secondaryLabel(
        userID.isEmpty() ? QString() : QStringLiteral("ID：%1").arg(userID)));
    layout->addWidget(info, 1);

    auto* logout = ui::ghostButton(QStringLiteral("退出登录"));
    connect(logout, &QPushButton::clicked, this, [this] { detach(logoutAsync()); });
    layout->addWidget(logout, 0, Qt::AlignVCenter);
    return card(content);
}

QWidget* ProfileView::buildLevelCard()
{
    auto* panel = new QWidget();
    auto* layout = new QVBoxLayout(panel);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(CTSpacing::Md);

    auto* header = new QWidget(panel);
    auto* headerLayout = new QHBoxLayout(header);
    headerLayout->setContentsMargins(0, 0, 0, 0);
    headerLayout->addWidget(ui::titleLabel(QStringLiteral("听歌等级"), CTTypography::SectionTitle, true));
    headerLayout->addStretch(1);
    if (m_loadingLevel) {
        auto* progress = new QProgressBar(header);
        progress->setRange(0, 0);
        progress->setTextVisible(false);
        progress->setFixedWidth(80);
        progress->setFixedHeight(4);
        headerLayout->addWidget(progress, 0, Qt::AlignVCenter);
    } else if (m_level.has_value()) {
        auto* level = new QLabel(QStringLiteral("Lv.%1").arg(m_level->level), header);
        level->setStyleSheet(QStringLiteral("color: %1; font-size: 22px;").arg(CTColors::accent().name()));
        headerLayout->addWidget(level, 0, Qt::AlignVCenter);
    }
    layout->addWidget(header);

    if (m_level.has_value()) {
        const UserLevelInfo& info = *m_level;
        auto* progress = new QProgressBar(panel);
        progress->setRange(0, 1000);
        progress->setValue(qBound(0, static_cast<int>(std::round(info.progressFraction() * 1000)), 1000));
        progress->setTextVisible(false);
        progress->setFixedHeight(4);
        layout->addWidget(progress);

        auto* stats = new QWidget(panel);
        auto* statsLayout = new QHBoxLayout(stats);
        statsLayout->setContentsMargins(0, 0, 0, 0);
        statsLayout->setSpacing(CTSpacing::Xl);
        statsLayout->addWidget(statBlock(QStringLiteral("累计听歌"),
            QStringLiteral("%1 首").arg(info.listenSongs)));
        statsLayout->addWidget(statBlock(QStringLiteral("累计天数"),
            QStringLiteral("%1 天").arg(info.listenDays)));
        statsLayout->addStretch(1);
        const QString hintText = info.nextLevelNeedLoginDays > 0
            ? QStringLiteral("再听 %1 天升级").arg(info.remainingLoginDays())
            : QStringLiteral("已是最高等级");
        statsLayout->addWidget(ui::secondaryLabel(hintText), 0, Qt::AlignVCenter);
        layout->addWidget(stats);
    } else if (m_levelError.has_value()) {
        auto* error = ui::secondaryLabel(*m_levelError);
        error->setWordWrap(true);
        layout->addWidget(error);
        auto* retry = ui::linkButton(QStringLiteral("重试"), [this] {
            const quint64 token = m_loadToken;
            detach(loadLevelAsync(token));
        });
        layout->addWidget(retry, 0, Qt::AlignLeft);
    }
    return card(panel);
}

QWidget* ProfileView::buildSignInCard()
{
    auto* content = new QWidget();
    auto* layout = new QHBoxLayout(content);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(CTSpacing::Lg);

    auto* icon = new QLabel(QStringLiteral("\uE8FB"), content);
    QFont iconFont(QStringLiteral("Segoe MDL2 Assets"));
    iconFont.setPixelSize(28);
    icon->setFont(iconFont);
    icon->setStyleSheet(QStringLiteral("color: %1;").arg(CTColors::accent().name()));
    layout->addWidget(icon, 0, Qt::AlignVCenter);

    auto* info = new QWidget(content);
    auto* infoLayout = new QVBoxLayout(info);
    infoLayout->setContentsMargins(0, 0, 0, 0);
    infoLayout->setSpacing(3);
    auto* title = ui::titleLabel(QStringLiteral("每日打卡"), CTTypography::Body, true);
    title->setStyleSheet(
        QStringLiteral("color: %1; font-weight: 500;").arg(CTColors::textPrimary().name()));
    infoLayout->addWidget(title);
    auto* subtitle = ui::secondaryLabel(signInSubtitle());
    subtitle->setWordWrap(true);
    infoLayout->addWidget(subtitle);
    layout->addWidget(info, 1);

    layout->addWidget(buildSignInButton(), 0, Qt::AlignVCenter);
    return card(content);
}

QString ProfileView::signInSubtitle() const
{
    if (m_signIn.has_value()) {
        switch (m_signIn->kind) {
        case SignInResult::Kind::Success:
            return QStringLiteral("打卡成功，获得 %1 成长值").arg(m_signIn->point);
        case SignInResult::Kind::AlreadySigned:
            return QStringLiteral("今天已经打过卡了");
        case SignInResult::Kind::Failed:
            return m_signIn->reason;
        }
    }
    return QStringLiteral("连续登录可提升听歌等级");
}

QWidget* ProfileView::buildSignInButton()
{
    if (m_signIn.has_value() && m_signIn->kind == SignInResult::Kind::Success) {
        auto* label = new QLabel(QStringLiteral("已打卡"));
        label->setStyleSheet(QStringLiteral("color: %1;").arg(CTColors::accent().name()));
        return label;
    }
    if (m_signIn.has_value() && m_signIn->kind == SignInResult::Kind::AlreadySigned) {
        auto* reload = ui::ghostButton(QStringLiteral("重新加载"));
        connect(reload, &QPushButton::clicked, this, [this] {
            const quint64 token = m_loadToken;
            detach(loadLevelAsync(token));
        });
        return reload;
    }
    auto* button = ui::accentButton(m_signingIn ? QStringLiteral("打卡中…") : QStringLiteral("打卡"));
    button->setEnabled(!m_signingIn && AppState::shared().canPerformWrite());
    connect(button, &QPushButton::clicked, this, [this] { detach(signInAsync()); });
    return button;
}

QWidget* ProfileView::buildCountsCard()
{
    auto* panel = new QWidget();
    auto* layout = new QVBoxLayout(panel);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(CTSpacing::Md);
    layout->addWidget(ui::titleLabel(QStringLiteral("收藏数量"), CTTypography::SectionTitle, true));

    if (m_counts.has_value()) {
        auto* grid = new QGridLayout();
        grid->setContentsMargins(0, 0, 0, 0);
        grid->setHorizontalSpacing(CTSpacing::Md);
        grid->setVerticalSpacing(CTSpacing::Sm);
        int index = 0;
        for (auto iterator = m_counts->constBegin(); iterator != m_counts->constEnd(); ++iterator) {
            auto* chip = new QWidget(panel);
            chip->setFixedWidth(96);
            auto* chipLayout = new QVBoxLayout(chip);
            chipLayout->setContentsMargins(0, 0, 0, 0);
            chipLayout->setSpacing(2);
            chipLayout->addWidget(ui::titleLabel(QString::number(iterator.value()), CTTypography::Body, true));
            chipLayout->addWidget(ui::secondaryLabel(iterator.key()));
            grid->addWidget(chip, index / 6, index % 6);
            ++index;
        }
        grid->setColumnStretch(6, 1);
        layout->addLayout(grid);
    } else if (m_loadingCounts) {
        auto* progress = new QProgressBar(panel);
        progress->setRange(0, 0);
        progress->setTextVisible(false);
        progress->setFixedWidth(160);
        progress->setFixedHeight(4);
        layout->addWidget(progress);
    } else if (m_countsError.has_value()) {
        auto* error = ui::secondaryLabel(*m_countsError);
        error->setWordWrap(true);
        layout->addWidget(error);
        layout->addWidget(ui::linkButton(QStringLiteral("重试"), [this] {
            const quint64 token = m_loadToken;
            detach(loadCountsAsync(token));
        }), 0, Qt::AlignLeft);
    }
    return card(panel);
}

QWidget* ProfileView::buildRecordsSection()
{
    auto* section = new QWidget();
    auto* layout = new QVBoxLayout(section);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(CTSpacing::Md);

    auto* header = new QWidget(section);
    auto* headerLayout = new QHBoxLayout(header);
    headerLayout->setContentsMargins(0, 0, 0, 0);
    headerLayout->addWidget(ui::titleLabel(QStringLiteral("听歌排行"), CTTypography::SectionTitle, true));
    headerLayout->addStretch(1);

    auto makeRange = [this](const QString& text, bool weekly) {
        auto* button = ui::ghostButton(text);
        if (m_recordsWeekly == weekly) {
            button->setStyleSheet(QStringLiteral(
                "QPushButton { background: %1; color: white; border: none; border-radius: 6px; "
                "padding: 6px 16px; font-weight: 600; }")
                                      .arg(CTColors::accent().name()));
        }
        connect(button, &QPushButton::clicked, this, [this, weekly] {
            detach(changeRangeAsync(weekly));
        });
        return button;
    };
    headerLayout->addWidget(makeRange(QStringLiteral("全部"), false));
    headerLayout->addWidget(makeRange(QStringLiteral("最近一周"), true));
    if (!m_records.isEmpty()) {
        auto* playAll = ui::ghostButton(QStringLiteral("播放全部"));
        connect(playAll, &QPushButton::clicked, this, [this] {
            QList<Song> songs;
            for (const ListenRecord& record : std::as_const(m_records)) songs.append(record.song);
            PlayerController::shared().playSongs(songs, 0);
        });
        headerLayout->addWidget(playAll);
    }
    layout->addWidget(header);

    if (m_loadingRecords && m_records.isEmpty()) {
        layout->addWidget(ui::statusPanel(QStringLiteral("加载中…"), true));
    } else if (m_recordsError.has_value()) {
        layout->addWidget(ui::errorPanel(*m_recordsError, [this] {
            const quint64 token = m_loadToken;
            detach(loadRecordsAsync(token));
        }));
    } else if (m_records.isEmpty()) {
        layout->addWidget(ui::statusPanel(QStringLiteral("暂无内容"), false));
    } else {
        layout->addWidget(buildRecordList());
    }
    return section;
}

QWidget* ProfileView::buildRecordList()
{
    auto* list = new SongListView();
    QList<Song> songs;
    for (const ListenRecord& record : std::as_const(m_records)) songs.append(record.song);
    list->setSongs(songs);
    list->setShowIndex(false);
    list->setRowHeight(52);
    return list;
}

QWidget* ProfileView::buildSubscriptionsSection()
{
    auto* section = new QWidget();
    auto* layout = new QVBoxLayout(section);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(CTSpacing::Lg);
    layout->addWidget(ui::titleLabel(QStringLiteral("我的收藏"), CTTypography::SectionTitle, true));

    const bool empty = m_subArtists.isEmpty() && m_subAlbums.isEmpty() && m_subRadios.isEmpty()
        && m_subPlaylists.isEmpty();
    if (m_loadingSubscriptions && empty) {
        layout->addWidget(ui::statusPanel(QStringLiteral("加载中…"), true));
        return section;
    }
    if (empty) {
        if (m_subscriptionsError.has_value()) {
            layout->addWidget(ui::errorPanel(*m_subscriptionsError, [this] {
                const quint64 token = m_loadToken;
                detach(loadSubscriptionsAsync(token));
            }));
        } else {
            layout->addWidget(ui::statusPanel(QStringLiteral("暂无内容"), false));
        }
        return section;
    }

    if (!m_subArtists.isEmpty()) {
        QList<QWidget*> cards;
        for (const Artist& artist : std::as_const(m_subArtists)) {
            cards.append(ui::artistCard(artist, [](const Artist& item) {
                AppState::shared().openArtist(item.id);
            }));
        }
        layout->addWidget(subscriptionGroup(QStringLiteral("关注的歌手"), cardGrid(cards, 4)));
    }
    if (!m_subAlbums.isEmpty()) {
        QList<QWidget*> cards;
        for (const Album& album : std::as_const(m_subAlbums)) {
            cards.append(ui::albumCard(album, [](const Album& item) {
                AppState::shared().openAlbum(item.id);
            }));
        }
        layout->addWidget(subscriptionGroup(QStringLiteral("收藏的专辑"), cardGrid(cards, 4)));
    }
    if (!m_subRadios.isEmpty()) {
        QList<QWidget*> cards;
        for (const RadioStation& radio : std::as_const(m_subRadios)) {
            cards.append(makeRadioCard(radio));
        }
        layout->addWidget(subscriptionGroup(QStringLiteral("收藏的电台"), cardGrid(cards, 4)));
    }
    if (!m_subPlaylists.isEmpty()) {
        QList<QWidget*> cards;
        for (const Playlist& playlist : std::as_const(m_subPlaylists)) {
            cards.append(ui::playlistCard(playlist, [](const Playlist& item) {
                AppState::shared().openPlaylist(item.id);
            }));
        }
        layout->addWidget(subscriptionGroup(QStringLiteral("收藏的歌单"), cardGrid(cards, 4)));
    }

    if (m_subscriptionsError.has_value()) {
        auto* error = ui::secondaryLabel(*m_subscriptionsError);
        error->setWordWrap(true);
        layout->addWidget(error);
    }
    return section;
}

QWidget* ProfileView::buildMyCommentsSection()
{
    auto* section = new QWidget();
    auto* layout = new QVBoxLayout(section);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(CTSpacing::Md);
    layout->addWidget(ui::titleLabel(QStringLiteral("我的评论"), CTTypography::SectionTitle, true));

    if (m_loadingMyComments && m_myComments.isEmpty()) {
        layout->addWidget(ui::statusPanel(QStringLiteral("加载中…"), true));
        return section;
    }
    if (m_myCommentsError.has_value()) {
        layout->addWidget(ui::errorPanel(*m_myCommentsError, [this] {
            const quint64 token = m_loadToken;
            detach(loadMyCommentsAsync(token));
        }));
        return section;
    }
    if (m_myComments.isEmpty()) {
        layout->addWidget(ui::statusPanel(QStringLiteral("暂无内容"), false));
        return section;
    }

    auto* list = new QWidget();
    auto* listLayout = new QVBoxLayout(list);
    listLayout->setContentsMargins(0, 0, 0, 0);
    listLayout->setSpacing(CTSpacing::Xs);
    for (const MyComment& comment : std::as_const(m_myComments)) {
        auto* row = new QWidget();
        auto* rowLayout = new QVBoxLayout(row);
        rowLayout->setContentsMargins(CTSpacing::Lg, CTSpacing::Sm, CTSpacing::Lg, CTSpacing::Sm);
        rowLayout->setSpacing(CTSpacing::Xs);

        auto* top = new QWidget(row);
        auto* topLayout = new QHBoxLayout(top);
        topLayout->setContentsMargins(0, 0, 0, 0);
        topLayout->setSpacing(CTSpacing::Sm);
        auto* kind = new QLabel(myCommentResourceKind::label(comment.resourceKind));
        kind->setStyleSheet(
            QStringLiteral("color: %1; font-size: 12px;").arg(CTColors::accent().name()));
        topLayout->addWidget(kind);
        topLayout->addWidget(ui::secondaryLabel(relativeTime(comment.time)));
        if (comment.likedCount > 0) {
            topLayout->addWidget(ui::secondaryLabel(QStringLiteral("%1 赞").arg(comment.likedCount)));
        }
        topLayout->addStretch(1);
        rowLayout->addWidget(top);

        if (comment.repliedNickname.has_value()) {
            auto* replied = ui::secondaryLabel(QStringLiteral("回复 @%1：%2")
                                                   .arg(comment.repliedNickname.value_or(QString()),
                                                       comment.repliedContent.value_or(QString())));
            replied->setWordWrap(true);
            replied->setMaximumWidth(720);
            rowLayout->addWidget(replied);
        }

        auto* content = new QLabel(comment.content);
        content->setWordWrap(true);
        content->setMaximumWidth(720);
        content->setStyleSheet(QStringLiteral("color: %1;").arg(CTColors::textPrimary().name()));
        rowLayout->addWidget(content);

        const bool navigable = myCommentResourceKind::isNavigable(comment.resourceKind)
            && comment.resourceID.has_value();
        if (navigable) {
            auto* button = new ui::CardButton();
            auto* buttonLayout = new QVBoxLayout(button);
            buttonLayout->setContentsMargins(0, 0, 0, 0);
            buttonLayout->addWidget(row);
            const MyComment copy = comment;
            button->onClicked = [this, copy] {
                switch (copy.resourceKind) {
                case MyCommentResourceKind::Song:
                    detach(openCommentSongAsync(copy.resourceID.value_or(QString())));
                    break;
                case MyCommentResourceKind::Playlist:
                    AppState::shared().openPlaylist(copy.resourceID.value_or(QString()));
                    break;
                case MyCommentResourceKind::Album:
                    AppState::shared().openAlbum(copy.resourceID.value_or(QString()));
                    break;
                case MyCommentResourceKind::Radio:
                    AppState::shared().openRadio(copy.resourceID.value_or(QString()));
                    break;
                default:
                    break;
                }
            };
            listLayout->addWidget(button);
        } else {
            listLayout->addWidget(row);
        }
    }
    layout->addWidget(card(list));
    return section;
}

CT_REGISTER_PAGE(Page::Profile, ProfileView);

} // namespace ct
