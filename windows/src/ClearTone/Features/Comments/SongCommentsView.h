#pragma once

#include "Core/Async.h"
#include "Core/Comments/CommentsStore.h"
#include "Core/Models/SocialModels.h"

#include <QString>
#include <QWidget>

#include <memory>
#include <optional>

class QScrollArea;
class QVBoxLayout;

namespace ct {

class SongCommentsView : public QWidget {
    Q_OBJECT

public:
    explicit SongCommentsView(QWidget* parent = nullptr);
    ~SongCommentsView() override;

protected:
    void showEvent(QShowEvent* event) override;
    void hideEvent(QHideEvent* event) override;

private:
    void render();
    void scheduleRender();
    void scheduleAppChange();
    void handleAppChange();
    void loadComments();
    void changeSort(CommentSort sort);
    void loadMore();
    void toggleLike(const Comment& comment);

    Task<void> loadCommentsAsync(Song song, CommentSort sort, quint64 token);
    Task<void> changeSortAsync(CommentSort sort, quint64 token);
    Task<void> loadMoreAsync();
    Task<void> toggleLikeAsync(Comment comment);

    QWidget* buildHeader();
    QWidget* buildRow(const Comment& comment);
    QWidget* buildFooter();

    CommentsStore m_store;
    std::optional<Song> m_song;
    quint64 m_loadToken = 0;
    bool m_isAttached = false;
    bool m_rendering = false;
    bool m_renderScheduled = false;
    bool m_appChangeScheduled = false;
    QString m_lastDataContextKey;
    std::shared_ptr<bool> m_alive = std::make_shared<bool>(true);
    int m_appObserver = 0;
    int m_contextObserver = 0;

    QWidget* m_headerHost = nullptr;
    QVBoxLayout* m_headerLayout = nullptr;
    QScrollArea* m_scroll = nullptr;
    QWidget* m_content = nullptr;
    QVBoxLayout* m_contentLayout = nullptr;
};

} // namespace ct
