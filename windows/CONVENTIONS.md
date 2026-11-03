# Windows（Qt/C++）开发约定

本文档约束 `windows/` 下 Qt Widgets、C++20 与 Rust 辅助进程的开发，保证实现与测试约定一致。

## 目录与命名

- C++ 源文件位于 `src/ClearTone/`，头文件与实现使用同名 `.h/.cpp`。
- 根命名空间 `ct`；类名 PascalCase；方法/函数 camelCase；类私有成员 `m_` 前缀；
  结构体字段 camelCase 且公开；枚举用 `enum class`。
- include 一律从 `src/ClearTone` 起算：`#include "Core/Models/MusicModels.h"`。
- 源文件用 GLOB 收集，新文件自动进构建；版本、依赖与构建规则在 `CMakeLists.txt` 维护。
- 注释说明行为约束与设计原因，避免重复代码本身。

## 异步

- 异步操作统一使用 `ct::Task<T>`（惰性 C++20 协程，`co_await`/`co_return`）。
- 无返回值时使用 `ct::Task<void>`，结束用 `co_return;`。
- **禁止协程 lambda**：`detach([...]() -> Task<void> { co_await ... }())` 的闭包捕获不会被
  复制进协程帧，仍指向调用方栈上的临时闭包；调用方返回后协程恢复会读到被覆写的内存，
  表现为随机闪退（封面、辅助进程监控等处都踩过）。顶层协程一律写成命名函数/成员函数，
  需要捕获的内容作为显式参数传入（参数会复制进协程帧）。
- Qt 的 MinGW 13.1 / GCC 13.1 对 `co_await request(..., QHash{...})` 会触发编译器内部错误。
  可先构造 `auto pending = request(...); co_await pending;`，或在**同步执行的非协程**
  lambda 中准备请求：`co_await ([&] { return request(...); }());`。lambda 体不得含 `co_await`。
- **禁止阻塞**（不调用 `wait()`/`processEvents()`）；延迟一律 `co_await ct::Delay(ms, ct)`。
- 取消：方法接收 `ct::CancellationToken ct`，网络层传入；`ct.isCancellationRequested()` 判断。
- 错误使用 `throw MusicException(...)` / `catch (const MusicException&)`；
  协程框架会把异常存进 Task，调用方 `co_await` 时重新抛出。
- 多播事件使用 `ct::Event<>`，订阅返回的 ID 必须在持有方析构时取消订阅。
- 测试桩返回立即完成的协程：`co_return value;`。

## 数据与 JSON

- 容器用 Qt 类型（`QString`、`QList`、`QHash`、`QStringList`、`QDateTime`、`QUuid`）；
  可空值用 `std::optional`。
- 解析用 `Core/Models/JsonHelpers.h`（`json::prop/optionalString/optionalDouble/optionalInt/
  optionalLong/optionalBool/array/optionalIDString/compactMap`），容忍缺失、null 与类型不符。
- 持久化模型序列化用 `Core/Models/ModelJson.h` 的 `toJson/fromJson`，保持已发布数据的
  camelCase 格式（枚举为 camelCase 字符串，null 字段省略，
  非有限浮点写成 `"NaN"`/`"Infinity"`/`"-Infinity"` 字符串）。

## 网络与辅助进程

- `HelperProcessManager::shared()`：
  - `co_await helper.startIfNeeded(ct);`
  - `helper.makeURL(path, query)` 返回 `Result<QUrl>`，失败 `throw` 其 `error()`；
  - 请求头 `helper.authHeaders()`（`X-CT-Token`），Cookie 用 `X-CT-Cookie` 头。
- `HTTPClient`（每实例一个 `QNetworkAccessManager`）：`co_await client.get(url, headers, timeoutMs, ct)`；
  返回 `HTTPResponse{statusCode, body, headers}`，4xx/5xx 不抛异常，交给调用方判断。
- 错误映射使用 `MusicException`（`Core/Models/MusicError.h`）的静态构造函数。

## 日志

- `CTLog::general()/network()/playback()/helper()/render()/security()`，方法 `info/warn/error/debug`。
- 输出前自动脱敏（`CTLog::sanitize`），不要把 cookie/token 拼进日志。

## 线程

- 全部逻辑在主线程；libVLC 等外部线程回调必须 marshal 回主线程（`QMetaObject::invokeMethod(..., Qt::QueuedConnection)`）。

## 构建与自查

```bash
cmake -S windows -B windows/build-dev -DCMAKE_PREFIX_PATH=$(brew --prefix qt) -DCT_ENABLE_VLC=OFF
cmake --build windows/build-dev -j8
```

- 提交前运行对应测试；离线单测必须通过脚本或 CTest 隔离持久化。
- 只修改任务涉及的文件，不格式化全仓，不覆盖用户的其他改动。
