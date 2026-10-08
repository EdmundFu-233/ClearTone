#pragma once

// C++20 协程 + 回调异步基础设施。
//
// 约定：所有异步工作都跑在主线程（QNetworkAccessManager / libVLC 事件统一 marshal
// 回主线程），Task 的生命周期由 promise 自身持有，调用方丢弃 Task 对象不会销毁
// 在途协程（与 C# 中丢弃 Task 的行为一致）。
//
//   ct::Task<T>            惰性协程，co_await 或 start() 后开始执行
//   ct::Result<T>          成功值或 MusicException
//   ct::CancellationToken  取消令牌，网络层据此中断请求
//   ct::Awaitable<T>       把「回调式 API」桥接进协程
//   ct::syncWait(task)     测试用：阻塞事件循环直到完成

#include "Core/Models/MusicError.h"

#include <QCoreApplication>
#include <QEventLoop>
#include <QMetaObject>
#include <QPair>
#include <QThread>
#include <QTimer>
#include <QVector>

#include <coroutine>
#include <exception>
#include <functional>
#include <memory>
#include <optional>
#include <utility>
#include <vector>

namespace ct {

struct Unit {};

// ---------------------------------------------------------------------------
// CancellationToken / CancellationTokenSource
// ---------------------------------------------------------------------------

struct CancellationState {
    bool cancelled = false;
    int nextId = 0;
    QVector<QPair<int, std::function<void()>>> callbacks;
};

class CancellationToken {
public:
    CancellationToken() = default;

    bool isCancellationRequested() const { return m_state && m_state->cancelled; }
    bool canBeCancelled() const { return static_cast<bool>(m_state); }

    int registerCallback(std::function<void()> callback) const
    {
        if (!m_state) return 0;
        if (m_state->cancelled) {
            callback();
            return 0;
        }
        const int id = ++m_state->nextId;
        m_state->callbacks.append({id, std::move(callback)});
        return id;
    }

    void unregisterCallback(int id) const
    {
        if (!m_state || id == 0) return;
        auto& callbacks = m_state->callbacks;
        for (int i = 0; i < callbacks.size(); ++i) {
            if (callbacks[i].first == id) {
                callbacks.removeAt(i);
                return;
            }
        }
    }

    static CancellationToken none() { return CancellationToken(); }

private:
    friend class CancellationTokenSource;
    explicit CancellationToken(std::shared_ptr<CancellationState> state) : m_state(std::move(state)) {}
    std::shared_ptr<CancellationState> m_state;
};

class CancellationTokenSource {
public:
    CancellationTokenSource() : m_state(std::make_shared<CancellationState>()) {}

    CancellationToken token() const { return CancellationToken(m_state); }
    bool isCancellationRequested() const { return m_state->cancelled; }

    void cancel()
    {
        if (m_state->cancelled) return;
        m_state->cancelled = true;
        auto callbacks = std::move(m_state->callbacks);
        m_state->callbacks.clear();
        for (auto& pair : callbacks) pair.second();
    }

private:
    std::shared_ptr<CancellationState> m_state;
};

// ---------------------------------------------------------------------------
// Result
// ---------------------------------------------------------------------------

template <typename T>
class Result {
public:
    static Result success(T value)
    {
        Result result;
        result.m_value.emplace(std::move(value));
        return result;
    }

    static Result failure(MusicException error)
    {
        Result result;
        result.m_error.emplace(std::move(error));
        return result;
    }

    bool isSuccess() const { return m_value.has_value(); }
    bool isFailure() const { return !m_value.has_value(); }

    const T& value() const { return *m_value; }
    T& value() { return *m_value; }
    T takeValue() { return std::move(*m_value); }

    const MusicException& error() const { return *m_error; }

private:
    std::optional<T> m_value;
    std::optional<MusicException> m_error;
};

using VoidResult = Result<Unit>;

inline VoidResult voidSuccess() { return VoidResult::success(Unit{}); }
inline VoidResult voidFailure(MusicException error)
{
    return VoidResult::failure(std::move(error));
}

template <typename T>
using Callback = std::function<void(Result<T>)>;
using Completion = Callback<Unit>;

// ---------------------------------------------------------------------------
// Task
// ---------------------------------------------------------------------------

namespace detail {

struct TaskState {
    std::coroutine_handle<> handle;
    bool done = false;

    ~TaskState()
    {
        if (handle) handle.destroy();
    }
};

inline void scheduleStateRelease(std::shared_ptr<TaskState> state)
{
    if (QCoreApplication::instance() != nullptr) {
        QMetaObject::invokeMethod(
            QCoreApplication::instance(), [state = std::move(state)] {}, Qt::QueuedConnection);
    } else {
        // 没有事件循环（极少见的裸环境）：把帧交还到一个静态回收站，避免在
        // final_suspend 里销毁自身。测试环境始终有 QCoreApplication。
        static auto* pending = new std::vector<std::shared_ptr<TaskState>>();
        pending->push_back(std::move(state));
    }
}

inline void resumeOnLoop(std::coroutine_handle<> handle)
{
    if (QCoreApplication::instance() != nullptr) {
        QMetaObject::invokeMethod(
            QCoreApplication::instance(), [handle] { handle.resume(); }, Qt::QueuedConnection);
    } else {
        handle.resume();
    }
}

} // namespace detail

template <typename T>
class Task {
public:
    struct promise_type {
        std::shared_ptr<detail::TaskState> state = std::make_shared<detail::TaskState>();
        std::optional<T> value;
        std::exception_ptr exception;
        std::coroutine_handle<> continuation;
        std::function<void()> onComplete;
        bool completed = false;

        promise_type()
        {
            state->handle = std::coroutine_handle<promise_type>::from_promise(*this);
        }

        Task get_return_object() { return Task(state); }
        std::suspend_always initial_suspend() noexcept { return {}; }

        auto final_suspend() noexcept
        {
            struct Final {
                bool await_ready() noexcept { return false; }
                std::coroutine_handle<> await_suspend(std::coroutine_handle<promise_type> handle) noexcept
                {
                    auto& promise = handle.promise();
                    promise.completed = true;
                    if (promise.onComplete) promise.onComplete();
                    if (promise.exception && !promise.continuation && !promise.onComplete) {
                        ct::logDetachedTaskException(promise.exception);
                    }
                    auto continuation = promise.continuation;
                    auto state = std::move(promise.state);
                    if (state) {
                        state->done = true;
                        detail::scheduleStateRelease(std::move(state));
                    }
                    return continuation ? continuation : std::noop_coroutine();
                }
                void await_resume() noexcept {}
            };
            return Final{};
        }

        void return_value(T v) { value.emplace(std::move(v)); }
        void unhandled_exception() { exception = std::current_exception(); }
    };

    explicit Task(std::shared_ptr<detail::TaskState> state) : m_state(std::move(state)) {}
    Task(Task&& other) noexcept : m_state(std::move(other.m_state)) {}
    Task& operator=(Task&& other) noexcept
    {
        m_state = std::move(other.m_state);
        return *this;
    }
    Task(const Task&) = delete;
    Task& operator=(const Task&) = delete;
    ~Task() = default;

    bool await_ready() const noexcept { return m_state && m_state->handle.done(); }

    std::coroutine_handle<> await_suspend(std::coroutine_handle<> caller)
    {
        promise().continuation = caller;
        return m_state->handle;
    }

    T await_resume() { return takeResult(); }

    void start()
    {
        if (m_state && m_state->handle && !m_state->handle.done()) {
            m_state->handle.resume();
        }
    }

    bool isDone() const { return m_state && m_state->done; }

    void onComplete(std::function<void()> hook)
    {
        if (!m_state) return;
        if (m_state->done) {
            hook();
            return;
        }
        promise().onComplete = std::move(hook);
    }

    T takeResult()
    {
        auto& p = promise();
        if (p.exception) {
            auto exception = p.exception;
            p.exception = nullptr;
            std::rethrow_exception(exception);
        }
        return std::move(*p.value);
    }

private:
    promise_type& promise() const
    {
        return std::coroutine_handle<promise_type>::from_address(m_state->handle.address()).promise();
    }

    std::shared_ptr<detail::TaskState> m_state;
};

template <>
class Task<void> {
public:
    struct promise_type {
        std::shared_ptr<detail::TaskState> state = std::make_shared<detail::TaskState>();
        std::exception_ptr exception;
        std::coroutine_handle<> continuation;
        std::function<void()> onComplete;
        bool completed = false;

        promise_type()
        {
            state->handle = std::coroutine_handle<promise_type>::from_promise(*this);
        }

        Task get_return_object() { return Task(state); }
        std::suspend_always initial_suspend() noexcept { return {}; }

        auto final_suspend() noexcept
        {
            struct Final {
                bool await_ready() noexcept { return false; }
                std::coroutine_handle<> await_suspend(std::coroutine_handle<promise_type> handle) noexcept
                {
                    auto& promise = handle.promise();
                    promise.completed = true;
                    if (promise.onComplete) promise.onComplete();
                    if (promise.exception && !promise.continuation && !promise.onComplete) {
                        ct::logDetachedTaskException(promise.exception);
                    }
                    auto continuation = promise.continuation;
                    auto state = std::move(promise.state);
                    if (state) {
                        state->done = true;
                        detail::scheduleStateRelease(std::move(state));
                    }
                    return continuation ? continuation : std::noop_coroutine();
                }
                void await_resume() noexcept {}
            };
            return Final{};
        }

        void return_void() {}
        void unhandled_exception() { exception = std::current_exception(); }
    };

    explicit Task(std::shared_ptr<detail::TaskState> state) : m_state(std::move(state)) {}
    Task(Task&& other) noexcept : m_state(std::move(other.m_state)) {}
    Task& operator=(Task&& other) noexcept
    {
        m_state = std::move(other.m_state);
        return *this;
    }
    Task(const Task&) = delete;
    Task& operator=(const Task&) = delete;
    ~Task() = default;

    bool await_ready() const noexcept { return m_state && m_state->handle.done(); }

    std::coroutine_handle<> await_suspend(std::coroutine_handle<> caller)
    {
        promise().continuation = caller;
        return m_state->handle;
    }

    void await_resume() { takeResult(); }

    void start()
    {
        if (m_state && m_state->handle && !m_state->handle.done()) {
            m_state->handle.resume();
        }
    }

    bool isDone() const { return m_state && m_state->done; }

    void onComplete(std::function<void()> hook)
    {
        if (!m_state) return;
        if (m_state->done) {
            hook();
            return;
        }
        promise().onComplete = std::move(hook);
    }

    void takeResult()
    {
        auto& p = promise();
        if (p.exception) {
            auto exception = p.exception;
            p.exception = nullptr;
            std::rethrow_exception(exception);
        }
    }

private:
    promise_type& promise() const
    {
        return std::coroutine_handle<promise_type>::from_address(m_state->handle.address()).promise();
    }

    std::shared_ptr<detail::TaskState> m_state;
};

// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// 延时（可取消）
// ---------------------------------------------------------------------------

class Delay {
public:
    Delay(int milliseconds, CancellationToken ct = CancellationToken::none())
        : m_ms(milliseconds), m_ct(std::move(ct))
    {
    }

    bool await_ready() const noexcept { return m_ms <= 0 || m_ct.isCancellationRequested(); }

    void await_suspend(std::coroutine_handle<> handle) const
    {
        auto state = std::make_shared<State>();
        state->handle = handle;
        state->timer = std::make_shared<QTimer>();
        state->timer->setSingleShot(true);
        QObject::connect(state->timer.get(), &QTimer::timeout, [state] { complete(state, false); });
        state->timer->start(m_ms);
        if (m_ct.canBeCancelled()) {
            const auto token = m_ct;
            state->cancelId = token.registerCallback([state] { complete(state, true); });
            state->token = token;
        }
    }

    void await_resume() const
    {
        if (m_ct.isCancellationRequested()) {
            throw MusicException(MusicErrorKind::Cancelled);
        }
    }

private:
    struct State {
        std::coroutine_handle<> handle;
        std::shared_ptr<QTimer> timer;
        CancellationToken token;
        int cancelId = 0;
        bool finished = false;
    };

    static void complete(const std::shared_ptr<State>& state, bool cancelled)
    {
        if (state->finished) return;
        state->finished = true;
        if (state->timer) state->timer->stop();
        state->token.unregisterCallback(state->cancelId);
        detail::resumeOnLoop(state->handle);
    }

    int m_ms;
    CancellationToken m_ct;
};

// 回调式 API 的协程桥
// ---------------------------------------------------------------------------

template <typename T>
struct Awaitable {
    Awaitable() = default;

    explicit Awaitable(std::function<void(Callback<T>)> start)
        : starter(std::move(start))
    {
    }

    std::function<void(Callback<T>)> starter;
    std::optional<Result<T>> result;

    bool await_ready() const noexcept { return false; }

    void await_suspend(std::coroutine_handle<> handle)
    {
        auto* self = this;
        auto starter = this->starter;
        starter([self, handle](Result<T> outcome) {
            self->result.emplace(std::move(outcome));
            detail::resumeOnLoop(handle);
        });
    }

    T await_resume()
    {
        if (!result) throw MusicException(MusicErrorKind::Cancelled);
        if (result->isFailure()) throw result->error();
        return result->takeValue();
    }
};

// 立即完成的 Task（测试桩用）。
template <typename T>
Task<T> makeReadyTask(T value)
{
    co_return value;
}

inline Task<void> makeReadyVoidTask()
{
    co_return;
}

template <typename T>
T syncWait(Task<T> task)
{
    T value = T();
    bool completed = false;
    task.onComplete([&] { completed = true; });
    task.start();
    if (!completed) {
        QEventLoop loop;
        task.onComplete([&] { loop.quit(); });
        if (!task.isDone()) loop.exec();
    }
    value = task.takeResult();
    return value;
}

inline void syncWait(Task<void> task)
{
    bool completed = false;
    task.onComplete([&] { completed = true; });
    task.start();
    if (!completed) {
        QEventLoop loop;
        task.onComplete([&] { loop.quit(); });
        if (!task.isDone()) loop.exec();
    }
    task.takeResult();
}

// 发起一个不等待的顶层协程；未观察到的异常会在 final_suspend 中记录日志。
template <typename T>
void detach(Task<T> task)
{
    task.start();
}

} // namespace ct
