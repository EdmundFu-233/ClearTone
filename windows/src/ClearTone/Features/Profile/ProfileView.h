#pragma once

#include "Core/Async.h"
#include "Core/Models/DiscoveryModels.h"
#include "Core/Models/RadioModels.h"
#include "Core/Models/SocialModels.h"

#include <QHash>
#include <QList>
#include <QString>
#include <QWidget>

#include <memory>
#include <optional>

class QLabel;
class QVBoxLayout;

namespace ct {

class ProfileView : public QWidget {
    Q_OBJECT

public:
    explicit ProfileView(QWidget* parent = nullptr);
    ~ProfileView() override;

protected:
    void showEvent(QShowEvent* event) override;
    void hideEvent(QHideEvent* event) override;

private:
    void loadAll();
    void resetState();
    void render();
    void scheduleAppChange();
    void handleAppChange();

    Task<void> loadLevelAsync(quint64 token);
    Task<void> loadCountsAsync(quint64 token);
    Task<void> loadRecordsAsync(quint64 token);
    Task<void> loadSubscriptionsAsync(quint64 token);
    Task<void> loadMyCommentsAsync(quint64 token);
    Task<void> openCommentSongAsync(QString songID);
    Task<void> changeRangeAsync(bool weekly);
    Task<void> signInAsync();
    Task<void> logoutAsync();

    QWidget* buildLoginRequired();
    QWidget* buildAccountCard();
    QWidget* buildLevelCard();
    QWidget* buildSignInCard();
    QWidget* buildCountsCard();
    QWidget* buildRecordsSection();
    QWidget* buildRecordList();
    QWidget* buildSubscriptionsSection();
    QWidget* buildMyCommentsSection();
    QWidget* buildSignInButton();
    QString signInSubtitle() const;

    QLabel* m_subtitle = nullptr;
    QWidget* m_body = nullptr;
    QVBoxLayout* m_bodyLayout = nullptr;

    std::optional<UserLevelInfo> m_level;
    bool m_loadingLevel = false;
    std::optional<QString> m_levelError;

    std::optional<SignInResult> m_signIn;
    bool m_signingIn = false;

    QList<ListenRecord> m_records;
    bool m_loadingRecords = false;
    std::optional<QString> m_recordsError;
    bool m_recordsWeekly = false;

    std::optional<QHash<QString, int>> m_counts;
    bool m_loadingCounts = false;
    std::optional<QString> m_countsError;

    QList<Artist> m_subArtists;
    QList<Album> m_subAlbums;
    QList<RadioStation> m_subRadios;
    QList<Playlist> m_subPlaylists;
    bool m_loadingSubscriptions = false;
    std::optional<QString> m_subscriptionsError;

    QList<MyComment> m_myComments;
    bool m_loadingMyComments = false;
    std::optional<QString> m_myCommentsError;

    quint64 m_loadToken = 0;
    bool m_isAttached = false;
    QString m_lastDataContextKey;
    bool m_lastCanWrite = false;
    bool m_appChangeScheduled = false;
    std::shared_ptr<bool> m_alive = std::make_shared<bool>(true);
    int m_appObserver = 0;
    int m_contextObserver = 0;
};

} // namespace ct
