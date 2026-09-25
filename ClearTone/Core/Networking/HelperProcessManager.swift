import Foundation

/// 管理内置的 Node.js 辅助进程，运行 NeteaseCloudMusicApiEnhanced
/// 安全约束：仅监听 127.0.0.1，每次启动生成随机端口与访问 token，随主应用退出
@MainActor
public final class HelperProcessManager: ObservableObject {
    public static let shared = HelperProcessManager()

    @Published public private(set) var state: State = .stopped
    @Published public private(set) var lastError: String?

    public enum State: Equatable {
        case stopped
        case starting
        case running(port: Int)
        case failed(String)
    }

    private var process: Process?
    private var port: Int = 0
    private var authToken: String = ""
    private var healthCheckTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    /// 进行中的启动任务：并发调用 start() 时等待同一次启动，避免返回时进程尚未就绪
    private var startupTask: Task<Void, Error>?

    /// 辅助进程运行目录（包含 node 二进制与 API 代码）
    private var runtimeDirectory: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/HelperRuntime")
    }

    /// 开发模式下使用源码目录
    private var devRuntimeDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core/Networking
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // ClearTone
            .appendingPathComponent("Resources/HelperRuntime")
    }

    private init() {}

    // MARK: - Public API

    /// 启动辅助进程；已在启动中则等待同一次启动完成后再返回
    public func start() async throws {
        if let startupTask {
            try await startupTask.value
            return
        }
        guard state == .stopped || state.isFailed else { return }
        let task = Task { try await self.performStart() }
        startupTask = task
        defer { startupTask = nil }
        try await task.value
    }

    private func performStart() async throws {
        state = .starting
        lastError = nil

        // 1. 定位 runtime
        let runtimeDir = resolveRuntimeDirectory()
        guard FileManager.default.fileExists(atPath: runtimeDir.path) else {
            let msg = "辅助进程运行时未找到: \(runtimeDir.path)。请先运行 scripts/setup-helper.sh"
            state = .failed(msg)
            lastError = msg
            throw MusicError.helperProcessUnavailable
        }

        let nodeBinary = runtimeDir.appendingPathComponent("bin/node")
        let apiScript = runtimeDir.appendingPathComponent("api/app.js")
        guard FileManager.default.fileExists(atPath: nodeBinary.path),
              FileManager.default.fileExists(atPath: apiScript.path) else {
            let msg = "辅助进程文件不完整（缺少 node 或 app.js）"
            state = .failed(msg)
            lastError = msg
            throw MusicError.helperProcessUnavailable
        }

        // 2. 随机端口与 token
        port = Int.random(in: 21000...29000)
        authToken = UUID().uuidString

        // 3. 启动进程
        let proc = Process()
        proc.executableURL = nodeBinary
        proc.arguments = [apiScript.path]
        // 以 api 目录为工作目录，保证 dotenv/.env 与相对路径配置解析正确
        proc.currentDirectoryURL = runtimeDir.appendingPathComponent("api")

        var env = ProcessInfo.processInfo.environment
        env["PORT"] = String(port)
        env["CT_AUTH_TOKEN"] = authToken
        env["HOST"] = "127.0.0.1"
        env["NODE_ENV"] = "production"
        // 清除代理环境变量，避免影响 request 库
        env["http_proxy"] = ""; env["https_proxy"] = ""
        env["HTTP_PROXY"] = ""; env["HTTPS_PROXY"] = ""
        env["no_proxy"] = ""; env["NO_PROXY"] = ""
        proc.environment = env

        let logDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/ClearTone")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logURL = logDir.appendingPathComponent("helper.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        // 日志句柄创建失败不应让状态卡在 .starting
        let logHandle = (try? FileHandle(forWritingTo: logURL)) ?? FileHandle.nullDevice
        proc.standardOutput = logHandle
        proc.standardError = logHandle

        proc.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self = self else { return }
                if self.process == process {
                    CTLog.helper.warning("辅助进程意外退出，code: \(process.terminationStatus)")
                    self.state = .failed("辅助进程意外退出 (code \(process.terminationStatus))")
                    self.cleanup()
                    // 自动重启（存入 restartTask，stop() 时可取消）
                    self.restartTask?.cancel()
                    self.restartTask = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(1))
                        guard let self, !Task.isCancelled else { return }
                        self.restartTask = nil
                        try? await self.start()
                    }
                }
            }
        }

        do {
            try proc.run()
            self.process = proc

            // 将子进程加入与主进程相同的进程组，确保主应用退出时子进程被杀死
            // 使用 setsid 的反向操作：不调用 setsid，让子进程属于主进程组
        } catch {
            state = .failed("启动失败: \(error.localizedDescription)")
            lastError = error.localizedDescription
            throw MusicError.helperProcessUnavailable
        }

        // 4. 等待健康检查通过
        do {
            try await waitForHealthy(timeout: 15)
            state = .running(port: port)
            CTLog.helper.info("辅助进程启动成功，端口 \(self.port)")
            startHealthMonitoring()
        } catch {
            stop()
            state = .failed("健康检查超时")
            lastError = "本地服务启动超时，请重试"
            throw MusicError.helperProcessTimeout
        }
    }

    public func stop() {
        healthCheckTask?.cancel()
        healthCheckTask = nil
        restartTask?.cancel()
        restartTask = nil
        stopProcess()
    }

    public func restart() async throws {
        // 健康监控任务自触发重启时不能先取消自身：
        // 否则下方 Task.sleep 会抛出取消异常被 try? 吞掉，start() 永远不执行，服务卡在 stopped
        stopProcess()
        try await Task.sleep(for: .milliseconds(500))
        try await start()
    }

    /// 终止进程并清理状态（不触碰健康监控任务，供 restart 复用）
    private func stopProcess() {
        if let proc = process, proc.isRunning {
            proc.terminate()
            // 给 2 秒优雅退出，然后强杀
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if proc.isRunning { Darwin.kill(proc.processIdentifier, SIGKILL) }
            }
        }
        cleanup()
        state = .stopped
        CTLog.helper.info("辅助进程已停止")
    }

    /// 构造带鉴权的请求 URL
    public func makeURL(path: String, query: [String: String] = [:]) throws -> URL {
        guard case .running(let port) = state else { throw MusicError.helperProcessUnavailable }
        var components = URLComponents(string: "http://127.0.0.1:\(port)\(path)")
        var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        components?.queryItems = items.isEmpty ? nil : items
        guard let url = components?.url else { throw MusicError.invalidResponse }
        return url
    }

    public func applyAuth(to request: inout URLRequest) {
        request.setValue(authToken, forHTTPHeaderField: "X-CT-Token")
    }

    // MARK: - Private

    private func resolveRuntimeDirectory() -> URL {
        let bundled = runtimeDirectory
        if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        return devRuntimeDirectory
    }

    private func waitForHealthy(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if let healthy = try? await performHealthCheck(), healthy { return }
            try await Task.sleep(for: .milliseconds(300))
        }
        throw MusicError.helperProcessTimeout
    }

    private func performHealthCheck() async throws -> Bool {
        guard case .running = state, port > 0 else {
            // starting 阶段也允许检查
            guard port > 0 else { return false }
            return try await checkPort(port)
        }
        return try await checkPort(port)
    }

    private func checkPort(_ port: Int) async throws -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/ct_health")!)
        request.setValue(authToken, forHTTPHeaderField: "X-CT-Token")
        request.timeoutInterval = 2
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private func startHealthMonitoring() {
        healthCheckTask?.cancel()
        healthCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self = self, !Task.isCancelled else { return }
                // 检查进程是否仍在运行
                let processAlive = self.process?.isRunning ?? false
                let healthy = (try? await self.performHealthCheck()) ?? false
                if !processAlive || !healthy {
                    CTLog.helper.warning("辅助进程异常 (alive=\(processAlive), healthy=\(healthy))，尝试重启")
                    self.state = .failed("辅助进程异常退出")
                    self.restartFromMonitor()
                    return
                }
            }
        }
    }

    /// 健康监控触发的重启：把“取消监控任务”与“重启动作”分离，
    /// 重启在新的未被取消的任务中执行；失败时重新挂起监控继续自动恢复
    private func restartFromMonitor() {
        healthCheckTask?.cancel()
        healthCheckTask = nil
        stopProcess()
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self = self, !Task.isCancelled else { return }
            self.restartTask = nil
            do {
                try await self.start()
            } catch {
                CTLog.helper.error("健康检查自动重启失败: \(error.localizedDescription)")
                self.state = .failed("辅助进程异常退出")
                self.startHealthMonitoring()
            }
        }
    }

    private func cleanup() {
        process = nil
        port = 0
        authToken = ""
    }
}

extension HelperProcessManager.State {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}


