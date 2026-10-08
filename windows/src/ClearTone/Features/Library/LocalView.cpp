#include "Features/Library/LocalView.h"

#include "DesignSystem/CTTheme.h"
#include "Features/Shared/PageFactory.h"
#include "Features/Shared/UIComponents.h"
#include "Providers/Local/LocalProvider.h"

#include <QFileDialog>
#include <QHBoxLayout>
#include <QLabel>
#include <QLineEdit>
#include <QPushButton>
#include <QVBoxLayout>

#include <utility>

namespace ct {

namespace {

void setHost(QVBoxLayout* layout, QWidget* content, QWidget* persistent = nullptr)
{
    if (content != nullptr && layout->indexOf(content) >= 0 && layout->count() == 1) return;
    while (QLayoutItem* item = layout->takeAt(0)) {
        if (QWidget* widget = item->widget()) {
            if (widget == persistent) {
                widget->hide();
            } else if (widget != content) {
                widget->deleteLater();
            }
        }
        delete item;
    }
    if (content != nullptr) {
        content->show();
        layout->addWidget(content);
    }
}

QString unknownUserMessage(const std::exception& error)
{
    return MusicException::unknown(QString::fromUtf8(error.what())).userFacingMessage();
}

} // namespace

LocalView::LocalView(QWidget* parent)
    : QWidget(parent)
{
    setObjectName(QStringLiteral("ctLocalView"));
    setStyleSheet(QStringLiteral("QWidget#ctLocalView { background: %1; }")
                      .arg(CTColors::background().name()));

    auto* root = new QVBoxLayout(this);
    root->setContentsMargins(0, 0, 0, 0);
    root->setSpacing(0);

    m_title = ui::titleLabel(QStringLiteral("本地音乐"), CTTypography::PageTitle, true);

    auto* importFiles = ui::ghostButton(QStringLiteral("导入文件"));
    connect(importFiles, &QPushButton::clicked, this, [this] { detach(importFilesAsync()); });
    auto* importFolder = ui::ghostButton(QStringLiteral("导入文件夹"));
    connect(importFolder, &QPushButton::clicked, this, [this] { detach(importFolderAsync()); });

    auto* actions = new QWidget(this);
    auto* actionsLayout = new QHBoxLayout(actions);
    actionsLayout->setContentsMargins(0, 0, 0, 0);
    actionsLayout->setSpacing(CTSpacing::Sm);
    actionsLayout->addWidget(importFiles);
    actionsLayout->addWidget(importFolder);

    auto* header = new QWidget(this);
    auto* headerLayout = new QHBoxLayout(header);
    headerLayout->setContentsMargins(CTSpacing::Lg, CTSpacing::Lg, CTSpacing::Lg, CTSpacing::Sm);
    headerLayout->addWidget(m_title);
    headerLayout->addStretch(1);
    headerLayout->addWidget(actions, 0, Qt::AlignVCenter);
    root->addWidget(header);

    m_searchBox = new QLineEdit(this);
    m_searchBox->setPlaceholderText(QStringLiteral("在本地音乐中搜索"));
    m_searchBox->setFrame(false);
    m_searchBox->setStyleSheet(QStringLiteral("QLineEdit { background: transparent; color: %1; }")
                                   .arg(CTColors::textPrimary().name()));
    connect(m_searchBox, &QLineEdit::textChanged, this, [this] { render(); });

    m_countText = ui::secondaryLabel(QString());
    m_countText->setVisible(false);

    auto* clear = ui::linkButton(QStringLiteral("清空"), [this] { m_searchBox->clear(); });

    auto* searchGrid = new QWidget(this);
    auto* searchLayout = new QHBoxLayout(searchGrid);
    searchLayout->setContentsMargins(CTSpacing::Sm, CTSpacing::Sm, CTSpacing::Sm, CTSpacing::Sm);
    searchLayout->setSpacing(CTSpacing::Sm);
    searchLayout->addWidget(m_searchBox, 1);
    searchLayout->addWidget(m_countText);
    searchLayout->addWidget(clear);

    m_searchRow = searchGrid;
    m_searchRow->setObjectName(QStringLiteral("ctLocalSearchRow"));
    m_searchRow->setStyleSheet(
        QStringLiteral("QWidget#ctLocalSearchRow { background: %1; border-radius: %2px; }")
            .arg(CTColors::panel().name())
            .arg(CTRadius::Small));
    m_searchRow->setVisible(false);

    auto* searchWrap = new QWidget(this);
    auto* searchWrapLayout = new QHBoxLayout(searchWrap);
    searchWrapLayout->setContentsMargins(CTSpacing::Lg, 0, CTSpacing::Lg, CTSpacing::Sm);
    searchWrapLayout->addWidget(m_searchRow);
    root->addWidget(searchWrap);

    m_host = new QWidget(this);
    m_hostLayout = new QVBoxLayout(m_host);
    m_hostLayout->setContentsMargins(0, 0, 0, 0);
    m_hostLayout->setSpacing(0);
    root->addWidget(m_host, 1);

    m_list = new SongListView();
    m_list->setEmptyText(QStringLiteral("没有匹配的音乐"));

    render();
}

LocalView::~LocalView()
{
    *m_alive = false;
}

void LocalView::showEvent(QShowEvent* event)
{
    QWidget::showEvent(event);
    if (!m_restored) {
        m_restored = true;
        detach(restoreAsync());
    }
}

void LocalView::updateTitle()
{
    m_title->setText(m_songs.isEmpty() ? QStringLiteral("本地音乐")
                                       : QStringLiteral("本地音乐（%1）").arg(m_songs.size()));
}

QList<Song> LocalView::filtered() const
{
    const QString keyword = m_searchBox->text().trimmed();
    if (keyword.isEmpty()) return m_songs;
    QList<Song> result;
    for (const Song& song : m_songs) {
        const bool albumMatch = song.album.has_value()
            && song.album->name.contains(keyword, Qt::CaseInsensitive);
        if (song.title.contains(keyword, Qt::CaseInsensitive)
            || song.artistNames().contains(keyword, Qt::CaseInsensitive) || albumMatch) {
            result.append(song);
        }
    }
    return result;
}

void LocalView::render()
{
    const QList<Song> songs = filtered();
    m_searchRow->setVisible(!m_songs.isEmpty());
    const QString keyword = m_searchBox->text().trimmed();
    m_countText->setVisible(!keyword.isEmpty());
    m_countText->setText(QStringLiteral("%1 / %2").arg(songs.size()).arg(m_songs.size()));

    if (m_isImporting) {
        setHost(m_hostLayout, ui::statusPanel(QStringLiteral("导入中…"), true), m_list);
        return;
    }
    if (m_error.has_value()) {
        setHost(m_hostLayout,
            ui::errorPanel(*m_error, [this] {
                m_error.reset();
                if (m_songs.isEmpty()) {
                    detach(restoreAsync());
                } else {
                    render();
                }
            }),
            m_list);
        return;
    }
    if (m_songs.isEmpty()) {
        setHost(m_hostLayout,
            ui::statusPanel(QStringLiteral("导入音频文件或文件夹开始播放"), false), m_list);
        return;
    }
    if (songs.isEmpty()) {
        setHost(m_hostLayout, ui::statusPanel(QStringLiteral("没有匹配的音乐"), false), m_list);
        return;
    }

    m_list->setSongs(songs);
    setHost(m_hostLayout, m_list, m_list);
}

Task<void> LocalView::restoreAsync()
{
    auto alive = m_alive;
    try {
        const QList<Song> songs = co_await LocalProvider::shared().restoreLibrary();
        if (!*alive) co_return;
        m_songs = songs;
        updateTitle();
    } catch (const MusicException& error) {
        if (!*alive) co_return;
        m_error = error.userFacingMessage();
    } catch (const std::exception& error) {
        if (!*alive) co_return;
        m_error = unknownUserMessage(error);
    }
    if (!*alive) co_return;
    render();
    co_return;
}

Task<void> LocalView::importFilesAsync()
{
    const QStringList paths = QFileDialog::getOpenFileNames(this, QStringLiteral("选择音频文件"),
        QString(),
        QStringLiteral("音频文件 (*.mp3 *.m4a *.aac *.wav *.flac *.aiff *.alac);;所有文件 (*)"));
    if (paths.isEmpty()) co_return;
    co_await runImportAsync(
        [paths] { return LocalProvider::shared().importFiles(paths, CancellationToken::none()); });
    co_return;
}

Task<void> LocalView::importFolderAsync()
{
    const QString directory = QFileDialog::getExistingDirectory(
        this, QStringLiteral("选择音乐文件夹"), QString());
    if (directory.isEmpty()) co_return;
    co_await runImportAsync([directory] {
        return LocalProvider::shared().scanDirectory(directory, CancellationToken::none());
    });
    co_return;
}

Task<void> LocalView::runImportAsync(std::function<Task<QList<Song>>()> action)
{
    auto alive = m_alive;
    if (m_isImporting) co_return;
    m_isImporting = true;
    m_error.reset();
    render();
    try {
        co_await action();
        if (!*alive) co_return;
        m_songs = LocalProvider::shared().allSongs();
        updateTitle();
    } catch (const MusicException& error) {
        if (!*alive) co_return;
        m_error = error.userFacingMessage();
    } catch (const std::exception& error) {
        if (!*alive) co_return;
        m_error = unknownUserMessage(error);
    }
    if (!*alive) co_return;
    m_isImporting = false;
    render();
    co_return;
}

CT_REGISTER_PAGE(Page::Local, LocalView);

} // namespace ct
