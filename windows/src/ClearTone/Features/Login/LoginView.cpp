#include "Features/Login/LoginView.h"

#include "App/AppState.h"
#include "Core/Models/MusicProvider.h"
#include "Core/Security/CredentialStore.h"
#include "Core/Security/NeteaseCookieNormalizer.h"
#include "DesignSystem/CTTheme.h"
#include "DesignSystem/CoverImageLoader.h"
#include "DesignSystem/L10n.h"
#include "Features/Shared/PageFactory.h"
#include "Features/Shared/UIComponents.h"
#include "Providers/Netease/NeteaseProvider.h"

#include <QByteArray>
#include <QGridLayout>
#include <QHBoxLayout>
#include <QLabel>
#include <QPixmap>
#include <QProgressBar>
#include <QPushButton>
#include <QVBoxLayout>

namespace ct {

namespace {

Task<QImage> loadQRCodeImage(const QString& source, CancellationToken ct)
{
    if (source.startsWith(QStringLiteral("data:"), Qt::CaseInsensitive)) {
        const int comma = source.indexOf(QLatin1Char(','));
        if (comma < 0) co_return QImage();
        const QByteArray decoded = QByteArray::fromBase64(source.mid(comma + 1).toUtf8());
        co_return QImage::fromData(decoded);
    }
    if (source.startsWith(QStringLiteral("http://"), Qt::CaseInsensitive)
        || source.startsWith(QStringLiteral("https://"), Qt::CaseInsensitive)) {
        const std::optional<QImage> image = co_await CoverImageLoader::shared().load(source, 440, ct);
        co_return image.value_or(QImage());
    }
    co_return QImage();
}

} // namespace

LoginView::LoginView(QWidget* parent)
    : QWidget(parent)
    , m_provider(AppState::shared().provider())
{
    setObjectName(QStringLiteral("ctLoginView"));
    setStyleSheet(QStringLiteral("QWidget#ctLoginView { background: transparent; }"));

    auto* layout = new QVBoxLayout(this);
    layout->setContentsMargins(CTSpacing::Xl, CTSpacing::Xl, CTSpacing::Xl, CTSpacing::Xl);
    layout->setSpacing(CTSpacing::Lg);

    auto* header = new QWidget(this);
    auto* headerLayout = new QHBoxLayout(header);
    headerLayout->setContentsMargins(0, 0, 0, 0);
    auto* title = ui::titleLabel(L10n::Login::Title, 18, true);
    headerLayout->addWidget(title);
    headerLayout->addStretch(1);

    auto* close = new QPushButton(QStringLiteral("✕"), header);
    close->setToolTip(L10n::Common::Close);
    close->setCursor(Qt::PointingHandCursor);
    close->setFixedSize(28, 28);
    close->setStyleSheet(QStringLiteral("QPushButton { background: transparent; border: none; color: %1; "
                                        "font-size: 14px; }")
                             .arg(CTColors::textSecondary().name()));
    headerLayout->addWidget(close);
    layout->addWidget(header);
    connect(close, &QPushButton::clicked, this, [this] {
        AppState::shared().setIsLoginPresented(false);
        cancel();
    });

    auto* qrFrame = new QFrame(this);
    qrFrame->setObjectName(QStringLiteral("ctQRFrame"));
    qrFrame->setFixedSize(240, 240);
    qrFrame->setStyleSheet(QStringLiteral("QFrame#ctQRFrame { background: %1; border-radius: %2px; }")
                               .arg(CTColors::overlay().name())
                               .arg(CTRadius::Medium));
    auto* qrLayout = new QGridLayout(qrFrame);
    qrLayout->setContentsMargins(10, 10, 10, 10);

    m_qrImage = new QLabel(qrFrame);
    m_qrImage->setFixedSize(220, 220);
    m_qrImage->setAlignment(Qt::AlignCenter);
    qrLayout->addWidget(m_qrImage, 0, 0, Qt::AlignCenter);

    m_spinner = new QProgressBar(qrFrame);
    m_spinner->setRange(0, 0);
    m_spinner->setTextVisible(false);
    m_spinner->setFixedWidth(150);
    qrLayout->addWidget(m_spinner, 0, 0, Qt::AlignCenter);
    layout->addWidget(qrFrame, 0, Qt::AlignHCenter);

    m_statusText = ui::secondaryLabel(L10n::Login::WaitingScan);
    m_statusText->setWordWrap(true);
    m_statusText->setAlignment(Qt::AlignCenter);
    layout->addWidget(m_statusText);

    m_errorText = new QLabel(this);
    m_errorText->setWordWrap(true);
    m_errorText->setAlignment(Qt::AlignCenter);
    m_errorText->setStyleSheet(QStringLiteral("color: %1;").arg(CTColors::accent().name()));
    m_errorText->hide();
    layout->addWidget(m_errorText);

    m_retryButton = ui::accentButton(L10n::Common::Retry);
    m_retryButton->hide();
    layout->addWidget(m_retryButton, 0, Qt::AlignHCenter);
    connect(m_retryButton, &QPushButton::clicked, this, [this] { beginLogin(); });

    auto* prompt = ui::secondaryLabel(L10n::Login::ScanPrompt);
    prompt->setWordWrap(true);
    prompt->setAlignment(Qt::AlignCenter);
    layout->addWidget(prompt);
    layout->addStretch(1);

    m_lastPresented = AppState::shared().isLoginPresented();
    m_appObserver = AppState::shared().changed.subscribe([this] {
        const bool presented = AppState::shared().isLoginPresented();
        if (presented == m_lastPresented) return;
        m_lastPresented = presented;
        if (presented) {
            beginLogin();
        } else {
            cancel();
        }
    });
}

LoginView::~LoginView()
{
    *m_alive = false;
    AppState::shared().changed.unsubscribe(m_appObserver);
    cancel();
}

void LoginView::showEvent(QShowEvent* event)
{
    QWidget::showEvent(event);
    if (AppState::shared().isLoginPresented() && !m_running) beginLogin();
}

void LoginView::hideEvent(QHideEvent* event)
{
    QWidget::hideEvent(event);
    cancel();
}

void LoginView::beginLogin()
{
    cancel();
    auto cts = std::make_shared<CancellationTokenSource>();
    m_cts = cts;
    m_generation += 1;
    const int generation = m_generation;
    m_running = true;
    m_errorText->hide();
    m_retryButton->hide();
    m_spinner->show();
    m_statusText->setText(L10n::Login::WaitingScan);
    setQRCode(QImage());
    detach(runAsync(cts->token(), generation));
}

void LoginView::cancel()
{
    if (m_cts) m_cts->cancel();
    m_cts.reset();
    m_running = false;
    m_generation += 1;
}

Task<void> LoginView::runAsync(CancellationToken ct, int generation)
{
    auto alive = m_alive;
    IMusicProvider* provider = m_provider;
    try {
        while (true) {
            if (!*alive || ct.isCancellationRequested() || generation != m_generation) co_return;

            const QString key = co_await provider->fetchQRCodeKey(ct);
            const QString source = co_await provider->fetchQRCodeImage(key, ct);
            const QImage image = co_await loadQRCodeImage(source, ct);
            if (!*alive || ct.isCancellationRequested() || generation != m_generation) co_return;

            if (image.isNull()) {
                showError(QStringLiteral("二维码加载失败"));
                co_return;
            }

            setQRCode(image);
            m_spinner->hide();
            m_statusText->setText(L10n::Login::WaitingScan);

            const bool completed = co_await pollAsync(key, ct, generation);
            if (completed || !*alive || ct.isCancellationRequested() || generation != m_generation) {
                co_return;
            }

            setQRCode(QImage());
            m_spinner->show();
            m_statusText->setText(L10n::Login::Expired);
            try {
                co_await Delay(1000, ct);
            } catch (const MusicException& error) {
                if (error.isCancelled()) co_return;
                throw;
            }
        }
    } catch (const MusicException& error) {
        if (*alive && !error.isCancelled() && generation == m_generation && !ct.isCancellationRequested()) {
            showError(error.userFacingMessage());
        }
    } catch (const std::exception& error) {
        if (*alive && generation == m_generation && !ct.isCancellationRequested()) {
            showError(MusicException::unknown(QString::fromUtf8(error.what())).userFacingMessage());
        }
    }
    if (*alive && generation == m_generation) m_running = false;
    co_return;
}

Task<bool> LoginView::pollAsync(QString key, CancellationToken ct, int generation)
{
    auto alive = m_alive;
    while (true) {
        if (!*alive || ct.isCancellationRequested() || generation != m_generation) co_return true;

        const QRLoginStatus status = co_await m_provider->checkQRCodeStatus(key, ct);
        if (!*alive || ct.isCancellationRequested() || generation != m_generation) co_return true;

        switch (status.kind) {
        case QRLoginStatus::Kind::WaitingScan:
            m_statusText->setText(L10n::Login::WaitingScan);
            break;
        case QRLoginStatus::Kind::ScannedWaitingConfirm:
            m_statusText->setText(L10n::Login::Scanned);
            break;
        case QRLoginStatus::Kind::Success:
            m_statusText->setText(L10n::Login::Success);
            co_return co_await completeLoginAsync(status.cookie, ct, generation);
        case QRLoginStatus::Kind::Expired:
            m_statusText->setText(L10n::Login::Expired);
            co_return false;
        case QRLoginStatus::Kind::Failed:
            showError(QStringLiteral("%1: %2").arg(L10n::Login::Failed, status.reason));
            co_return true;
        }

        try {
            co_await Delay(2000, ct);
        } catch (const MusicException& error) {
            if (error.isCancelled()) co_return true;
            throw;
        }
    }
    co_return true;
}

Task<bool> LoginView::completeLoginAsync(QString cookie, CancellationToken ct, int generation)
{
    auto alive = m_alive;
    const QString normalized = NeteaseCookieNormalizer::normalize(cookie);
    std::optional<AccountInfo> account;
    try {
        account = co_await NeteaseProvider::shared().fetchAccountInfo(normalized, ct);
    } catch (const MusicException& error) {
        if (*alive && !error.isCancelled() && generation == m_generation && !ct.isCancellationRequested()) {
            showError(QStringLiteral("%1: %2").arg(L10n::Login::Failed, error.userFacingMessage()));
        }
        co_return true;
    } catch (const std::exception& error) {
        if (*alive && generation == m_generation && !ct.isCancellationRequested()) {
            showError(QStringLiteral("%1: %2")
                          .arg(L10n::Login::Failed,
                              MusicException::unknown(QString::fromUtf8(error.what())).userFacingMessage()));
        }
        co_return true;
    }

    if (!*alive || generation != m_generation || ct.isCancellationRequested()) co_return true;

    if (!account.has_value()) {
        showError(L10n::Login::Failed);
        co_return true;
    }

    CredentialStore::shared().save(normalized.isEmpty() ? cookie : normalized, CredentialKey::NeteaseCookie);

    try {
        co_await AppState::shared().didLogin(*account);
    } catch (const MusicException& error) {
        if (*alive && generation == m_generation) showError(error.userFacingMessage());
        co_return true;
    } catch (const std::exception& error) {
        if (*alive && generation == m_generation) {
            showError(MusicException::unknown(QString::fromUtf8(error.what())).userFacingMessage());
        }
        co_return true;
    }

    if (*alive && generation == m_generation) {
        AppState::shared().setIsLoginPresented(false);
    }
    co_return true;
}

void LoginView::showError(const QString& message)
{
    m_errorText->setText(message);
    m_errorText->show();
    m_retryButton->show();
    m_spinner->hide();
}

void LoginView::setQRCode(const QImage& image)
{
    if (image.isNull()) {
        m_qrImage->clear();
        return;
    }
    m_qrImage->setPixmap(QPixmap::fromImage(image).scaled(
        m_qrImage->size(), Qt::KeepAspectRatio, Qt::SmoothTransformation));
}

CT_REGISTER_OVERLAY(OverlayKind::Login, LoginView);

} // namespace ct
