import SwiftUI

/// 二维码登录视图
struct LoginView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme

    @State private var qrImage: NSImage?
    @State private var status: QRLoginStatus = .waitingScan
    @State private var qrKey: String?
    @State private var pollingTask: Task<Void, Never>?
    @State private var autoRefreshTask: Task<Void, Never>?
    @State private var errorMessage: String?

    private let provider = NeteaseProvider.shared

    var body: some View {
        VStack(spacing: 0) {
            // 标题 + 关闭
            CTSheetHeader(title: L10n.Login.title) { dismiss() }

            Divider()

            VStack(spacing: CTSpacing.xl) {
                // 二维码区域
                ZStack {
                    RoundedRectangle(cornerRadius: CTRadius.medium)
                        .fill(CTColors.panel(for: colorScheme))
                        .frame(width: 240, height: 240)

                    if let qrImage = qrImage {
                        Image(nsImage: qrImage)
                            .resizable()
                            .interpolation(.none)
                            .scaledToFit()
                            .frame(width: 220, height: 220)

                        // 过期遮罩
                        if case .expired = status {
                            RoundedRectangle(cornerRadius: CTRadius.medium)
                                .fill(.black.opacity(0.7))
                                .frame(width: 220, height: 220)
                            VStack {
                                Image(systemName: "arrow.clockwise")
                                    .font(.title)
                                Text(L10n.Login.expired)
                                    .font(CTTypography.caption)
                            }
                            .foregroundStyle(.white)
                            .onTapGesture { refreshQRCode() }
                        }
                    } else if let error = errorMessage {
                        VStack(spacing: CTSpacing.sm) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.largeTitle)
                                .foregroundStyle(CTColors.accent(for: colorScheme))
                            Text(error)
                                .font(CTTypography.caption)
                                .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                                .multilineTextAlignment(.center)
                            Button(L10n.Common.retry) { refreshQRCode() }
                                .buttonStyle(.borderedProminent)
                        }
                        .padding()
                    } else {
                        ProgressView()
                            .scaleEffect(1.5)
                    }
                }

                // 状态提示
                VStack(spacing: CTSpacing.sm) {
                    Text(statusText)
                        .font(CTTypography.body)
                        .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                    if case .failed = status {
                        Button(L10n.Common.retry) { refreshQRCode() }
                            .buttonStyle(.bordered)
                    }
                }

                // 说明
                Text(L10n.Login.scanPrompt)
                    .font(CTTypography.caption)
                    .foregroundStyle(CTColors.textSecondary(for: colorScheme))

                Spacer()
                }
            .padding(CTSpacing.xxl)
        }
        .frame(width: 400, height: 600)
        .background(CTColors.background(for: colorScheme))
        .onAppear { refreshQRCode() }
        .onDisappear {
            cancelPolling()
            autoRefreshTask?.cancel()
            autoRefreshTask = nil
        }
    }

    private var statusText: String {
        switch status {
        case .waitingScan: return L10n.Login.waitingScan
        case .scannedWaitingConfirm: return L10n.Login.scanned
        case .success: return L10n.Login.success
        case .expired: return L10n.Login.expired
        case .failed(let msg): return "\(L10n.Login.failed): \(msg)"
        }
    }

    private func refreshQRCode() {
        cancelPolling()
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
        errorMessage = nil
        qrImage = nil
        status = .waitingScan

        pollingTask = Task {
            do {
                let key = try await provider.fetchQRCodeKey()
                qrKey = key

                let imageURL = try await provider.fetchQRCodeImage(key: key)
                let (data, _) = try await URLSession.shared.data(from: imageURL)
                if let image = NSImage(data: data) {
                    qrImage = image
                }

                // 开始轮询
                await pollStatus(key: key)
            } catch {
                if !Task.isCancelled {
                    errorMessage = error.ctUserMessage
                }
            }
        }
    }

    private func pollStatus(key: String) async {
        var retryCount = 0
        let maxRetries = 60 // 最多轮询 2 分钟

        while !Task.isCancelled && retryCount < maxRetries {
            do {
                let status = try await provider.checkQRCodeStatus(key: key)
                self.status = status

                switch status {
                case .success(let cookie):
                    // 必须归一化再存。`login_qr_check.js` 返回的是
                    // `result.cookie.join(';')` —— 一整组 Set-Cookie 响应头，
                    // 每个元素本身就带 `Expires` / `Max-Age` / `Path`，
                    // 原样存进去会让每个请求的 Cookie 头有 134 段
                    // （6 个真 cookie + 大量属性 + 空值），见 NeteaseCookieNormalizer。
                    try? KeychainStore.shared.save(NeteaseCookieNormalizer.normalize(cookie),
                                                   for: .neteaseCookie)
                    await loadAccount()
                    return
                case .expired:
                    // 过期后自动更换新二维码，无需手动点击
                    scheduleAutoRefresh()
                    return
                case .failed:
                    return
                default:
                    break
                }

                retryCount += 1
                // 退避策略：前 10 次每 1 秒，之后每 2 秒
                let delay: UInt64 = retryCount < 10 ? 1_000_000_000 : 2_000_000_000
                try await Task.sleep(nanoseconds: delay)
            } catch {
                retryCount += 1
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }

        if retryCount >= maxRetries {
            status = .expired
        }
    }

    private func loadAccount() async {
        do {
            if let account = try await provider.fetchAccountInfo() {
                appState.didLogin(account: account)
                try? KeychainStore.shared.save(account.userID, for: .neteaseUserID)
                await appState.loadLikedSongs(force: true)
                dismiss()
            }
        } catch {
            errorMessage = "获取账户信息失败"
        }
    }

    /// 过期后延迟自动刷新，避免与原轮询任务竞争
    private func scheduleAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            refreshQRCode()
        }
    }

    private func cancelPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }
}
