#pragma once

#include "Core/Async.h"

#include <QCoreApplication>
#include <QMetaObject>

#include <memory>
#include <utility>

namespace ct {

// 组合两个取消令牌：任一取消时合成令牌取消（对应 C# CreateLinkedTokenSource）。
// 调用方用 shared_ptr 持有它保证在途协程存活期间回调不失效。
class LinkedCancellation {
public:
    LinkedCancellation(const CancellationToken& first, const CancellationToken& second)
        : m_source(std::make_shared<CancellationTokenSource>()),
          m_first(first),
          m_second(second)
    {
        auto source = m_source;
        m_firstId = first.registerCallback([source] { source->cancel(); });
        m_secondId = second.registerCallback([source] { source->cancel(); });
    }

    ~LinkedCancellation()
    {
        m_first.unregisterCallback(m_firstId);
        m_second.unregisterCallback(m_secondId);
    }

    LinkedCancellation(const LinkedCancellation&) = delete;
    LinkedCancellation& operator=(const LinkedCancellation&) = delete;

    CancellationToken token() const { return m_source->token(); }
    bool isCancellationRequested() const { return m_source->isCancellationRequested(); }
    void cancel() { m_source->cancel(); }

private:
    std::shared_ptr<CancellationTokenSource> m_source;
    CancellationToken m_first;
    CancellationToken m_second;
    int m_firstId = 0;
    int m_secondId = 0;
};

// 把顶层协程挂到主循环再启动（对应 C# 的 `_ = Task.Run(...)`）：
// 同步方法返回时协程尚未跑，状态与 C# 的调度时机一致。
template <typename T>
void startOnLoop(Task<T> task)
{
    auto holder = std::make_shared<Task<T>>(std::move(task));
    if (QCoreApplication::instance() != nullptr) {
        QMetaObject::invokeMethod(
            QCoreApplication::instance(), [holder] { holder->start(); }, Qt::QueuedConnection);
    } else {
        holder->start();
    }
}

} // namespace ct
