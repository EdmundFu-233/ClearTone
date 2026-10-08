#pragma once

#include <QWidget>

class QLabel;
class QListWidget;

namespace ct {

class QueuePanelView : public QWidget {
    Q_OBJECT

public:
    explicit QueuePanelView(QWidget* parent = nullptr);
    ~QueuePanelView() override;

protected:
    void showEvent(QShowEvent* event) override;

private:
    void scheduleRefresh();
    void refresh();
    void activateRow(int row);
    void showContextMenu(const QPoint& position);
    void moveItem(int row, int delta);

    QLabel* m_countText = nullptr;
    QListWidget* m_list = nullptr;
    QLabel* m_emptyText = nullptr;
    bool m_refreshScheduled = false;
    bool m_syncing = false;
    int m_queueObserver = 0;
    int m_songObserver = 0;
};

} // namespace ct
