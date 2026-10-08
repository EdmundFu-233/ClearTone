#pragma once

#include "Core/Async.h"

#include <QImage>
#include <QWidget>

#include <memory>

class QLabel;
class QProgressBar;
class QPushButton;

namespace ct {

class IMusicProvider;

class LoginView : public QWidget {
    Q_OBJECT

public:
    explicit LoginView(QWidget* parent = nullptr);
    ~LoginView() override;

protected:
    void showEvent(QShowEvent* event) override;
    void hideEvent(QHideEvent* event) override;

private:
    Task<void> runAsync(CancellationToken ct, int generation);
    Task<bool> pollAsync(QString key, CancellationToken ct, int generation);
    Task<bool> completeLoginAsync(QString cookie, CancellationToken ct, int generation);

    void beginLogin();
    void cancel();
    void showError(const QString& message);
    void setQRCode(const QImage& image);

    IMusicProvider* m_provider = nullptr;

    QLabel* m_qrImage = nullptr;
    QProgressBar* m_spinner = nullptr;
    QLabel* m_statusText = nullptr;
    QLabel* m_errorText = nullptr;
    QPushButton* m_retryButton = nullptr;

    std::shared_ptr<CancellationTokenSource> m_cts;
    std::shared_ptr<bool> m_alive = std::make_shared<bool>(true);
    int m_generation = 0;
    bool m_running = false;
    bool m_lastPresented = false;
    int m_appObserver = 0;
};

} // namespace ct
