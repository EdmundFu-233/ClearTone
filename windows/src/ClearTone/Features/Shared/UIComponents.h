#pragma once

#include "Core/Models/MusicModels.h"
#include "DesignSystem/CTTheme.h"

#include <QFrame>
#include <QList>
#include <QPushButton>
#include <QString>
#include <QWidget>

#include <functional>

class QLabel;
class QListWidget;
class QListWidgetItem;
class QVBoxLayout;
class QScrollArea;

namespace ct {

namespace ui {

QLabel* titleLabel(const QString& text, double size = CTTypography::Body, bool bold = false);
QLabel* secondaryLabel(const QString& text);
QWidget* headerRow(const QString& title, QWidget* trailing = nullptr);
QPushButton* linkButton(const QString& text, std::function<void()> action);
QPushButton* accentButton(const QString& text);
QPushButton* ghostButton(const QString& text);
QWidget* statusPanel(const QString& text, bool showSpinner = true);
QWidget* errorPanel(const QString& message, std::function<void()> retry);
QFrame* separator();
QScrollArea* scrollWrapper(QWidget* content);

class CardButton : public QFrame {
    Q_OBJECT

public:
    explicit CardButton(QWidget* parent = nullptr);
    std::function<void()> onClicked;
    void setHighlighted(bool highlighted);

protected:
    void mouseReleaseEvent(QMouseEvent* event) override;
    void enterEvent(QEnterEvent* event) override;
    void leaveEvent(QEvent* event) override;
};

QWidget* playlistCard(const Playlist& playlist, std::function<void(const Playlist&)> onClick, double width = 160);
QWidget* albumCard(const Album& album, std::function<void(const Album&)> onClick, double width = 160);
QWidget* artistCard(const Artist& artist, std::function<void(const Artist&)> onClick, double width = 140);

} // namespace ui

// 可复用歌曲列表：双击播放、喜欢状态、正在播放标记、右键菜单。
class SongListView : public QWidget {
    Q_OBJECT

public:
    explicit SongListView(QWidget* parent = nullptr);
    ~SongListView() override;

    void setSongs(const QList<Song>& songs);
    const QList<Song>& songs() const { return m_songs; }
    void setShowIndex(bool showIndex);
    void setRowHeight(int height);
    void setEmptyText(const QString& text);
    QListWidget* listWidget() const { return m_list; }

private:
    struct Row {
        QListWidgetItem* item = nullptr;
        QWidget* widget = nullptr;
        QLabel* index = nullptr;
        QLabel* like = nullptr;
        QLabel* title = nullptr;
        QLabel* artist = nullptr;
        QLabel* reason = nullptr;
        QLabel* duration = nullptr;
    };

    void rebuild();
    void refreshDynamic();
    void showContextMenu(const QPoint& position);
    void activateRow(int row);

    QListWidget* m_list;
    QList<Song> m_songs;
    QList<Row> m_rows;
    QLabel* m_empty = nullptr;
    bool m_showIndex = true;
    int m_rowHeight = 52;
    QString m_emptyText;
    int m_appObserver = 0;
    int m_stateObserver = 0;
    int m_songObserver = 0;
};

} // namespace ct
