#include "Features/Radio/RadioView.h"

#include "App/AppState.h"
#include "DesignSystem/CTTheme.h"
#include "DesignSystem/CoverImage.h"
#include "DesignSystem/L10n.h"
#include "Features/Shared/PageFactory.h"
#include "Features/Shared/UIComponents.h"
#include "Providers/Netease/NeteaseProvider.h"

#include <QGridLayout>
#include <QHBoxLayout>
#include <QLabel>
#include <QPushButton>
#include <QScrollArea>
#include <QVBoxLayout>

#include <utility>

namespace ct {

namespace {

NeteaseProvider* neteaseProvider()
{
    if (auto* provider = dynamic_cast<NeteaseProvider*>(AppState::shared().provider())) {
        return provider;
    }
    return &NeteaseProvider::shared();
}

void clearLayout(QLayout* layout)
{
    while (QLayoutItem* item = layout->takeAt(0)) {
        if (QWidget* widget = item->widget()) widget->deleteLater();
        if (QLayout* child = item->layout()) {
            clearLayout(child);
            child->deleteLater();
        }
        delete item;
    }
}

QString unknownUserMessage(const std::exception& error)
{
    return MusicException::unknown(QString::fromUtf8(error.what())).userFacingMessage();
}

} // namespace

RadioView::RadioView(QWidget* parent)
    : QWidget(parent)
{
    setObjectName(QStringLiteral("ctRadioView"));
    setStyleSheet(QStringLiteral("QWidget#ctRadioView { background: %1; }")
                      .arg(CTColors::background().name()));

    auto* root = new QVBoxLayout(this);
    root->setContentsMargins(0, 0, 0, 0);
    root->setSpacing(0);

    auto* titleStack = new QWidget(this);
    auto* titleLayout = new QVBoxLayout(titleStack);
    titleLayout->setContentsMargins(CTSpacing::Xl, CTSpacing::Xl, CTSpacing::Xl, CTSpacing::Md);
    titleLayout->setSpacing(CTSpacing::Xs);
    titleLayout->addWidget(ui::titleLabel(QStringLiteral("电台"), CTTypography::PageTitle, true));
    m_subtitle = ui::secondaryLabel(QStringLiteral("主播的声音，长音频节目。"));
    titleLayout->addWidget(m_subtitle);
    root->addWidget(titleStack);

    auto* chipContent = new QWidget();
    m_chipLayout = new QHBoxLayout(chipContent);
    m_chipLayout->setContentsMargins(0, 0, 0, 0);
    m_chipLayout->setSpacing(CTSpacing::Sm);
    m_chipScroll = new QScrollArea(this);
    m_chipScroll->setWidgetResizable(true);
    m_chipScroll->setFrameShape(QFrame::NoFrame);
    m_chipScroll->setFixedHeight(44);
    m_chipScroll->setHorizontalScrollBarPolicy(Qt::ScrollBarAsNeeded);
    m_chipScroll->setVerticalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    m_chipScroll->setStyleSheet(QStringLiteral("QScrollArea { background: transparent; }"));
    m_chipScroll->setWidget(chipContent);
    root->addWidget(m_chipScroll);

    m_host = new QWidget(this);
    m_hostLayout = new QVBoxLayout(m_host);
    m_hostLayout->setContentsMargins(0, 0, 0, 0);
    m_hostLayout->setSpacing(0);
    root->addWidget(m_host, 1);

    render();
}

RadioView::~RadioView()
{
    *m_alive = false;
}

void RadioView::showEvent(QShowEvent* event)
{
    QWidget::showEvent(event);
    if (!m_categoriesLoaded) {
        m_categoriesLoaded = true;
        loadCategories();
    }
    if (!m_loaded) {
        m_loaded = true;
        loadRadios();
    }
}

void RadioView::resizeEvent(QResizeEvent* event)
{
    QWidget::resizeEvent(event);
    if (!*m_alive || m_radios.isEmpty()) return;
    if (gridColumns() != m_lastColumns) renderList();
}

int RadioView::gridColumns() const
{
    const int available = qMax(0, width() - 2 * static_cast<int>(CTSpacing::Xl));
    return qMax(1, available / (160 + static_cast<int>(CTSpacing::Lg)));
}

void RadioView::loadCategories()
{
    const quint64 token = m_loadToken;
    detach(loadCategoriesAsync(token));
}

Task<void> RadioView::loadCategoriesAsync(quint64 token)
{
    auto alive = m_alive;
    Q_UNUSED(token);
    try {
        m_categories = co_await neteaseProvider()->fetchRadioCategories(CancellationToken::none());
    } catch (const MusicException&) {
        if (!*alive) co_return;
        m_categories.clear();
    } catch (const std::exception&) {
        if (!*alive) co_return;
        m_categories.clear();
    }
    if (!*alive) co_return;
    renderChips();
}

void RadioView::loadRadios()
{
    const quint64 token = ++m_loadToken;
    m_isLoading = true;
    m_errorMessage.reset();
    render();
    detach(loadRadiosAsync(token));
}

Task<void> RadioView::loadRadiosAsync(quint64 token)
{
    auto alive = m_alive;
    const std::optional<QString> category = m_selectedCategoryID;
    try {
        QList<RadioStation> loaded;
        if (category.has_value() && !category->isEmpty()) {
            loaded = co_await neteaseProvider()->fetchHotRadios(category, 40, CancellationToken::none());
        } else {
            loaded = co_await neteaseProvider()->fetchRecommendedRadios(40, CancellationToken::none());
            if (loaded.isEmpty()) {
                loaded = co_await neteaseProvider()->fetchHotRadios(
                    std::nullopt, 40, CancellationToken::none());
            }
        }
        if (!*alive || token != m_loadToken) co_return;
        m_radios = loaded;
    } catch (const MusicException& error) {
        if (!*alive || token != m_loadToken) co_return;
        m_radios.clear();
        m_errorMessage = error.userFacingMessage();
    } catch (const std::exception& error) {
        if (!*alive || token != m_loadToken) co_return;
        m_radios.clear();
        m_errorMessage = unknownUserMessage(error);
    }
    if (!*alive || token != m_loadToken) co_return;
    m_isLoading = false;
    render();
}

void RadioView::selectCategory(const std::optional<QString>& id)
{
    if (m_selectedCategoryID == id) return;
    m_selectedCategoryID = id;
    renderChips();
    loadRadios();
}

void RadioView::render()
{
    if (!*m_alive) return;
    m_chipScroll->setVisible(!m_categories.isEmpty());
    m_subtitle->setText(m_isLoading && m_radios.isEmpty() ? QStringLiteral("正在获取电台…")
                                                          : QStringLiteral("主播的声音，长音频节目。"));
    renderList();
}

void RadioView::renderChips()
{
    clearLayout(m_chipLayout);
    m_chipLayout->addWidget(buildChip(QStringLiteral("全部"), std::nullopt));
    for (const RadioCategory& category : m_categories) {
        m_chipLayout->addWidget(buildChip(category.name, category.id));
    }
    m_chipLayout->addStretch(1);
    m_chipScroll->setVisible(!m_categories.isEmpty());
}

QWidget* RadioView::buildChip(const QString& title, const std::optional<QString>& id)
{
    const bool selected = m_selectedCategoryID == id;
    auto* button = new QPushButton(title);
    button->setCursor(Qt::PointingHandCursor);
    button->setStyleSheet(QStringLiteral(
        "QPushButton { background: %1; color: %2; border: none; border-radius: %3px;"
        " padding: 5px 12px; font-size: 12px; }")
                              .arg(selected ? CTColors::accent().name() : CTColors::overlay().name(),
                                  selected ? QStringLiteral("white") : CTColors::textSecondary().name())
                              .arg(CTRadius::Small));
    connect(button, &QPushButton::clicked, this, [this, id] { selectCategory(id); });
    return button;
}

void RadioView::renderList()
{
    clearLayout(m_hostLayout);
    if (m_isLoading && m_radios.isEmpty()) {
        m_hostLayout->addWidget(ui::statusPanel(L10n::Common::Loading, true));
        return;
    }
    if (m_errorMessage.has_value() && m_radios.isEmpty()) {
        m_hostLayout->addWidget(ui::errorPanel(*m_errorMessage, [this] { loadRadios(); }));
        return;
    }
    if (m_radios.isEmpty()) {
        m_hostLayout->addWidget(ui::statusPanel(QStringLiteral("没有找到电台"), false));
        return;
    }

    auto* content = new QWidget();
    auto* grid = new QGridLayout(content);
    grid->setContentsMargins(CTSpacing::Xl, 0, CTSpacing::Xl, CTSpacing::Xl);
    grid->setHorizontalSpacing(CTSpacing::Lg);
    grid->setVerticalSpacing(CTSpacing::Lg);
    const int columns = gridColumns();
    m_lastColumns = columns;
    for (int index = 0; index < m_radios.size(); ++index) {
        grid->addWidget(buildRadioCard(m_radios.at(index)), index / columns, index % columns,
            Qt::AlignTop | Qt::AlignLeft);
    }
    grid->setColumnStretch(columns, 1);
    m_hostLayout->addWidget(ui::scrollWrapper(content), 1);
}

QWidget* RadioView::buildRadioCard(const RadioStation& radio)
{
    auto* card = new ui::CardButton();
    card->setFixedWidth(160);
    auto* layout = new QVBoxLayout(card);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(CTSpacing::Sm);

    auto* cover = new CoverImage(card);
    cover->setFixedSize(160, 160);
    cover->setCornerRadius(CTRadius::Medium);
    cover->setCoverURL(radio.coverURL, 320);
    layout->addWidget(cover, 0, Qt::AlignHCenter);

    auto* name = ui::titleElidedLabel(radio.name, CTTypography::Body, true);
    name->setMaximumWidth(160);
    layout->addWidget(name);

    QStringList parts;
    if (radio.creatorName.has_value() && !radio.creatorName->isEmpty()) {
        parts.append(*radio.creatorName);
    }
    if (radio.programCount > 0) parts.append(QStringLiteral("%1 期").arg(radio.programCount));
    auto* meta = ui::secondaryElidedLabel(
        parts.isEmpty() ? QStringLiteral("电台") : parts.join(QStringLiteral(" · ")));
    meta->setMaximumWidth(160);
    layout->addWidget(meta);

    const QString id = radio.id;
    card->onClicked = [id] { AppState::shared().openRadio(id); };
    return card;
}

CT_REGISTER_PAGE(Page::Radio, RadioView);

} // namespace ct
