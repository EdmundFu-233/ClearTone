#pragma once

#include "Core/Async.h"
#include "Core/Persistence/AppSettings.h"

#include <QWidget>

#include <memory>

class QCheckBox;
class QComboBox;
class QDoubleSpinBox;
class QLabel;
class QPushButton;
class QNetworkAccessManager;

namespace ct {

class SettingsView : public QWidget {
    Q_OBJECT

public:
    explicit SettingsView(QWidget* parent = nullptr);
    ~SettingsView() override;

protected:
    void showEvent(QShowEvent* event) override;

private:
    void buildUi();
    void buildSections(QWidget* body);
    void loadSettings();
    void save();
    void updateCloseHint();
    void updateOffsetDescription();
    void updateCacheSize();
    void updateAccount();
    void updateAutoQualityLabel();
    void checkForUpdates();
    QString autoQualityLabel() const;
    Task<void> logoutAsync();

    QComboBox* m_themeBox = nullptr;
    QCheckBox* m_resumeBox = nullptr;
    QCheckBox* m_cacheBox = nullptr;
    QComboBox* m_qualityBox = nullptr;
    QComboBox* m_closeBox = nullptr;
    QCheckBox* m_menuBarBox = nullptr;
    QCheckBox* m_miniTopBox = nullptr;
    QComboBox* m_performanceBox = nullptr;
    QDoubleSpinBox* m_offsetBox = nullptr;
    QLabel* m_closeHint = nullptr;
    QLabel* m_offsetDescription = nullptr;
    QLabel* m_cacheSizeText = nullptr;
    QPushButton* m_clearCacheButton = nullptr;
    QLabel* m_accountText = nullptr;
    QPushButton* m_logoutButton = nullptr;
    QLabel* m_saveHint = nullptr;
    QLabel* m_updateHint = nullptr;
    QPushButton* m_updateButton = nullptr;
    QPushButton* m_downloadButton = nullptr;
    QNetworkAccessManager* m_updateClient = nullptr;

    AppSettings m_settings;
    bool m_loading = false;
    std::shared_ptr<bool> m_alive = std::make_shared<bool>(true);
    int m_appObserver = 0;
};

} // namespace ct
