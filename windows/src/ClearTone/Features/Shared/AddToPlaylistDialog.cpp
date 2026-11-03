#include "Features/Shared/AddToPlaylistDialog.h"

#include "App/AppState.h"
#include "DesignSystem/CTTheme.h"
#include "Features/Shared/UIComponents.h"

#include <QComboBox>
#include <QHBoxLayout>
#include <QLabel>
#include <QPushButton>
#include <QVBoxLayout>

namespace ct {

AddToPlaylistDialog::AddToPlaylistDialog(Song song, QWidget* parent, AppState* app)
    : QDialog(parent)
    , m_song(std::move(song))
    , m_app(app ? *app : AppState::shared())
    , m_accountGeneration(m_app.currentAccountGeneration())
{
    setAttribute(Qt::WA_DeleteOnClose);
    setObjectName(QStringLiteral("ctAddToPlaylistDialog"));
    setWindowTitle(QStringLiteral("添加到歌单"));
    setModal(true);
    resize(400, 220);
    setStyleSheet(QStringLiteral("QDialog { background: %1; }").arg(CTColors::panel().name()));

    auto* layout = new QVBoxLayout(this);
    layout->setContentsMargins(CTSpacing::Xl, CTSpacing::Xl, CTSpacing::Xl, CTSpacing::Xl);
    layout->setSpacing(CTSpacing::Md);
    layout->addWidget(ui::titleLabel(QStringLiteral("添加到歌单"), CTTypography::SectionTitle, true));
    layout->addWidget(ui::titleElidedLabel(m_song.title));
    m_picker = new QComboBox(this);
    m_picker->setObjectName(QStringLiteral("ctPlaylistPicker"));
    m_picker->setSizeAdjustPolicy(QComboBox::AdjustToMinimumContentsLengthWithIcon);
    m_picker->setMinimumContentsLength(16);
    m_picker->setEnabled(false);
    layout->addWidget(m_picker);
    m_message = ui::secondaryLabel(QStringLiteral("正在加载歌单…"));
    m_message->setWordWrap(true);
    layout->addWidget(m_message);

    auto* buttons = new QHBoxLayout();
    buttons->addStretch();
    auto* cancel = ui::ghostButton(QStringLiteral("取消"));
    m_confirm = ui::accentButton(QStringLiteral("添加"));
    m_confirm->setObjectName(QStringLiteral("ctConfirmAddToPlaylist"));
    m_confirm->setEnabled(false);
    buttons->addWidget(cancel);
    buttons->addWidget(m_confirm);
    layout->addLayout(buttons);
    connect(cancel, &QPushButton::clicked, this, &QDialog::reject);
    connect(m_confirm, &QPushButton::clicked, this, [this] {
        const int index = m_picker->currentIndex();
        if (!m_confirm->isEnabled() || !checkSession() || index < 0 || index >= m_playlists.size()) return;
        detach(submitAsync(this, m_playlists.at(index), m_song));
    });
    detach(loadAsync(this));
}

void AddToPlaylistDialog::showError(const QString& message)
{
    m_message->setText(message);
    m_message->setVisible(true);
}

bool AddToPlaylistDialog::checkSession()
{
    const AppState& app = m_app;
    if (!app.canPerformWrite() || app.currentAccountGeneration() != m_accountGeneration) {
        m_confirm->setEnabled(false);
        m_picker->setEnabled(false);
        showError(QStringLiteral("登录状态已变化，请关闭此窗口并重新登录后再试。"));
        return false;
    }
    return true;
}

Task<void> AddToPlaylistDialog::loadAsync(QPointer<AddToPlaylistDialog> self)
{
    if (!self || !self->checkSession()) co_return;
    try {
        co_await self->m_app.loadUserPlaylists();
    } catch (const std::exception&) {
        if (self) self->showError(QStringLiteral("加载歌单失败，请稍后重试。"));
        co_return;
    }
    if (!self || !self->checkSession()) co_return;
    for (const Playlist& playlist : self->m_app.userPlaylists()) {
        if (playlist.source != SongSource::Netease || playlist.isSubscribed) continue;
        self->m_playlists.append(playlist);
        self->m_picker->addItem(playlist.name);
    }
    const bool hasPlaylists = !self->m_playlists.isEmpty();
    self->m_picker->setEnabled(hasPlaylists);
    self->m_confirm->setEnabled(hasPlaylists);
    self->m_message->setVisible(!hasPlaylists);
    if (!hasPlaylists) self->showError(QStringLiteral("暂无可添加的歌单，请先在「我的音乐」中创建歌单。"));
}

Task<void> AddToPlaylistDialog::submitAsync(QPointer<AddToPlaylistDialog> self, Playlist playlist, Song song)
{
    if (!self || !self->checkSession() || song.source != SongSource::Netease) co_return;
    self->m_confirm->setEnabled(false);
    self->m_picker->setEnabled(false);
    self->showError(QStringLiteral("正在添加…"));
    bool ok = false;
    try {
        const QStringList ids{song.id};
        ok = co_await self->m_app.modifyPlaylist(playlist, ids, true);
    } catch (const std::exception&) {
    }
    if (!self || !self->checkSession()) co_return;
    if (ok) {
        self->accept();
        co_return;
    }
    self->m_confirm->setEnabled(true);
    self->m_picker->setEnabled(true);
    const QString error = self->m_app.lastWriteError();
    self->showError(error.isEmpty() ? QStringLiteral("添加失败，请稍后重试。") : error);
}

} // namespace ct
