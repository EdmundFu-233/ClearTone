#pragma once

#include "Core/Async.h"
#include "Core/Models/SocialModels.h"

#include <QList>
#include <QString>
#include <QWidget>

#include <memory>
#include <optional>

class QVBoxLayout;

namespace ct {

class MessagesView : public QWidget {
    Q_OBJECT

public:
    explicit MessagesView(QWidget* parent = nullptr);
    ~MessagesView() override;

protected:
    void showEvent(QShowEvent* event) override;
    void hideEvent(QHideEvent* event) override;

private:
    enum class MessageTab {
        Notices,
        Conversations,
        MyComments,
    };

    void render();
    void scheduleAppChange();
    void handleAppChange();
    void loadCurrentTab();
    void refreshCurrentTab();
    void switchTab(MessageTab tab);
    void closeConversation();
    void markConversationRead(const PrivateConversation& conversation);

    Task<void> loadNoticesAsync();
    Task<void> loadConversationsAsync();
    Task<void> openConversationAsync(PrivateConversation conversation);
    Task<void> loadMyCommentsAsync();

    QWidget* buildLoginRequired();
    QWidget* buildTabRow();
    QWidget* buildNoticesPane();
    QWidget* buildConversationsPane();
    QWidget* buildConversationDetail();
    QWidget* buildMessageBubbles();
    QWidget* buildMyCommentsPane();

    MessageTab m_tab = MessageTab::Notices;

    QList<UserNotice> m_notices;
    bool m_loadingNotices = false;
    std::optional<QString> m_noticesError;
    int m_noticesToken = 0;

    QList<PrivateConversation> m_conversations;
    bool m_loadingConversations = false;
    std::optional<QString> m_conversationsError;
    int m_conversationsToken = 0;

    std::optional<PrivateConversation> m_selectedConversation;
    QList<PrivateMessage> m_messages;
    bool m_loadingMessages = false;
    std::optional<QString> m_messagesError;
    int m_messagesToken = 0;

    QList<MyComment> m_myComments;
    bool m_loadingMyComments = false;
    std::optional<QString> m_myCommentsError;
    int m_myCommentsToken = 0;

    bool m_isAttached = false;
    QString m_lastDataContextKey;
    bool m_appChangeScheduled = false;
    std::shared_ptr<bool> m_alive = std::make_shared<bool>(true);
    int m_appObserver = 0;
    int m_contextObserver = 0;

    QWidget* m_tabsHost = nullptr;
    QVBoxLayout* m_tabsLayout = nullptr;
    QWidget* m_contentHost = nullptr;
    QVBoxLayout* m_contentLayout = nullptr;
};

} // namespace ct
