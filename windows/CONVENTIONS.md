# Windows（Qt/C++）移植约定

本文档约束 `windows/` 下 C++ 代码的写法，保证从 C# 版（git 历史中）移植时行为一致、风格统一。
新增代码一律遵守；与本文冲突时以「与 C# 原实现语义一致」优先。

## 目录与命名

- 源文件路径与 C# 版一一对应：`src/ClearTone/<同样的相对路径>.h/.cpp`。
- 根命名空间 `ct`；类名 PascalCase；方法/函数 camelCase；类私有成员 `m_` 前缀；
  结构体字段 camelCase 且公开；枚举用 `enum class`，成员名沿用 C#。
- include 一律从 `src/ClearTone` 起算：`#include "Core/Models/MusicModels.h"`。
- 不修改 `CMakeLists.txt`（源文件用 GLOB 收集，新文件自动进构建）。
- 除非从 C# 移植了注释，否则不新增注释。

## 异步

- C# `Task<T>` → `ct::Task<T>`（C++20 协程，惰性，`co_await`/`co_return`）。
- C# `Task` → `ct::Task<void>`，结束用 `co_return;`。
- **禁止协程 lambda**：`detach([...]() -> Task<void> { co_await ... }())` 的闭包捕获不会被
  复制进协程帧，仍指向调用方栈上的临时闭包；调用方返回后协程恢复会读到被覆写的内存，
  表现为随机闪退（封面、辅助进程监控等处都踩过）。顶层协程一律写成命名函数/成员函数，
  需要捕获的内容作为显式参数传入（参数会复制进协程帧）。
- **禁止阻塞**（不调用 `wait()`/`processEvents()`）；延迟一律 `co_await ct::Delay(ms, ct)`。
- 取消：方法接收 `ct::CancellationToken ct`，网络层传入；`ct.isCancellationRequested()` 判断。
- `throw MusicException(...)` / `catch (const MusicException&)` 与 C# 的 throw/catch 一一对应；
  协程框架会把异常存进 Task，调用方 `co_await` 时重新抛出。
- 事件：C# `event Action` → 公开的 `std::function<void()>` 成员，如 `std::function<void()> sessionExpired;`。
- 测试桩返回立即完成的协程：`co_return value;`。

## 数据与 JSON

- 容器用 Qt 类型（`QString`、`QList`、`QHash`、`QStringList`、`QDateTime`、`QUuid`）；
  可空值用 `std::optional`。
- 解析用 `Core/Models/JsonHelpers.h`（`json::prop/optionalString/optionalDouble/optionalInt/
  optionalLong/optionalBool/array/optionalIDString/compactMap`），语义与 C# `JsonHelpers` 相同。
- 持久化模型序列化用 `Core/Models/ModelJson.h` 的 `toJson/fromJson`，字段名与 C#
  System.Text.Json 的 camelCase 输出一致（枚举为 camelCase 字符串，null 字段省略，
  非有限浮点写成 `"NaN"`/`"Infinity"`/`"-Infinity"` 字符串）。

## 网络与辅助进程

- `HelperProcessManager::shared()`：
  - `co_await helper.startIfNeeded(ct);`
  - `helper.makeURL(path, query)` 返回 `Result<QUrl>`，失败 `throw` 其 `error()`；
  - 请求头 `helper.authHeaders()`（`X-CT-Token`），Cookie 用 `X-CT-Cookie` 头。
- `HTTPClient`（每实例一个 `QNetworkAccessManager`）：`co_await client.get(url, headers, timeoutMs, ct)`；
  返回 `HTTPResponse{statusCode, body, headers}`，4xx/5xx 不抛异常，交给调用方判断。
- 错误映射：`MusicException`（`Core/Models/MusicError.h`），静态构造与 C# 同名。

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

- 只修自己负责文件的编译错误；其它模块可能尚未完成，属正常现象。
- 不提交、不格式化全仓、不改 `Tests` 以外的既有文件。
