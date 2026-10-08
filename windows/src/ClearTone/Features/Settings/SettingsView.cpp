#include "Features/Settings/SettingsView.h"

#include "App/AppState.h"
#include "Core/Models/MusicModels.h"
#include "Core/Persistence/PersistenceStore.h"
#include "DesignSystem/CTTheme.h"
#include "DesignSystem/L10n.h"
#include "Features/Shared/PageFactory.h"
#include "Features/Shared/UIComponents.h"
#include "Playback/AudioCacheManager.h"
#include "Playback/PlayerController.h"
#include "Playback/SongQuality.h"

#include <QCheckBox>
#include <QComboBox>
#include <QCoreApplication>
#include <QDoubleSpinBox>
#include <QFrame>
#include <QGuiApplication>
#include <QHBoxLayout>
#include <QLabel>
#include <QPushButton>
#include <QScrollArea>
#include <QStyleHints>
#include <QVBoxLayout>

#include <cmath>

namespace ct {

namespace {

QWidget* labeled(const QString& text, QWidget* control)
{
    auto* panel = new QWidget();
    auto* layout = new QVBoxLayout(panel);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(4);
    auto* label = new QLabel(text);
    label->setStyleSheet(
        QStringLiteral("color: %1; font-weight: 500;").arg(CTColors::textPrimary().name()));
    layout->addWidget(label);
    layout->addWidget(control);
    return panel;
}

QWidget* hint(const QString& text)
{
    auto* label = ui::secondaryLabel(text);
    label->setWordWrap(true);
    return label;
}

QWidget* section(const QString& title, QWidget* content)
{
    auto* container = new QWidget();
    auto* layout = new QVBoxLayout(container);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(CTSpacing::Sm);
    layout->addWidget(ui::titleLabel(title, CTTypography::SectionTitle, true));

    auto* frame = new QFrame(container);
    frame->setObjectName(QStringLiteral("ctCard"));
    frame->setStyleSheet(QStringLiteral("QFrame#ctCard { background: %1; border-radius: %2px; }")
                             .arg(CTColors::panel().name())
                             .arg(CTRadius::Medium));
    auto* cardLayout = new QVBoxLayout(frame);
    cardLayout->setContentsMargins(CTSpacing::Lg, CTSpacing::Lg, CTSpacing::Lg, CTSpacing::Lg);
    cardLayout->addWidget(content);
    layout->addWidget(frame);
    return container;
}

int qualityIndex(QualityLevel level)
{
    if (level == songQualityPolicy::autoLevel) return 0;
    const QList<QualityLevel>& levels = songQualityPolicy::selectableLevels;
    for (int index = 0; index < levels.size(); ++index) {
        if (levels[index] == level) return index + 1;
    }
    return 0;
}

QualityLevel qualityFromIndex(int index)
{
    if (index <= 0) return songQualityPolicy::autoLevel;
    const QList<QualityLevel>& levels = songQualityPolicy::selectableLevels;
    return index - 1 < levels.size() ? levels[index - 1] : songQualityPolicy::autoLevel;
}

void applyTheme(CTThemeMode mode)
{
#if QT_VERSION >= QT_VERSION_CHECK(6, 8, 0)
    QStyleHints* hints = QGuiApplication::styleHints();
    if (hints == nullptr) return;
    switch (mode) {
    case CTThemeMode::Dark:
        hints->setColorScheme(Qt::ColorScheme::Dark);
        break;
    case CTThemeMode::Light:
        hints->setColorScheme(Qt::ColorScheme::Light);
        break;
    case CTThemeMode::System:
        hints->unsetColorScheme();
        break;
    }
#else
    Q_UNUSED(mode);
#endif
}

} // namespace

SettingsView::SettingsView(QWidget* parent)
    : QWidget(parent)
{
    buildUi();
    loadSettings();

    m_appObserver = AppState::shared().changed.subscribe([this] {
        updateAccount();
        updateAutoQualityLabel();
    });
}

SettingsView::~SettingsView()
{
    *m_alive = false;
    AppState::shared().changed.unsubscribe(m_appObserver);
}

void SettingsView::showEvent(QShowEvent* event)
{
    QWidget::showEvent(event);
    loadSettings();
}

void SettingsView::buildUi()
{
    setObjectName(QStringLiteral("ctSettingsView"));
    setStyleSheet(QStringLiteral("QWidget#ctSettingsView { background: %1; }")
                      .arg(CTColors::background().name()));

    auto* root = new QVBoxLayout(this);
    root->setContentsMargins(0, 0, 0, 0);
    root->setSpacing(0);

    auto* titleStack = new QWidget(this);
    auto* titleLayout = new QVBoxLayout(titleStack);
    titleLayout->setContentsMargins(0, 0, 0, 0);
    titleLayout->setSpacing(CTSpacing::Xs);
    titleLayout->addWidget(ui::titleLabel(QStringLiteral("设置"), CTTypography::PageTitle, true));
    titleLayout->addWidget(ui::secondaryLabel(QStringLiteral("外观、播放与账号。")));

    m_saveHint = ui::secondaryLabel(QString());
    m_saveHint->setAlignment(Qt::AlignVCenter);

    auto* saveButton = ui::accentButton(QStringLiteral("保存设置"));
    connect(saveButton, &QPushButton::clicked, this, [this] {
        save();
        m_saveHint->setText(QStringLiteral("已保存"));
    });

    auto* header = new QWidget(this);
    auto* headerLayout = new QHBoxLayout(header);
    headerLayout->setContentsMargins(CTSpacing::Xl, CTSpacing::Xl, CTSpacing::Xl, CTSpacing::Lg);
    headerLayout->addWidget(titleStack);
    headerLayout->addStretch(1);
    headerLayout->addWidget(m_saveHint);
    headerLayout->addWidget(saveButton);
    root->addWidget(header);

    auto* body = new QWidget();
    auto* bodyLayout = new QVBoxLayout(body);
    bodyLayout->setContentsMargins(CTSpacing::Xl, 0, CTSpacing::Xl, CTSpacing::Xl);
    bodyLayout->setSpacing(CTSpacing::Xl);
    buildSections(body);
    bodyLayout->addStretch(1);

    auto* scroll = ui::scrollWrapper(body);
    scroll->setParent(this);
    root->addWidget(scroll, 1);
}

void SettingsView::buildSections(QWidget* body)
{
    auto* bodyLayout = qobject_cast<QVBoxLayout*>(body->layout());

    m_themeBox = new QComboBox();
    m_themeBox->addItems({QStringLiteral("跟随系统"), QStringLiteral("深色"), QStringLiteral("浅色")});
    m_resumeBox = new QCheckBox(QStringLiteral("启动时恢复上次播放"));
    m_cacheBox = new QCheckBox(QStringLiteral("缓存播放的音乐（128kbps OPUS）"));
    m_qualityBox = new QComboBox();
    m_closeBox = new QComboBox();
    for (const CloseBehavior behavior :
        {CloseBehavior::KeepPlaying, CloseBehavior::MinimizeToMenuBar, CloseBehavior::Quit}) {
        m_closeBox->addItem(closeBehavior::displayName(behavior));
    }
    m_menuBarBox = new QCheckBox(QStringLiteral("菜单栏常驻"));
    m_miniTopBox = new QCheckBox(QStringLiteral("迷你播放器置顶"));
    m_performanceBox = new QComboBox();
    for (const PerformanceMode mode :
        {PerformanceMode::Auto, PerformanceMode::Saver, PerformanceMode::Quality, PerformanceMode::Static}) {
        m_performanceBox->addItem(performanceMode::displayName(mode));
    }
    m_spectrumBox = new QComboBox();
    for (const SpectrumMode mode : {SpectrumMode::Ambient, SpectrumMode::Off}) {
        m_spectrumBox->addItem(spectrumMode::displayName(mode));
    }
    m_offsetBox = new QDoubleSpinBox();
    m_offsetBox->setRange(-10, 10);
    m_offsetBox->setSingleStep(0.1);
    m_offsetBox->setDecimals(1);
    m_offsetBox->setFixedWidth(120);

    m_closeHint = ui::secondaryLabel(QString());
    m_closeHint->setWordWrap(true);
    m_offsetDescription = ui::secondaryLabel(QString());
    m_cacheSizeText = ui::secondaryLabel(QString());

    auto* appearance = new QWidget();
    auto* appearanceLayout = new QVBoxLayout(appearance);
    appearanceLayout->setContentsMargins(0, 0, 0, 0);
    appearanceLayout->setSpacing(CTSpacing::Md);
    appearanceLayout->addWidget(labeled(QStringLiteral("主题"), m_themeBox));
    appearanceLayout->addWidget(hint(QStringLiteral("深色与浅色只影响应用外观，随时可以改回跟随系统。")));
    bodyLayout->addWidget(section(QStringLiteral("外观"), appearance));

    auto* playback = new QWidget();
    auto* playbackLayout = new QVBoxLayout(playback);
    playbackLayout->setContentsMargins(0, 0, 0, 0);
    playbackLayout->setSpacing(CTSpacing::Md);
    playbackLayout->addWidget(m_resumeBox);
    playbackLayout->addWidget(
        hint(QStringLiteral("启动时接着上次的位置继续播放，而不是从队列第一首开始。")));
    playbackLayout->addWidget(ui::separator());
    playbackLayout->addWidget(labeled(QStringLiteral("默认音质"), m_qualityBox));
    playbackLayout->addWidget(hint(QStringLiteral(
        "只对本地没有缓存、必须走在线流的歌曲生效。选「自动」时按会员状态决定：VIP 走无损，否则走极高。")));
    playbackLayout->addWidget(ui::separator());
    playbackLayout->addWidget(m_cacheBox);
    playbackLayout->addWidget(hint(QStringLiteral(
        "听过的网易云歌曲会转成缓存，再次播放优先使用；单条最多保留 7 天，过期后重新拉流。")));
    auto* cacheRow = new QWidget();
    auto* cacheRowLayout = new QHBoxLayout(cacheRow);
    cacheRowLayout->setContentsMargins(0, 0, 0, 0);
    cacheRowLayout->addWidget(m_cacheSizeText);
    cacheRowLayout->addStretch(1);
    m_clearCacheButton = ui::ghostButton(QStringLiteral("清空缓存"));
    cacheRowLayout->addWidget(m_clearCacheButton);
    playbackLayout->addWidget(cacheRow);
    bodyLayout->addWidget(section(QStringLiteral("播放"), playback));

    auto* window = new QWidget();
    auto* windowLayout = new QVBoxLayout(window);
    windowLayout->setContentsMargins(0, 0, 0, 0);
    windowLayout->setSpacing(CTSpacing::Md);
    windowLayout->addWidget(labeled(QStringLiteral("关闭窗口时"), m_closeBox));
    windowLayout->addWidget(m_closeHint);
    windowLayout->addWidget(m_menuBarBox);
    windowLayout->addWidget(hint(QStringLiteral(
        "只要应用在运行就显示菜单栏图标，不受「关闭窗口时」影响。关掉它时，图标只在选了「缩到菜单栏」且当前没有窗口时出现。")));
    windowLayout->addWidget(m_miniTopBox);
    bodyLayout->addWidget(section(QStringLiteral("窗口"), window));

    auto* performance = new QWidget();
    auto* performanceLayout = new QVBoxLayout(performance);
    performanceLayout->setContentsMargins(0, 0, 0, 0);
    performanceLayout->setSpacing(CTSpacing::Md);
    performanceLayout->addWidget(labeled(QStringLiteral("性能模式"), m_performanceBox));
    performanceLayout->addWidget(labeled(QStringLiteral("频谱显示"), m_spectrumBox));
    performanceLayout->addWidget(hint(QStringLiteral(
        "背景呈现方式。真实频谱需要读取音频采样，当前播放链路拿不到，因此不提供真实频谱选项。")));
    bodyLayout->addWidget(section(QStringLiteral("性能"), performance));

    auto* lyrics = new QWidget();
    auto* lyricsLayout = new QVBoxLayout(lyrics);
    lyricsLayout->setContentsMargins(0, 0, 0, 0);
    lyricsLayout->setSpacing(CTSpacing::Md);
    auto* offsetRow = new QWidget();
    auto* offsetRowLayout = new QHBoxLayout(offsetRow);
    offsetRowLayout->setContentsMargins(0, 0, 0, 0);
    auto* offsetLabel = new QLabel(QStringLiteral("时间偏移"));
    offsetLabel->setStyleSheet(QStringLiteral("color: %1;").arg(CTColors::textPrimary().name()));
    offsetRowLayout->addWidget(offsetLabel);
    offsetRowLayout->addStretch(1);
    offsetRowLayout->addWidget(m_offsetBox);
    offsetRowLayout->addSpacing(CTSpacing::Md);
    offsetRowLayout->addWidget(m_offsetDescription);
    lyricsLayout->addWidget(offsetRow);
    lyricsLayout->addWidget(hint(QStringLiteral("字幕比音频早或晚时在这里微调。正值表示歌词提前。")));
    bodyLayout->addWidget(section(QStringLiteral("歌词"), lyrics));

    auto* account = new QWidget();
    auto* accountLayout = new QHBoxLayout(account);
    accountLayout->setContentsMargins(0, 0, 0, 0);
    m_accountText = new QLabel();
    m_accountText->setStyleSheet(QStringLiteral("color: %1;").arg(CTColors::textPrimary().name()));
    accountLayout->addWidget(m_accountText);
    accountLayout->addStretch(1);
    m_logoutButton = ui::ghostButton(L10n::Common::Logout);
    accountLayout->addWidget(m_logoutButton);
    bodyLayout->addWidget(section(QStringLiteral("账号"), account));

    auto* about = new QWidget();
    auto* aboutLayout = new QVBoxLayout(about);
    aboutLayout->setContentsMargins(0, 0, 0, 0);
    aboutLayout->setSpacing(CTSpacing::Xs);
    const QString version = QCoreApplication::applicationVersion();
    auto* versionLabel = new QLabel(version.isEmpty() ? QStringLiteral("澄音 v0.1.0")
                                                      : QStringLiteral("澄音 v%1").arg(version));
    versionLabel->setStyleSheet(QStringLiteral("color: %1;").arg(CTColors::textPrimary().name()));
    aboutLayout->addWidget(versionLabel);
    aboutLayout->addWidget(hint(QStringLiteral("第三方网易云音乐客户端，与网易公司无关联")));
    bodyLayout->addWidget(section(QStringLiteral("关于"), about));

    connect(m_themeBox, &QComboBox::currentIndexChanged, this, [this] { save(); });
    connect(m_resumeBox, &QCheckBox::toggled, this, [this] { save(); });
    connect(m_cacheBox, &QCheckBox::toggled, this, [this] { save(); });
    connect(m_qualityBox, &QComboBox::currentIndexChanged, this, [this] { save(); });
    connect(m_closeBox, &QComboBox::currentIndexChanged, this, [this] {
        updateCloseHint();
        save();
    });
    connect(m_menuBarBox, &QCheckBox::toggled, this, [this] { save(); });
    connect(m_miniTopBox, &QCheckBox::toggled, this, [this] { save(); });
    connect(m_performanceBox, &QComboBox::currentIndexChanged, this, [this] { save(); });
    connect(m_spectrumBox, &QComboBox::currentIndexChanged, this, [this] { save(); });
    connect(m_offsetBox, &QDoubleSpinBox::valueChanged, this, [this] {
        updateOffsetDescription();
        save();
    });
    connect(m_clearCacheButton, &QPushButton::clicked, this, [this] {
        AudioCacheManager::shared().clearAll();
        updateCacheSize();
    });
    connect(m_logoutButton, &QPushButton::clicked, this, [this] { detach(logoutAsync()); });
}

void SettingsView::loadSettings()
{
    const QJsonValue stored = PersistenceStore::shared().loadSetting(QStringLiteral("appSettings"));
    m_settings = stored.isObject() ? AppSettings::fromJson(stored.toObject()) : AppSettings();

    m_loading = true;
    m_themeBox->setCurrentIndex(qBound(0, static_cast<int>(m_settings.themeMode), 2));
    m_resumeBox->setChecked(m_settings.resumePlaybackOnLaunch);
    m_cacheBox->setChecked(m_settings.audioCacheEnabled);

    m_qualityBox->clear();
    m_qualityBox->addItem(autoQualityLabel());
    for (const QualityLevel level : songQualityPolicy::selectableLevels) {
        m_qualityBox->addItem(quality::displayName(level));
    }
    m_qualityBox->setCurrentIndex(qualityIndex(m_settings.preferredQuality));

    m_closeBox->setCurrentIndex(qBound(0, static_cast<int>(m_settings.closeBehavior), 2));
    m_menuBarBox->setChecked(m_settings.menuBarAlwaysVisible);
    m_miniTopBox->setChecked(m_settings.miniPlayerAlwaysOnTop);
    m_performanceBox->setCurrentIndex(qBound(0, static_cast<int>(m_settings.performanceMode), 3));
    m_spectrumBox->setCurrentIndex(qBound(0, static_cast<int>(m_settings.spectrumMode), 1));
    m_offsetBox->setValue(m_settings.lyricOffset);
    m_loading = false;

    m_saveHint->clear();
    updateAccount();
    updateCloseHint();
    updateOffsetDescription();
    updateCacheSize();
}

void SettingsView::save()
{
    if (m_loading) return;

    m_settings.themeMode = static_cast<CTThemeMode>(qBound(0, m_themeBox->currentIndex(), 2));
    m_settings.resumePlaybackOnLaunch = m_resumeBox->isChecked();
    m_settings.audioCacheEnabled = m_cacheBox->isChecked();
    m_settings.preferredQuality = qualityFromIndex(m_qualityBox->currentIndex());
    m_settings.closeBehavior = static_cast<CloseBehavior>(qBound(0, m_closeBox->currentIndex(), 2));
    m_settings.menuBarAlwaysVisible = m_menuBarBox->isChecked();
    m_settings.miniPlayerAlwaysOnTop = m_miniTopBox->isChecked();
    m_settings.performanceMode =
        static_cast<PerformanceMode>(qBound(0, m_performanceBox->currentIndex(), 3));
    m_settings.spectrumMode = static_cast<SpectrumMode>(qBound(0, m_spectrumBox->currentIndex(), 1));
    m_settings.lyricOffset = m_offsetBox->value();

    PersistenceStore::shared().saveSetting(QStringLiteral("appSettings"), m_settings.toJson());
    AudioCacheManager::shared().setEnabled(m_settings.audioCacheEnabled);
    PlayerController::shared().setRequestedQuality(m_settings.preferredQuality);
    applyTheme(m_settings.themeMode);
}

void SettingsView::updateCloseHint()
{
    m_closeHint->setText(closeBehavior::help(static_cast<CloseBehavior>(qBound(0, m_closeBox->currentIndex(), 2))));
}

void SettingsView::updateOffsetDescription()
{
    const double value = m_offsetBox->value();
    if (std::abs(value) < 0.001) {
        m_offsetDescription->setText(QStringLiteral("0.0 秒"));
    } else if (value > 0) {
        m_offsetDescription->setText(QStringLiteral("提前 %1 秒").arg(value, 0, 'f', 1));
    } else {
        m_offsetDescription->setText(QStringLiteral("延后 %1 秒").arg(-value, 0, 'f', 1));
    }
}

void SettingsView::updateCacheSize()
{
    m_cacheSizeText->setText(
        QStringLiteral("缓存占用：%1").arg(AudioCacheManager::shared().formattedTotalSize()));
    m_clearCacheButton->setEnabled(AudioCacheManager::shared().totalCacheBytes() > 0);
}

void SettingsView::updateAccount()
{
    const AppState& app = AppState::shared();
    if (app.isLoggedIn()) {
        const std::optional<AccountInfo> account = app.account();
        m_accountText->setText(account && !account->nickname.isEmpty() ? account->nickname
                                                                       : QStringLiteral("已登录"));
    } else {
        m_accountText->setText(QStringLiteral("未登录"));
    }
    m_logoutButton->setVisible(app.isLoggedIn());
}

void SettingsView::updateAutoQualityLabel()
{
    if (m_qualityBox->count() == 0) return;
    m_qualityBox->setItemText(0, autoQualityLabel());
}

QString SettingsView::autoQualityLabel() const
{
    const bool isVIP = PlayerController::shared().isAccountVIP();
    const QualityLevel resolved = songQualityPolicy::defaultLevel(isVIP);
    return isVIP ? QStringLiteral("自动（VIP → %1）").arg(quality::displayName(resolved))
                 : QStringLiteral("自动（%1）").arg(quality::displayName(resolved));
}

Task<void> SettingsView::logoutAsync()
{
    auto alive = m_alive;
    try {
        co_await AppState::shared().performLogout();
    } catch (const MusicException&) {
    }
    if (!*alive) co_return;
    updateAccount();
    m_saveHint->clear();
    co_return;
}

CT_REGISTER_PAGE(Page::Settings, SettingsView);

} // namespace ct
