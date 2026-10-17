#pragma once

#include "Core/Async.h"

#include <QHash>
#include <QPixmap>
#include <QPointer>
#include <QSet>
#include <QWidget>

#include <memory>

class QHideEvent;
class QLabel;
class QListWidget;

namespace ct {

class QueuePanelView : public QWidget {
    Q_OBJECT

public:
    explicit QueuePanelView(QWidget* parent = nullptr);
    ~QueuePanelView() override;

    QPixmap coverPixmapFor(const QString& url);

protected:
    void showEvent(QShowEvent* event) override;
    void hideEvent(QHideEvent* event) override;

private:
    static Task<void> fetchCoverAsync(QPointer<QueuePanelView> self, QString url,
        quint64 generation, CancellationToken token);
    void scheduleRefresh(bool structureChanged);
    void refresh();
    void updateSelectionOnly();
    void activateRow(int row);
    void showContextMenu(const QPoint& position);
    void moveItem(int row, int delta);

    QLabel* m_countText = nullptr;
    QListWidget* m_list = nullptr;
    QLabel* m_emptyText = nullptr;
    bool m_refreshScheduled = false;
    bool m_pendingStructureRefresh = false;
    bool m_dirtyWhileHidden = true;
    bool m_syncing = false;
    QHash<QString, QPixmap> m_rowPixmaps;
    QSet<QString> m_inFlightCovers;
    quint64 m_coverGeneration = 0;
    std::shared_ptr<CancellationTokenSource> m_coverCts;
    int m_queueObserver = 0;
    int m_songObserver = 0;
};

} // namespace ct
