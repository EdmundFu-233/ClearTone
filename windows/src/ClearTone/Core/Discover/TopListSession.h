#pragma once

#include "Core/Async.h"
#include "Core/AsyncUtils.h"
#include "Core/Models/DiscoveryModels.h"

#include <functional>
#include <memory>
#include <optional>

namespace ct {

class IMusicSocialProvider;

class TopListSession {
public:
    explicit TopListSession(IMusicSocialProvider* source = nullptr);

    std::function<void()> onChanged;

    const QList<TopList>& lists() const { return m_lists; }
    bool isLoading() const { return m_isLoading; }
    const std::optional<QString>& errorMessage() const { return m_errorMessage; }

    Task<void> loadAsync(CancellationToken ct = CancellationToken::none());

private:
    void notifyChanged();

    IMusicSocialProvider* m_source = nullptr;
    QList<TopList> m_lists;
    bool m_isLoading = false;
    std::optional<QString> m_errorMessage;

    int m_token = 0;
    std::shared_ptr<LinkedCancellation> m_cts;
};

} // namespace ct
