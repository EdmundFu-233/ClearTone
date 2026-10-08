#pragma once

#include "Core/Async.h"
#include "Core/Models/MusicModels.h"

#include <QList>
#include <QString>
#include <QWidget>

#include <functional>
#include <memory>
#include <optional>

class QLabel;
class QLineEdit;
class QVBoxLayout;

namespace ct {

class SongListView;

class LocalView : public QWidget {
    Q_OBJECT

public:
    explicit LocalView(QWidget* parent = nullptr);
    ~LocalView() override;

protected:
    void showEvent(QShowEvent* event) override;

private:
    void render();
    QList<Song> filtered() const;
    void updateTitle();

    Task<void> restoreAsync();
    Task<void> importFilesAsync();
    Task<void> importFolderAsync();
    Task<void> runImportAsync(std::function<Task<QList<Song>>()> action);

    QLabel* m_title = nullptr;
    QWidget* m_searchRow = nullptr;
    QLineEdit* m_searchBox = nullptr;
    QLabel* m_countText = nullptr;
    QWidget* m_host = nullptr;
    QVBoxLayout* m_hostLayout = nullptr;
    SongListView* m_list = nullptr;

    QList<Song> m_songs;
    bool m_isImporting = false;
    bool m_restored = false;
    std::optional<QString> m_error;
    std::shared_ptr<bool> m_alive = std::make_shared<bool>(true);
};

} // namespace ct
