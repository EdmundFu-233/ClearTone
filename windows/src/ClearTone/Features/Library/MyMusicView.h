#pragma once

#include "Core/Async.h"
#include "Core/Models/MusicModels.h"
#include "Core/Models/RadioModels.h"

#include <QList>
#include <QPointer>
#include <QString>
#include <QWidget>

#include <memory>
#include <optional>

class QDialog;
class QLabel;
class QPushButton;
class QVBoxLayout;

namespace ct {

class MyMusicView : public QWidget {
    Q_OBJECT

public:
    explicit MyMusicView(QWidget* parent = nullptr);
    ~MyMusicView() override;

protected:
    void showEvent(QShowEvent* event) override;

private:
    void render();
    QString signature() const;
    void scheduleAppChange();
    void handleAppChange();

    Task<void> loadAsync();
    Task<void> loadSubscriptionsAsync(quint64 token);
    Task<void> submitCreateAsync(QPointer<QDialog> dialog);
    Task<void> submitRenameAsync(QPointer<QDialog> dialog, Playlist playlist);
    Task<void> submitDeleteAsync(QPointer<QDialog> dialog, Playlist playlist);

    void showCreateDialog();
    void showRenameDialog(const Playlist& playlist);
    void showDeleteDialog(const Playlist& playlist);

    QWidget* buildLoginRequired();
    QWidget* buildLikedCard();
    QWidget* buildPlaylistCard(const Playlist& playlist);
    QWidget* buildRecentEntry();
    QWidget* buildSubscriptionsSection();

    QLabel* m_subtitle = nullptr;
    QPushButton* m_createButton = nullptr;
    QWidget* m_body = nullptr;
    QVBoxLayout* m_bodyLayout = nullptr;

    QList<Artist> m_subArtists;
    QList<Album> m_subAlbums;
    QList<RadioStation> m_subRadios;
    bool m_loadingSubscriptions = false;
    std::optional<QString> m_subscriptionsError;

    quint64 m_loadToken = 0;
    bool m_hasLoaded = false;
    QString m_lastDataContextKey;
    QString m_lastSignature;
    bool m_appChangeScheduled = false;
    std::shared_ptr<bool> m_alive = std::make_shared<bool>(true);
    int m_appObserver = 0;
    int m_contextObserver = 0;
};

} // namespace ct
