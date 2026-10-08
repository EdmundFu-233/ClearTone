#pragma once

#include "Core/Async.h"
#include "Core/Models/MusicModels.h"

#include <QList>
#include <QString>
#include <QWidget>

#include <memory>
#include <optional>

class QLabel;
class QVBoxLayout;

namespace ct {

class PersonalFMView : public QWidget {
    Q_OBJECT

public:
    explicit PersonalFMView(QWidget* parent = nullptr);
    ~PersonalFMView() override;

protected:
    void showEvent(QShowEvent* event) override;

private:
    void render();
    void scheduleRender();
    void handleAppChange();
    void scheduleAppChange();

    Task<void> loadAsync();
    Task<void> nextAsync();
    Task<void> toggleLikeAsync(Song song);
    Task<void> dislikeAsync(Song song);

    QWidget* buildLoginRequired();
    QWidget* buildCurrentPanel(const Song& song);

    QLabel* m_subtitle = nullptr;
    QWidget* m_host = nullptr;
    QVBoxLayout* m_hostLayout = nullptr;

    QList<Song> m_songs;
    int m_index = 0;
    bool m_isLoading = false;
    std::optional<QString> m_errorMessage;
    quint64 m_loadToken = 0;
    bool m_hasLoaded = false;

    QString m_lastDataContextKey;
    int m_lastLikesVersion = -1;
    bool m_lastCanWrite = false;
    bool m_appChangeScheduled = false;
    bool m_renderScheduled = false;

    std::shared_ptr<bool> m_alive = std::make_shared<bool>(true);
    int m_appObserver = 0;
    int m_contextObserver = 0;
    int m_songObserver = 0;
    int m_stateObserver = 0;
};

} // namespace ct
