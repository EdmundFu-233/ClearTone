#include "Features/Social/MessagesView.h"

#include "App/AppState.h"
#include "DesignSystem/CTTheme.h"
#include "DesignSystem/CoverImage.h"
#include "Features/Shared/PageFactory.h"
#include "Features/Shared/UIComponents.h"
#include "Providers/Netease/NeteaseProvider.h"
#include "Providers/Netease/NeteaseSocialProvider.h"

#include <QFontMetrics>
#include <QFrame>
#include <QHBoxLayout>
#include <QLabel>
#include <QPushButton>
#include <QScrollArea>
#include <QVBoxLayout>

#include <utility>

namespace ct {

namespace {

IMusicSocialProvider& socialProvider()
{
    auto* session = AppState::shared().social();
    if (auto* social = dynamic_cast<IMusicSocialProvider*>(session)) return *social;
    return NeteaseSocialProvider::shared();
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

QString relativeTime(const QDateTime& date)
{
    if (!date.isValid()) return QString();
    const double seconds = date.msecsTo(QDateTime::currentDateTime()) / 1000.0;
    if (seconds < 60) return QStringLiteral("刚刚");
    if (seconds < 3600) return QStringLiteral("%1 分钟前").arg(static_cast<int>(seconds / 60));
    if (seconds < 86400) return QStringLiteral("%1 小时前").arg(static_cast<int>(seconds / 3600));
    if (seconds < 172800) return QStringLiteral("昨天");
    if (seconds < 604800) return QStringLiteral("%1 天前").arg(static_cast<int>(seconds / 86400));
    return date.toLocalTime().toString(QStringLiteral("yyyy-MM-dd"));
}

QString unknownUserMessage(const std::exception& error)
{
    return MusicException::unknown(QString::fromUtf8(error.what())).userFacingMessage();
}

QWidget* buildNoticeRow(const UserNotice& notice)
{
    auto* row = new QWidget();
    auto* layout = new QHBoxLayout(row);
    layout->setContentsMargins(CTSpacing::Lg, CTSpacing::Sm, CTSpacing::Lg, CTSpacing::Sm);
    layout->setSpacing(CTSpacing::Md);

    auto* avatar = new CoverImage(row);
    avatar->setFixedSize(34, 34);
    avatar->setCornerRadius(17);
    avatar->setCoverURL(notice.actorAvatarURL, 68);
    layout->addWidget(avatar, 0, Qt::AlignTop);

    auto* right = new QWidget(row);
    auto* rightLayout = new QVBoxLayout(right);
    rightLayout->setContentsMargins(0, 0, 0, 0);
    rightLayout->setSpacing(3);

    auto* top = new QWidget(right);
    auto* topLayout = new QHBoxLayout(top);
    topLayout->setContentsMargins(0, 0, 0, 0);
    topLayout->setSpacing(CTSpacing::Sm);
    auto* kind = new QLabel(notice.kind.label());
    kind->setStyleSheet(QStringLiteral("color: %1; font-size: 12px;").arg(CTColors::accent().name()));
    topLayout->addWidget(kind);
    if (notice.actorNickname.has_value() && !notice.actorNickname->isEmpty()) {
        topLayout->addWidget(ui::titleLabel(*notice.actorNickname, CTTypography::Body, true));
    }
    topLayout->addWidget(ui::secondaryLabel(relativeTime(notice.time)));
    topLayout->addStretch(1);
    rightLayout->addWidget(top);

    if (notice.content.has_value() && !notice.content->isEmpty()) {
        auto* content = ui::secondaryLabel(*notice.content);
        content->setWordWrap(true);
        content->setMaximumWidth(720);
        rightLayout->addWidget(content);
    }
    if (notice.replyCommentText.has_value() && !notice.replyCommentText->isEmpty()) {
        auto* quote = new QFrame(right);
        quote->setObjectName(QStringLiteral("ctQuote"));
        quote->setStyleSheet(QStringLiteral("QFrame#ctQuote { background: %1; border-radius: %2px; }")
                                 .arg(CTColors::overlay().name())
                                 .arg(CTRadius::Small));
        auto* quoteLayout = new QVBoxLayout(quote);
        quoteLayout->setContentsMargins(CTSpacing::Xs, CTSpacing::Xs, CTSpacing::Xs, CTSpacing::Xs);
        auto* text = ui::secondaryLabel(QStringLiteral("「%1」").arg(*notice.replyCommentText));
        text->setWordWrap(true);
        text->setMaximumWidth(680);
        quoteLayout->addWidget(text);
        rightLayout->addWidget(quote);
    }
    layout->addWidget(right, 1);
    return row;
}

QWidget* buildConversationRow(const PrivateConversation& conversation, std::function<void()> onOpen)
{
    auto* row = new ui::CardButton();
    auto* layout = new QHBoxLayout(row);
    layout->setContentsMargins(CTSpacing::Lg, CTSpacing::Sm, CTSpacing::Lg, CTSpacing::Sm);
    layout->setSpacing(CTSpacing::Md);

    auto* avatar = new CoverImage(row);
    avatar->setFixedSize(40, 40);
    avatar->setCornerRadius(20);
    avatar->setCoverURL(conversation.avatarURL, 80);
    layout->addWidget(avatar, 0, Qt::AlignVCenter);

    auto* info = new QWidget(row);
    auto* infoLayout = new QVBoxLayout(info);
    infoLayout->setContentsMargins(0, 0, 0, 0);
    infoLayout->setSpacing(2);
    auto* nickname = new ui::ElidedLabel(conversation.nickname, info);
    nickname->setStyleSheet(QStringLiteral("color: %1; font-size: %2px; font-weight: 600;")
                                .arg(CTColors::textPrimary().name())
                                .arg(CTTypography::Body));
    infoLayout->addWidget(nickname);
    if (conversation.lastMessage.has_value() && !conversation.lastMessage->isEmpty()) {
        auto* lastMessage = new ui::ElidedLabel(*conversation.lastMessage, info);
        lastMessage->setStyleSheet(
            QStringLiteral("color: %1;").arg(CTColors::textSecondary().name()));
        infoLayout->addWidget(lastMessage);
    }
    layout->addWidget(info, 1);

    auto* status = new QWidget(row);
    auto* statusLayout = new QVBoxLayout(status);
    statusLayout->setContentsMargins(0, 0, 0, 0);
    statusLayout->setSpacing(4);
    statusLayout->setAlignment(Qt::AlignRight | Qt::AlignVCenter);
    if (conversation.lastTime.has_value()) {
        auto* time = ui::secondaryLabel(relativeTime(*conversation.lastTime));
        time->setAlignment(Qt::AlignRight);
        statusLayout->addWidget(time, 0, Qt::AlignRight);
    }
    if (conversation.unreadCount > 0) {
        auto* badge = new QLabel(QString::number(conversation.unreadCount), status);
        badge->setStyleSheet(QStringLiteral(
            "background: %1; color: white; border-radius: 9px; padding: 1px 6px; font-size: 11px;")
                                 .arg(CTColors::accent().name()));
        statusLayout->addWidget(badge, 0, Qt::AlignRight);
    }
    layout->addWidget(status, 0, Qt::AlignVCenter);

    row->onClicked = std::move(onOpen);
    return row;
}

QWidget* buildMyCommentRow(const MyComment& comment)
{
    auto* row = new QWidget();
    auto* layout = new QVBoxLayout(row);
    layout->setContentsMargins(CTSpacing::Lg, CTSpacing::Sm, CTSpacing::Lg, CTSpacing::Sm);
    layout->setSpacing(CTSpacing::Xs);

    auto* top = new QWidget(row);
    auto* topLayout = new QHBoxLayout(top);
    topLayout->setContentsMargins(0, 0, 0, 0);
    topLayout->setSpacing(CTSpacing::Sm);
    auto* kind = new QLabel(myCommentResourceKind::label(comment.resourceKind));
    kind->setStyleSheet(QStringLiteral("color: %1; font-size: 12px;").arg(CTColors::accent().name()));
    topLayout->addWidget(kind);
    topLayout->addWidget(ui::secondaryLabel(relativeTime(comment.time)));
    if (comment.likedCount > 0) {
        topLayout->addWidget(ui::secondaryLabel(QStringLiteral("%1 赞").arg(comment.likedCount)));
    }
    topLayout->addStretch(1);
    layout->addWidget(top);

    if (comment.repliedNickname.has_value()) {
        auto* replied = ui::secondaryLabel(QStringLiteral("回复 @%1：%2")
                                               .arg(comment.repliedNickname.value_or(QString()),
                                                   comment.repliedContent.value_or(QString())));
        replied->setWordWrap(true);
        replied->setMaximumWidth(720);
        layout->addWidget(replied);
    }

    auto* content = new QLabel(comment.content);
    content->setWordWrap(true);
    content->setMaximumWidth(720);
    content->setStyleSheet(QStringLiteral("color: %1;").arg(CTColors::textPrimary().name()));
    layout->addWidget(content);
    return row;
}

QString privateMessageKindLabel(PrivateMessageKind kind)
{
    switch (kind.type) {
    case PrivateMessageKindType::Image:
        return QStringLiteral("图片");
    case PrivateMessageKindType::Song:
        return QStringLiteral("歌曲");
    case PrivateMessageKindType::Album:
        return QStringLiteral("专辑");
    case PrivateMessageKindType::Playlist:
        return QStringLiteral("歌单");
    case PrivateMessageKindType::Text:
    case PrivateMessageKindType::Unknown:
        return QStringLiteral("消息");
    }
    return QStringLiteral("消息");
}

} // namespace

MessagesView::MessagesView(QWidget* parent)
    : QWidget(parent)
{
    setObjectName(QStringLiteral("ctMessagesView"));
    setStyleSheet(QStringLiteral("QWidget#ctMessagesView { background: %1; }")
                      .arg(CTColors::background().name()));

    auto* root = new QVBoxLayout(this);
    root->setContentsMargins(0, 0, 0, 0);
    root->setSpacing(0);

    auto* titleStack = new QWidget(this);
    auto* titleLayout = new QVBoxLayout(titleStack);
    titleLayout->setContentsMargins(0, 0, 0, 0);
    titleLayout->setSpacing(CTSpacing::Xs);
    titleLayout->addWidget(ui::titleLabel(QStringLiteral("消息"), CTTypography::PageTitle, true));
    titleLayout->addWidget(ui::secondaryLabel(QStringLiteral("评论、回复与私信都在这里。")));

    auto* refresh = ui::ghostButton(QStringLiteral("刷新"));
    connect(refresh, &QPushButton::clicked, this, [this] { refreshCurrentTab(); });

    auto* header = new QWidget(this);
    auto* headerLayout = new QHBoxLayout(header);
    headerLayout->setContentsMargins(CTSpacing::Xl, CTSpacing::Xl, CTSpacing::Xl, CTSpacing::Lg);
    headerLayout->addWidget(titleStack);
    headerLayout->addStretch(1);
    headerLayout->addWidget(refresh, 0, Qt::AlignVCenter);
    root->addWidget(header);

    m_tabsHost = new QWidget(this);
    m_tabsLayout = new QVBoxLayout(m_tabsHost);
    m_tabsLayout->setContentsMargins(CTSpacing::Xl, 0, CTSpacing::Xl, CTSpacing::Md);
    m_tabsLayout->setSpacing(0);
    root->addWidget(m_tabsHost);

    m_contentHost = new QWidget(this);
    m_contentLayout = new QVBoxLayout(m_contentHost);
    m_contentLayout->setContentsMargins(0, 0, 0, 0);
    m_contentLayout->setSpacing(0);
    root->addWidget(m_contentHost, 1);

    m_lastDataContextKey = AppState::shared().dataContextKey();
    m_appObserver = AppState::shared().changed.subscribe([this] { scheduleAppChange(); });
    m_contextObserver = AppState::shared().dataContextChanged.subscribe([this] { scheduleAppChange(); });
    render();
}

MessagesView::~MessagesView()
{
    *m_alive = false;
    AppState::shared().changed.unsubscribe(m_appObserver);
    AppState::shared().dataContextChanged.unsubscribe(m_contextObserver);
}

void MessagesView::showEvent(QShowEvent* event)
{
    QWidget::showEvent(event);
    m_isAttached = true;
    loadCurrentTab();
}

void MessagesView::hideEvent(QHideEvent* event)
{
    QWidget::hideEvent(event);
    m_isAttached = false;
}

void MessagesView::scheduleAppChange()
{
    if (m_appChangeScheduled) return;
    m_appChangeScheduled = true;
    QMetaObject::invokeMethod(
        this,
        [this] {
            m_appChangeScheduled = false;
            handleAppChange();
        },
        Qt::QueuedConnection);
}

void MessagesView::handleAppChange()
{
    const QString key = AppState::shared().dataContextKey();
    if (key == m_lastDataContextKey) return;
    m_lastDataContextKey = key;
    m_notices.clear();
    m_conversations.clear();
    m_myComments.clear();
    m_selectedConversation.reset();
    m_messages.clear();
    m_noticesToken++;
    m_conversationsToken++;
    m_myCommentsToken++;
    m_messagesToken++;
    if (m_isAttached) {
        loadCurrentTab();
    } else {
        render();
    }
}

void MessagesView::loadCurrentTab()
{
    switch (m_tab) {
    case MessageTab::Notices:
        detach(loadNoticesAsync());
        break;
    case MessageTab::Conversations:
        detach(loadConversationsAsync());
        break;
    case MessageTab::MyComments:
        detach(loadMyCommentsAsync());
        break;
    }
}

void MessagesView::refreshCurrentTab()
{
    if (m_tab == MessageTab::Conversations && m_selectedConversation.has_value()) {
        detach(openConversationAsync(*m_selectedConversation));
        return;
    }
    loadCurrentTab();
}

void MessagesView::switchTab(MessageTab tab)
{
    if (m_tab == tab) return;
    m_tab = tab;
    m_selectedConversation.reset();
    m_messages.clear();
    m_messagesToken++;
    render();
    loadCurrentTab();
}

void MessagesView::closeConversation()
{
    m_selectedConversation.reset();
    m_messages.clear();
    m_messagesToken++;
    render();
}

void MessagesView::markConversationRead(const PrivateConversation& conversation)
{
    for (int index = 0; index < m_conversations.size(); ++index) {
        if (m_conversations[index].id != conversation.id) continue;
        if (m_conversations[index].unreadCount == 0) return;
        m_conversations[index].unreadCount = 0;
        return;
    }
}

Task<void> MessagesView::loadNoticesAsync()
{
    auto alive = m_alive;
    const int token = ++m_noticesToken;
    m_loadingNotices = m_notices.isEmpty();
    m_noticesError.reset();
    render();
    try {
        const QList<UserNotice> loaded = co_await socialProvider().fetchNotices(30, CancellationToken::none());
        if (!*alive || m_noticesToken != token) co_return;
        m_notices = loaded;
    } catch (const MusicException& error) {
        if (!*alive || m_noticesToken != token) co_return;
        m_noticesError = error.userFacingMessage();
    } catch (const std::exception& error) {
        if (!*alive || m_noticesToken != token) co_return;
        m_noticesError = unknownUserMessage(error);
    }
    if (!*alive || m_noticesToken != token) co_return;
    m_loadingNotices = false;
    render();
    co_return;
}

Task<void> MessagesView::loadConversationsAsync()
{
    auto alive = m_alive;
    const int token = ++m_conversationsToken;
    m_loadingConversations = m_conversations.isEmpty();
    m_conversationsError.reset();
    render();
    try {
        const QList<PrivateConversation> loaded =
            co_await socialProvider().fetchPrivateConversations(30, 0, CancellationToken::none());
        if (!*alive || m_conversationsToken != token) co_return;
        m_conversations = loaded;
    } catch (const MusicException& error) {
        if (!*alive || m_conversationsToken != token) co_return;
        m_conversationsError = error.userFacingMessage();
    } catch (const std::exception& error) {
        if (!*alive || m_conversationsToken != token) co_return;
        m_conversationsError = unknownUserMessage(error);
    }
    if (!*alive || m_conversationsToken != token) co_return;
    m_loadingConversations = false;
    render();
    co_return;
}

Task<void> MessagesView::openConversationAsync(PrivateConversation conversation)
{
    auto alive = m_alive;
    m_selectedConversation = conversation;
    const int token = ++m_messagesToken;
    m_loadingMessages = true;
    m_messagesError.reset();
    m_messages.clear();
    render();
    try {
        const QList<PrivateMessage> loaded =
            co_await socialProvider().fetchPrivateMessages(conversation.userID, 50, CancellationToken::none());
        if (!*alive || m_messagesToken != token) co_return;
        m_messages = loaded;
        markConversationRead(conversation);
    } catch (const MusicException& error) {
        if (!*alive || m_messagesToken != token) co_return;
        m_messagesError = error.userFacingMessage();
    } catch (const std::exception& error) {
        if (!*alive || m_messagesToken != token) co_return;
        m_messagesError = unknownUserMessage(error);
    }
    if (!*alive || m_messagesToken != token) co_return;
    m_loadingMessages = false;
    render();
    co_return;
}

Task<void> MessagesView::loadMyCommentsAsync()
{
    auto alive = m_alive;
    const int token = ++m_myCommentsToken;
    m_loadingMyComments = m_myComments.isEmpty();
    m_myCommentsError.reset();
    render();
    try {
        const QList<MyComment> loaded = co_await socialProvider().fetchMyComments(30, CancellationToken::none());
        if (!*alive || m_myCommentsToken != token) co_return;
        m_myComments = loaded;
    } catch (const MusicException& error) {
        if (!*alive || m_myCommentsToken != token) co_return;
        m_myCommentsError = error.userFacingMessage();
    } catch (const std::exception& error) {
        if (!*alive || m_myCommentsToken != token) co_return;
        m_myCommentsError = unknownUserMessage(error);
    }
    if (!*alive || m_myCommentsToken != token) co_return;
    m_loadingMyComments = false;
    render();
    co_return;
}

void MessagesView::render()
{
    clearLayout(m_tabsLayout);
    clearLayout(m_contentLayout);

    if (!AppState::shared().canPerformWrite()) {
        m_tabsHost->hide();
        m_contentLayout->addWidget(buildLoginRequired());
        m_contentLayout->addStretch(1);
        return;
    }

    m_tabsHost->show();
    m_tabsLayout->addWidget(buildTabRow());

    switch (m_tab) {
    case MessageTab::Notices:
        m_contentLayout->addWidget(buildNoticesPane(), 1);
        break;
    case MessageTab::Conversations:
        m_contentLayout->addWidget(buildConversationsPane(), 1);
        break;
    case MessageTab::MyComments:
        m_contentLayout->addWidget(buildMyCommentsPane(), 1);
        break;
    }
}

QWidget* MessagesView::buildLoginRequired()
{
    auto* panel = new QWidget();
    auto* layout = new QVBoxLayout(panel);
    layout->setContentsMargins(0, 60, 0, 60);
    layout->setSpacing(CTSpacing::Md);
    layout->setAlignment(Qt::AlignCenter);

    auto* hint = new QLabel(QStringLiteral("登录后查看通知与私信"));
    hint->setStyleSheet(QStringLiteral("color: %1;").arg(CTColors::textSecondary().name()));
    hint->setAlignment(Qt::AlignCenter);
    layout->addWidget(hint, 0, Qt::AlignHCenter);

    auto* login = ui::accentButton(QStringLiteral("去登录"));
    connect(login, &QPushButton::clicked, this, [] {
        AppState::shared().setIsLoginPresented(true);
    });
    layout->addWidget(login, 0, Qt::AlignHCenter);
    return panel;
}

QWidget* MessagesView::buildTabRow()
{
    auto* row = new QWidget();
    auto* layout = new QHBoxLayout(row);
    layout->setContentsMargins(CTSpacing::Xl, 0, CTSpacing::Xl, 0);
    layout->setSpacing(CTSpacing::Sm);

    auto makeTab = [this](MessageTab tab, const QString& text) {
        QPushButton* button = nullptr;
        if (m_tab == tab) {
            button = ui::accentButton(text);
        } else {
            button = ui::ghostButton(text);
        }
        connect(button, &QPushButton::clicked, this, [this, tab] { switchTab(tab); });
        return button;
    };
    layout->addWidget(makeTab(MessageTab::Notices, QStringLiteral("通知")));
    layout->addWidget(makeTab(MessageTab::Conversations, QStringLiteral("私信")));
    layout->addWidget(makeTab(MessageTab::MyComments, QStringLiteral("我的评论")));
    layout->addStretch(1);
    return row;
}

QWidget* MessagesView::buildNoticesPane()
{
    if (m_loadingNotices && m_notices.isEmpty()) {
        return ui::statusPanel(QStringLiteral("加载中…"), true);
    }
    if (m_noticesError.has_value()) {
        return ui::errorPanel(*m_noticesError, [this] { detach(loadNoticesAsync()); });
    }
    if (m_notices.isEmpty()) return ui::statusPanel(QStringLiteral("暂无内容"), false);

    auto* container = new QWidget();
    auto* layout = new QVBoxLayout(container);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(0);
    for (const UserNotice& notice : std::as_const(m_notices)) {
        layout->addWidget(buildNoticeRow(notice));
        layout->addWidget(ui::separator());
    }
    layout->addStretch(1);
    return ui::scrollWrapper(container);
}

QWidget* MessagesView::buildConversationsPane()
{
    if (m_selectedConversation.has_value()) return buildConversationDetail();
    if (m_loadingConversations && m_conversations.isEmpty()) {
        return ui::statusPanel(QStringLiteral("加载中…"), true);
    }
    if (m_conversationsError.has_value()) {
        return ui::errorPanel(*m_conversationsError, [this] { detach(loadConversationsAsync()); });
    }
    if (m_conversations.isEmpty()) return ui::statusPanel(QStringLiteral("暂无内容"), false);

    auto* container = new QWidget();
    auto* layout = new QVBoxLayout(container);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(0);
    for (const PrivateConversation& conversation : std::as_const(m_conversations)) {
        const PrivateConversation copy = conversation;
        layout->addWidget(buildConversationRow(copy, [this, copy] {
            detach(openConversationAsync(copy));
        }));
    }
    layout->addStretch(1);
    return ui::scrollWrapper(container);
}

QWidget* MessagesView::buildConversationDetail()
{
    const PrivateConversation conversation = *m_selectedConversation;

    auto* panel = new QWidget();
    auto* layout = new QVBoxLayout(panel);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(0);

    auto* top = new QWidget(panel);
    auto* topLayout = new QHBoxLayout(top);
    topLayout->setContentsMargins(CTSpacing::Lg, CTSpacing::Sm, CTSpacing::Lg, CTSpacing::Sm);
    auto* back = ui::ghostButton(QStringLiteral("返回"));
    connect(back, &QPushButton::clicked, this, [this] { closeConversation(); });
    topLayout->addWidget(back);
    auto* title = ui::titleLabel(conversation.nickname, CTTypography::SectionTitle, true);
    title->setAlignment(Qt::AlignCenter);
    topLayout->addWidget(title, 1);
    auto* spacer = new QWidget(top);
    spacer->setFixedWidth(back->sizeHint().width());
    topLayout->addWidget(spacer);
    layout->addWidget(top);
    layout->addWidget(ui::separator());

    if (m_loadingMessages) {
        layout->addWidget(ui::statusPanel(QStringLiteral("加载中…"), true), 1);
    } else if (m_messagesError.has_value()) {
        layout->addWidget(ui::errorPanel(*m_messagesError, [this, conversation] {
            detach(openConversationAsync(conversation));
        }), 1);
    } else if (m_messages.isEmpty()) {
        layout->addWidget(ui::statusPanel(QStringLiteral("暂无内容"), false), 1);
    } else {
        layout->addWidget(buildMessageBubbles(), 1);
    }

    layout->addWidget(ui::separator());
    auto* note = ui::secondaryLabel(QStringLiteral("发送私信依赖网易云的反作弊校验，当前版本仅支持阅读"));
    note->setWordWrap(true);
    note->setContentsMargins(CTSpacing::Lg, CTSpacing::Md, CTSpacing::Lg, CTSpacing::Md);
    layout->addWidget(note);
    return panel;
}

QWidget* MessagesView::buildMessageBubbles()
{
    auto* container = new QWidget();
    auto* layout = new QVBoxLayout(container);
    layout->setContentsMargins(CTSpacing::Lg, CTSpacing::Lg, CTSpacing::Lg, CTSpacing::Lg);
    layout->setSpacing(CTSpacing::Md);

    for (const PrivateMessage& message : std::as_const(m_messages)) {
        auto* bubble = new QFrame(container);
        bubble->setObjectName(QStringLiteral("ctBubble"));
        bubble->setStyleSheet(
            QStringLiteral("QFrame#ctBubble { background: %1; border: 1px solid %2; border-radius: %3px; }")
                .arg(message.isOutgoing ? CTColors::overlay().name() : CTColors::panel().name(),
                    message.isOutgoing ? CTColors::accent().name() : CTColors::overlay().name())
                .arg(CTRadius::Medium));
        auto* bubbleLayout = new QVBoxLayout(bubble);
        bubbleLayout->setContentsMargins(CTSpacing::Md, CTSpacing::Md, CTSpacing::Md, CTSpacing::Md);
        bubbleLayout->setSpacing(3);

        if (message.kind.type != PrivateMessageKindType::Text) {
            bubbleLayout->addWidget(ui::secondaryLabel(privateMessageKindLabel(message.kind)));
        }
        auto* content = new QLabel(message.content);
        content->setWordWrap(true);
        content->setMaximumWidth(420);
        content->setStyleSheet(QStringLiteral("color: %1;").arg(CTColors::textPrimary().name()));
        bubbleLayout->addWidget(content);
        bubbleLayout->addWidget(ui::secondaryLabel(relativeTime(message.time)));

        auto* row = new QWidget(container);
        auto* rowLayout = new QHBoxLayout(row);
        rowLayout->setContentsMargins(0, 0, 0, 0);
        if (message.isOutgoing) {
            rowLayout->addStretch(1);
            rowLayout->addWidget(bubble);
        } else {
            rowLayout->addWidget(bubble);
            rowLayout->addStretch(1);
        }
        layout->addWidget(row);
    }
    layout->addStretch(1);
    return ui::scrollWrapper(container);
}

QWidget* MessagesView::buildMyCommentsPane()
{
    if (m_loadingMyComments && m_myComments.isEmpty()) {
        return ui::statusPanel(QStringLiteral("加载中…"), true);
    }
    if (m_myCommentsError.has_value()) {
        return ui::errorPanel(*m_myCommentsError, [this] { detach(loadMyCommentsAsync()); });
    }
    if (m_myComments.isEmpty()) return ui::statusPanel(QStringLiteral("暂无内容"), false);

    auto* container = new QWidget();
    auto* layout = new QVBoxLayout(container);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(0);
    for (const MyComment& comment : std::as_const(m_myComments)) {
        layout->addWidget(buildMyCommentRow(comment));
        layout->addWidget(ui::separator());
    }
    layout->addStretch(1);
    return ui::scrollWrapper(container);
}

CT_REGISTER_PAGE(Page::Messages, MessagesView);

} // namespace ct
