#pragma once

#include "Core/Async.h"
#include "Core/Models/MusicModels.h"

#include <QDialog>
#include <QPointer>

class QComboBox;
class QLabel;
class QPushButton;

namespace ct {

class AppState;

class AddToPlaylistDialog : public QDialog {
public:
    explicit AddToPlaylistDialog(Song song, QWidget* parent = nullptr, AppState* app = nullptr);

private:
    static Task<void> loadAsync(QPointer<AddToPlaylistDialog> self);
    static Task<void> submitAsync(QPointer<AddToPlaylistDialog> self, Playlist playlist, Song song);
    bool checkSession();
    void showError(const QString& message);

    Song m_song;
    AppState& m_app;
    int m_accountGeneration;
    QList<Playlist> m_playlists;
    QComboBox* m_picker = nullptr;
    QLabel* m_message = nullptr;
    QPushButton* m_confirm = nullptr;
};

} // namespace ct
