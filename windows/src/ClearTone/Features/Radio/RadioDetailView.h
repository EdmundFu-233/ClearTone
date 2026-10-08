#pragma once

#include "Core/Async.h"
#include "Core/Models/MusicModels.h"
#include "Core/Models/RadioModels.h"

#include <QWidget>

#include <memory>
#include <optional>

class QLabel;
class QListWidget;
class QListWidgetItem;
class QPushButton;
class QVBoxLayout;

namespace ct {

class RadioDetailView : public QWidget {
    Q_OBJECT

public:
    explicit RadioDetailView(QWidget* parent = nullptr);
    ~RadioDetailView() override;

protected:
    void showEvent(QShowEvent* event) override;
    void hideEvent(QHideEvent* event) override;

private:
    void scheduleAppChange();
    void handleAppChange();
    void load();
    Task<void> loadStationAsync(QString id, quint64 token);
    Task<void> loadProgramsAsync(QString id, int page, quint64 token);
    Task<void> toggleSubscribeAsync(quint64 token);
    void renderHeader();
    void renderPrograms();
    void updateStatus(const QString& text, bool visible);
    void playProgram(int programIndex);
    QList<Song> playableSongs() const;
    QList<int> playableIndexMap() const;
    QListWidgetItem* buildProgramRow(const RadioProgram& program, int programIndex, int songIndex);
    QString metaText(const RadioStation& station) const;

    QWidget* m_headerHost = nullptr;
    QVBoxLayout* m_headerLayout = nullptr;
    QLabel* m_statusText = nullptr;
    QListWidget* m_programList = nullptr;
    QPushButton* m_loadMoreButton = nullptr;

    QList<RadioProgram> m_programs;
    std::optional<RadioStation> m_station;
    std::optional<QString> m_loadedStationID;
    quint64 m_loadToken = 0;
    int m_page = 1;
    int m_programCount = 0;
    bool m_loading = false;
    bool m_isLoadingMore = false;
    bool m_hasMore = false;
    bool m_isAttached = false;
    QString m_lastSelectedID;
    std::shared_ptr<bool> m_alive = std::make_shared<bool>(true);
    int m_appObserver = 0;
    bool m_appChangeScheduled = false;
};

} // namespace ct
