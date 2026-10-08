#include "Features/Library/MyMusicView.h"

#include "App/AppState.h"
#include "DesignSystem/CTTheme.h"
#include "DesignSystem/CoverImage.h"
#include "DesignSystem/L10n.h"
#include "Features/Shared/PageFactory.h"
#include "Features/Shared/UIComponents.h"
#include "Providers/Netease/NeteaseProvider.h"
#include "Providers/Netease/NeteaseSocialProvider.h"

#include <QAction>
#include <QCheckBox>
#include <QDialog>
#include <QGridLayout>
#include <QHBoxLayout>
#include <QLabel>
#include <QLineEdit>
#include <QMenu>
#include <QPushButton>
#include <QScrollArea>
#include <QVBoxLayout>

#include <utility>

namespace ct {

namespace {

IMusicSocialProvider& socialProvider()
{
    auto* session = AppState::shared().social();
    if (auto* social = dynamic_cast<IMusicSocialProvider*>(session)) return *social;
    return NeteaseSocialProvider::shared();
}

QString unknownUserMessage(const std::exception& error)
{
    return MusicException::unknown(QString::fromUtf8(error.what())).userFacingMessage();
}

QString writeError()
{
    const QString message = AppState::shared().lastWriteError();
    return message.isEmpty() ? QStringLiteral("操作失败") : message;
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

class PlaylistNameDialog : public QDialog {
public:
    PlaylistNameDialog(const QString& title, const QString& initial, bool allowPrivate,
        QWidget* parent = nullptr)
        : QDialog(parent)
    {
        setWindowTitle(title);
        setModal(true);
        setMinimumWidth(380);
        auto* layout = new QVBoxLayout(this);
        layout->setContentsMargins(CTSpacing::Xl, CTSpacing::Xl, CTSpacing::Xl, CTSpacing::Xl);
        layout->setSpacing(CTSpacing::Lg);
        layout->addWidget(ui::titleLabel(title, CTTypography::SectionTitle, true));

        m_box = new QLineEdit(initial, this);
        m_box->setPlaceholderText(QStringLiteral("歌单名称"));
        m_box->setMaxLength(40);
        layout->addWidget(m_box);

        m_private = new QCheckBox(QStringLiteral("隐私歌单（不公开显示）"), this);
        m_private->setVisible(allowPrivate);
        layout->addWidget(m_private);

        m_error = new QLabel(this);
        m_error->setWordWrap(true);
        m_error->setStyleSheet(QStringLiteral("color: %1;").arg(CTColors::accent().name()));
        m_error->setVisible(false);
        layout->addWidget(m_error);

        auto* buttons = new QWidget(this);
        auto* buttonLayout = new QHBoxLayout(buttons);
        buttonLayout->setContentsMargins(0, 0, 0, 0);
        buttonLayout->setSpacing(CTSpacing::Sm);
        buttonLayout->addStretch(1);

        auto* cancel = ui::ghostButton(L10n::Common::Cancel);
        connect(cancel, &QPushButton::clicked, this, &QDialog::reject);
        buttonLayout->addWidget(cancel);

        m_confirm = ui::accentButton(title);
        connect(m_confirm, &QPushButton::clicked, this, [this] {
            if (onConfirm) onConfirm();
        });
        buttonLayout->addWidget(m_confirm);
        layout->addWidget(buttons);

        connect(m_box, &QLineEdit::returnPressed, this, [this] {
            if (onConfirm) onConfirm();
        });
        m_box->setFocus();
    }

    QString name() const { return m_box->text().trimmed(); }
    bool isPrivate() const { return m_private->isChecked(); }

    void setBusy(bool busy)
    {
        m_confirm->setEnabled(!busy);
        m_box->setEnabled(!busy);
    }

    void showError(const QString& message)
    {
        m_error->setText(message);
        m_error->setVisible(true);
    }

    std::function<void()> onConfirm;

private:
    QLineEdit* m_box = nullptr;
    QCheckBox* m_private = nullptr;
    QLabel* m_error = nullptr;
    QPushButton* m_confirm = nullptr;
};

class ConfirmDialog : public QDialog {
public:
    ConfirmDialog(const QString& title, const QString& message, const QString& confirmText,
        QWidget* parent = nullptr)
        : QDialog(parent)
    {
        setWindowTitle(title);
        setModal(true);
        setMinimumWidth(360);
        auto* layout = new QVBoxLayout(this);
        layout->setContentsMargins(CTSpacing::Xl, CTSpacing::Xl, CTSpacing::Xl, CTSpacing::Xl);
        layout->setSpacing(CTSpacing::Lg);
        layout->addWidget(ui::titleLabel(title, CTTypography::SectionTitle, true));

        auto* text = ui::secondaryLabel(message);
        text->setWordWrap(true);
        layout->addWidget(text);

        m_error = new QLabel(this);
        m_error->setWordWrap(true);
        m_error->setStyleSheet(QStringLiteral("color: %1;").arg(CTColors::accent().name()));
        m_error->setVisible(false);
        layout->addWidget(m_error);

        auto* buttons = new QWidget(this);
        auto* buttonLayout = new QHBoxLayout(buttons);
        buttonLayout->setContentsMargins(0, 0, 0, 0);
        buttonLayout->setSpacing(CTSpacing::Sm);
        buttonLayout->addStretch(1);

        auto* cancel = ui::ghostButton(L10n::Common::Cancel);
        connect(cancel, &QPushButton::clicked, this, &QDialog::reject);
        buttonLayout->addWidget(cancel);

        m_confirm = ui::ghostButton(confirmText);
        m_confirm->setStyleSheet(
            QStringLiteral("QPushButton { background: %1; color: white; border: none; "
                           "border-radius: 6px; padding: 6px 16px; font-weight: 600; }")
                .arg(CTColors::accent().name()));
        connect(m_confirm, &QPushButton::clicked, this, [this] {
            if (onConfirm) onConfirm();
        });
        buttonLayout->addWidget(m_confirm);
        layout->addWidget(buttons);
    }

    void setBusy(bool busy) { m_confirm->setEnabled(!busy); }

    void showError(const QString& message)
    {
        m_error->setText(message);
        m_error->setVisible(true);
    }

    std::function<void()> onConfirm;

private:
    QLabel* m_error = nullptr;
    QPushButton* m_confirm = nullptr;
};

} // namespace

MyMusicView::MyMusicView(QWidget* parent)
    : QWidget(parent)
{
    setObjectName(QStringLiteral("ctMyMusicView"));
    setStyleSheet(QStringLiteral("QWidget#ctMyMusicView { background: %1; }")
                      .arg(CTColors::background().name()));

    auto* root = new QVBoxLayout(this);
    root->setContentsMargins(0, 0, 0, 0);
    root->setSpacing(0);

    auto* titleStack = new QWidget(this);
    auto* titleLayout = new QVBoxLayout(titleStack);
    titleLayout->setContentsMargins(0, 0, 0, 0);
    titleLayout->setSpacing(CTSpacing::Xs);
    titleLayout->addWidget(ui::titleLabel(QStringLiteral("我的音乐"), CTTypography::PageTitle, true));
    m_subtitle = ui::secondaryLabel(QStringLiteral("收藏的旋律，都在这里。"));
    titleLayout->addWidget(m_subtitle);

    m_createButton = ui::accentButton(QStringLiteral("新建歌单"));
    connect(m_createButton, &QPushButton::clicked, this, [this] { showCreateDialog(); });

    auto* header = new QWidget(this);
    auto* headerLayout = new QHBoxLayout(header);
    headerLayout->setContentsMargins(CTSpacing::Xl, CTSpacing::Xl, CTSpacing::Xl, CTSpacing::Lg);
    headerLayout->addWidget(titleStack);
    headerLayout->addStretch(1);
    headerLayout->addWidget(m_createButton, 0, Qt::AlignVCenter);
    root->addWidget(header);

    m_body = new QWidget();
    m_bodyLayout = new QVBoxLayout(m_body);
    m_bodyLayout->setContentsMargins(CTSpacing::Xl, 0, CTSpacing::Xl, CTSpacing::Xl);
    m_bodyLayout->setSpacing(CTSpacing::Xl);
    root->addWidget(ui::scrollWrapper(m_body), 1);

    const AppState& app = AppState::shared();
    m_lastDataContextKey = app.dataContextKey();
    m_lastSignature = signature();
    m_appObserver = AppState::shared().changed.subscribe([this] { scheduleAppChange(); });
    m_contextObserver = AppState::shared().dataContextChanged.subscribe([this] { scheduleAppChange(); });
    render();
}

MyMusicView::~MyMusicView()
{
    *m_alive = false;
    AppState::shared().changed.unsubscribe(m_appObserver);
    AppState::shared().dataContextChanged.unsubscribe(m_contextObserver);
}

void MyMusicView::showEvent(QShowEvent* event)
{
    QWidget::showEvent(event);
    if (m_hasLoaded) return;
    m_hasLoaded = true;
    detach(loadAsync());
}

QString MyMusicView::signature() const
{
    const AppState& app = AppState::shared();
    return QStringLiteral("%1|%2|%3|%4|%5|%6")
        .arg(app.dataContextKey())
        .arg(app.likesVersion())
        .arg(app.userPlaylists().size())
        .arg(app.isLoadingUserPlaylists() ? 1 : 0)
        .arg(app.needsReLogin() ? 1 : 0)
        .arg(app.canPerformWrite() ? 1 : 0);
}

void MyMusicView::scheduleAppChange()
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

void MyMusicView::handleAppChange()
{
    const QString key = AppState::shared().dataContextKey();
    const QString current = signature();
    if (key == m_lastDataContextKey && current == m_lastSignature) return;
    const bool contextChanged = key != m_lastDataContextKey;
    m_lastDataContextKey = key;
    m_lastSignature = current;
    if (contextChanged) {
        m_hasLoaded = true;
        detach(loadAsync());
    } else {
        render();
    }
}

Task<void> MyMusicView::loadAsync()
{
    auto alive = m_alive;
    const quint64 token = ++m_loadToken;
    try {
        co_await AppState::shared().loadLikedSongs();
    } catch (const std::exception&) {
    }
    if (!*alive || token != m_loadToken) co_return;
    try {
        co_await AppState::shared().loadUserPlaylists();
    } catch (const std::exception&) {
    }
    if (!*alive || token != m_loadToken) co_return;
    co_await loadSubscriptionsAsync(token);
    if (!*alive || token != m_loadToken) co_return;
    render();
    co_return;
}

Task<void> MyMusicView::loadSubscriptionsAsync(quint64 token)
{
    auto alive = m_alive;
    if (!AppState::shared().canPerformWrite()) {
        m_subArtists.clear();
        m_subAlbums.clear();
        m_subRadios.clear();
        m_subscriptionsError.reset();
        m_loadingSubscriptions = false;
        if (*alive && token == m_loadToken) render();
        co_return;
    }

    m_loadingSubscriptions = true;
    m_subscriptionsError.reset();
    render();

    QList<Artist> artists;
    QList<Album> albums;
    QList<RadioStation> radios;
    std::optional<QString> error;

    try {
        artists = co_await socialProvider().fetchSubscribedArtists(50, CancellationToken::none());
    } catch (const MusicException& exception) {
        error = exception.userFacingMessage();
    } catch (const std::exception& exception) {
        error = unknownUserMessage(exception);
    }
    if (!*alive || token != m_loadToken) co_return;

    try {
        albums = co_await socialProvider().fetchSubscribedAlbums(50, CancellationToken::none());
    } catch (const MusicException& exception) {
        if (!error.has_value()) error = exception.userFacingMessage();
    } catch (const std::exception& exception) {
        if (!error.has_value()) error = unknownUserMessage(exception);
    }
    if (!*alive || token != m_loadToken) co_return;

    try {
        radios = co_await socialProvider().fetchSubscribedRadios(30, CancellationToken::none());
    } catch (const MusicException& exception) {
        if (!error.has_value()) error = exception.userFacingMessage();
    } catch (const std::exception& exception) {
        if (!error.has_value()) error = unknownUserMessage(exception);
    }
    if (!*alive || token != m_loadToken) co_return;

    m_subArtists = artists;
    m_subAlbums = albums;
    m_subRadios = radios;
    m_subscriptionsError = error;
    m_loadingSubscriptions = false;
    render();
    co_return;
}

Task<void> MyMusicView::submitCreateAsync(QPointer<QDialog> dialog)
{
    auto alive = m_alive;
    auto* nameDialog = static_cast<PlaylistNameDialog*>(dialog.data());
    if (nameDialog == nullptr) co_return;
    const QString name = nameDialog->name();
    if (name.isEmpty()) co_return;
    nameDialog->setBusy(true);
    const std::optional<Playlist> created
        = co_await AppState::shared().createPlaylist(name, nameDialog->isPrivate());
    if (!*alive || dialog.isNull()) co_return;
    if (created.has_value()) {
        dialog->accept();
    } else {
        nameDialog->setBusy(false);
        nameDialog->showError(writeError());
    }
    co_return;
}

Task<void> MyMusicView::submitRenameAsync(QPointer<QDialog> dialog, Playlist playlist)
{
    auto alive = m_alive;
    auto* nameDialog = static_cast<PlaylistNameDialog*>(dialog.data());
    if (nameDialog == nullptr) co_return;
    const QString name = nameDialog->name();
    if (name.isEmpty()) co_return;
    nameDialog->setBusy(true);
    const bool renamed = co_await AppState::shared().renamePlaylist(playlist, name);
    if (!*alive || dialog.isNull()) co_return;
    if (renamed) {
        dialog->accept();
    } else {
        nameDialog->setBusy(false);
        nameDialog->showError(writeError());
    }
    co_return;
}

Task<void> MyMusicView::submitDeleteAsync(QPointer<QDialog> dialog, Playlist playlist)
{
    auto alive = m_alive;
    auto* confirmDialog = static_cast<ConfirmDialog*>(dialog.data());
    if (confirmDialog == nullptr) co_return;
    confirmDialog->setBusy(true);
    const bool deleted = co_await AppState::shared().deletePlaylist(playlist);
    if (!*alive || dialog.isNull()) co_return;
    if (deleted) {
        dialog->accept();
    } else {
        confirmDialog->setBusy(false);
        confirmDialog->showError(writeError());
    }
    co_return;
}

void MyMusicView::showCreateDialog()
{
    auto* dialog = new PlaylistNameDialog(QStringLiteral("新建歌单"), QString(), true, this);
    dialog->setAttribute(Qt::WA_DeleteOnClose);
    const QPointer<QDialog> guard(dialog);
    dialog->onConfirm = [this, guard] { detach(submitCreateAsync(guard)); };
    AppState::shared().clearWriteError();
    dialog->open();
}

void MyMusicView::showRenameDialog(const Playlist& playlist)
{
    auto* dialog = new PlaylistNameDialog(
        QStringLiteral("重命名歌单"), playlist.name, false, this);
    dialog->setAttribute(Qt::WA_DeleteOnClose);
    const QPointer<QDialog> guard(dialog);
    dialog->onConfirm = [this, guard, playlist] { detach(submitRenameAsync(guard, playlist)); };
    AppState::shared().clearWriteError();
    dialog->open();
}

void MyMusicView::showDeleteDialog(const Playlist& playlist)
{
    auto* dialog = new ConfirmDialog(QStringLiteral("删除歌单"),
        QStringLiteral("确定要删除「%1」吗？此操作不可撤销。").arg(playlist.name),
        QStringLiteral("删除"), this);
    dialog->setAttribute(Qt::WA_DeleteOnClose);
    const QPointer<QDialog> guard(dialog);
    dialog->onConfirm = [this, guard, playlist] { detach(submitDeleteAsync(guard, playlist)); };
    AppState::shared().clearWriteError();
    dialog->open();
}

void MyMusicView::render()
{
    const AppState& app = AppState::shared();
    const bool loggedIn = app.isLoggedIn();
    const QList<Playlist>& playlists = app.userPlaylists();

    m_createButton->setVisible(app.canPerformWrite());
    m_subtitle->setText(loggedIn
            ? (playlists.isEmpty()
                      ? QStringLiteral("收藏的旋律，都在这里。")
                      : QStringLiteral("%1 个歌单 · %2 首喜欢")
                            .arg(playlists.size())
                            .arg(app.likedSongs().size()))
            : QStringLiteral("收藏的旋律，都在这里。"));

    while (QLayoutItem* item = m_bodyLayout->takeAt(0)) {
        if (QWidget* widget = item->widget()) widget->deleteLater();
        if (QLayout* child = item->layout()) {
            child->deleteLater();
        }
        delete item;
    }

    if (!loggedIn) {
        m_bodyLayout->addWidget(buildLoginRequired());
        m_bodyLayout->addStretch(1);
        return;
    }
    if (app.isLoadingUserPlaylists() && playlists.isEmpty()) {
        m_bodyLayout->addWidget(ui::statusPanel(QStringLiteral("加载中…"), true));
        m_bodyLayout->addStretch(1);
        return;
    }
    if (playlists.isEmpty()) {
        m_bodyLayout->addWidget(ui::statusPanel(QStringLiteral("还没有创建歌单"), false));
        if (app.canPerformWrite()) {
            auto* create = ui::accentButton(QStringLiteral("新建歌单"));
            connect(create, &QPushButton::clicked, this, [this] { showCreateDialog(); });
            m_bodyLayout->addWidget(create, 0, Qt::AlignHCenter);
        }
        m_bodyLayout->addStretch(1);
        return;
    }

    QList<QWidget*> cards;
    cards.append(buildLikedCard());
    for (const Playlist& playlist : playlists) cards.append(buildPlaylistCard(playlist));
    m_bodyLayout->addWidget(cardGrid(cards, 4));
    m_bodyLayout->addWidget(buildRecentEntry());
    if (QWidget* subscriptions = buildSubscriptionsSection()) {
        m_bodyLayout->addWidget(subscriptions);
    }
    m_bodyLayout->addStretch(1);
}

QWidget* MyMusicView::buildLoginRequired()
{
    auto* panel = new QWidget();
    auto* layout = new QVBoxLayout(panel);
    layout->setContentsMargins(0, 60, 0, 60);
    layout->setSpacing(CTSpacing::Md);
    layout->setAlignment(Qt::AlignCenter);

    const bool reLogin = AppState::shared().needsReLogin();
    auto* hint = ui::secondaryLabel(reLogin ? QStringLiteral("登录状态已失效，请重新登录")
                                            : QStringLiteral("登录后查看我的音乐"));
    hint->setAlignment(Qt::AlignCenter);
    layout->addWidget(hint, 0, Qt::AlignHCenter);

    auto* login = ui::accentButton(QStringLiteral("去登录"));
    connect(login, &QPushButton::clicked, this, [] {
        AppState::shared().setIsLoginPresented(true);
    });
    layout->addWidget(login, 0, Qt::AlignHCenter);
    return panel;
}

QWidget* MyMusicView::buildLikedCard()
{
    auto* card = new ui::CardButton();
    card->setFixedWidth(160);
    auto* layout = new QVBoxLayout(card);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(CTSpacing::Sm);

    auto* cover = new QLabel(QStringLiteral("♥"), card);
    cover->setFixedSize(160, 160);
    cover->setAlignment(Qt::AlignCenter);
    cover->setStyleSheet(QStringLiteral(
        "background: qlineargradient(x1:0, y1:0, x2:1, y2:1, stop:0 #D966C6, stop:1 #5A7BE0); "
        "border-radius: %1px; color: white; font-size: 48px;")
                             .arg(CTRadius::Medium));
    layout->addWidget(cover, 0, Qt::AlignHCenter);

    layout->addWidget(ui::titleLabel(QStringLiteral("我喜欢的音乐"), CTTypography::Body, true));
    layout->addWidget(ui::secondaryLabel(
        QStringLiteral("%1 首").arg(AppState::shared().likedSongs().size())));

    card->onClicked = [] { AppState::shared().switchToTopLevel(Page::Liked); };
    return card;
}

QWidget* MyMusicView::buildPlaylistCard(const Playlist& playlist)
{
    auto* card = ui::playlistCard(playlist, [](const Playlist& item) {
        AppState::shared().openPlaylist(item.id);
    });
    const Playlist copy = playlist;
    card->setContextMenuPolicy(Qt::CustomContextMenu);
    connect(card, &QWidget::customContextMenuRequested, this, [this, card, copy](const QPoint& position) {
        QMenu menu(card);
        menu.addAction(QStringLiteral("打开"), [copy] { AppState::shared().openPlaylist(copy.id); });
        const bool canWrite = AppState::shared().canPerformWrite();
        QAction* rename = menu.addAction(QStringLiteral("重命名"), [this, copy] { showRenameDialog(copy); });
        QAction* remove = menu.addAction(QStringLiteral("删除"), [this, copy] { showDeleteDialog(copy); });
        rename->setEnabled(canWrite);
        remove->setEnabled(canWrite);
        menu.exec(card->mapToGlobal(position));
    });
    return card;
}

QWidget* MyMusicView::buildRecentEntry()
{
    auto* card = new ui::CardButton();
    auto* layout = new QHBoxLayout(card);
    layout->setContentsMargins(CTSpacing::Lg, CTSpacing::Md, CTSpacing::Lg, CTSpacing::Md);
    layout->setSpacing(CTSpacing::Md);
    layout->addWidget(ui::titleLabel(QStringLiteral("最近播放"), CTTypography::Body, true));
    layout->addWidget(ui::secondaryLabel(QStringLiteral("查看最近听过的歌曲")));
    layout->addStretch(1);
    layout->addWidget(ui::secondaryLabel(QStringLiteral("›")));
    card->onClicked = [] { AppState::shared().switchToTopLevel(Page::Recent); };
    return card;
}

QWidget* MyMusicView::buildSubscriptionsSection()
{
    if (!AppState::shared().canPerformWrite()) return nullptr;

    auto* section = new QWidget();
    auto* layout = new QVBoxLayout(section);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(CTSpacing::Lg);
    layout->addWidget(ui::titleLabel(QStringLiteral("我的收藏"), CTTypography::SectionTitle, true));

    const bool empty
        = m_subArtists.isEmpty() && m_subAlbums.isEmpty() && m_subRadios.isEmpty();
    if (m_loadingSubscriptions && empty) {
        layout->addWidget(ui::statusPanel(QStringLiteral("加载中…"), true));
        return section;
    }
    if (empty) {
        if (m_subscriptionsError.has_value()) {
            layout->addWidget(ui::errorPanel(*m_subscriptionsError,
                [this] { detach(loadSubscriptionsAsync(m_loadToken)); }));
        } else {
            layout->addWidget(ui::statusPanel(QStringLiteral("暂无收藏"), false));
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
        layout->addWidget(cardGrid(cards, 4));
    }
    if (!m_subAlbums.isEmpty()) {
        QList<QWidget*> cards;
        for (const Album& album : std::as_const(m_subAlbums)) {
            cards.append(ui::albumCard(album, [](const Album& item) {
                AppState::shared().openAlbum(item.id);
            }));
        }
        layout->addWidget(cardGrid(cards, 4));
    }
    if (!m_subRadios.isEmpty()) {
        auto* radios = new QWidget();
        auto* radiosLayout = new QHBoxLayout(radios);
        radiosLayout->setContentsMargins(0, 0, 0, 0);
        radiosLayout->setSpacing(CTSpacing::Lg);
        for (const RadioStation& radio : std::as_const(m_subRadios)) {
            auto* card = new ui::CardButton();
            card->setFixedWidth(160);
            auto* cardLayout = new QVBoxLayout(card);
            cardLayout->setContentsMargins(0, 0, 0, 0);
            cardLayout->setSpacing(CTSpacing::Sm);
            auto* cover = new CoverImage(card);
            cover->setFixedSize(160, 160);
            cover->setCornerRadius(CTRadius::Medium);
            cover->setCoverURL(radio.coverURL, 320);
            cardLayout->addWidget(cover, 0, Qt::AlignHCenter);
            cardLayout->addWidget(ui::titleLabel(radio.name, CTTypography::Body, true));
            cardLayout->addWidget(ui::secondaryLabel(
                QStringLiteral("%1 期").arg(radio.programCount)));
            const QString id = radio.id;
            card->onClicked = [id] { AppState::shared().openRadio(id); };
            radiosLayout->addWidget(card, 0, Qt::AlignTop);
        }
        radiosLayout->addStretch(1);
        layout->addWidget(radios);
    }
    if (m_subscriptionsError.has_value()) {
        auto* error = ui::secondaryLabel(*m_subscriptionsError);
        error->setWordWrap(true);
        layout->addWidget(error);
    }
    return section;
}

CT_REGISTER_PAGE(Page::MyMusic, MyMusicView);

} // namespace ct
