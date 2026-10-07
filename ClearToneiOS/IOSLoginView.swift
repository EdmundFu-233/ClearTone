import SwiftUI
import CoreImage.CIFilterBuiltins

struct IOSLoginView: View {
    @StateObject private var session = MobileLoginSession()
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var refreshID = UUID()
    @State private var mode = 0
    @State private var cookie = ""
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "waveform.circle.fill").font(.system(size: 64)).foregroundStyle(.indigo)
                    Text("连接网易云音乐").font(.title2.bold())
                    Picker("登录方式", selection: $mode) { Text("扫码登录").tag(0); Text("Cookie 登录").tag(1) }.pickerStyle(.segmented)
                    if mode == 0 {
                        if let key = session.key, let qr = Self.qrImage(key) {
                            Image(uiImage: qr).interpolation(.none).resizable().scaledToFit().frame(maxWidth: 260).padding(12).background(.white).clipShape(RoundedRectangle(cornerRadius: 16))
                            ShareLink(item: Image(uiImage: qr), preview: SharePreview("澄音登录二维码", image: Image(uiImage: qr))) { Label("保存或分享二维码", systemImage: "square.and.arrow.up") }
                        } else if session.isLoading { ProgressView() }
                        Text(session.status).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("刷新二维码") { refreshID = UUID() }.buttonStyle(.bordered)
                        Text("在网易云音乐中扫描，或保存二维码后使用扫一扫的相册入口识别。").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        SecureField("粘贴网易云 Cookie", text: $cookie).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                        Button("登录") {
                            Task { await session.login(cookie: cookie); cookie = "" }
                        }.buttonStyle(.borderedProminent).disabled(cookie.isEmpty || session.isLoading)
                        Text("Cookie 仅保存在本机系统钥匙串中。此方式适用于已有的网易云网页登录凭据。").font(.footnote).foregroundStyle(.secondary)
                        if session.isLoading { ProgressView("验证登录…") }
                    }
                    if let error = session.errorMessage { Text(error).foregroundStyle(.red).font(.subheadline) }
                }.padding(24).frame(maxWidth: 520).frame(maxWidth: .infinity)
            }
            .navigationTitle("登录").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
        .task(id: "\(mode)-\(refreshID)") { if mode == 0 { await session.poll() } }
        .onReceive(session.$account) { account in
            if let account { appState.didLogin(account: account); dismiss() }
        }
        .onDisappear { session.cancel(); cookie = "" }
    }
    private static func qrImage(_ key: String) -> UIImage? {
        guard let url = try? NeteaseMobileRoute.qrURL(key: key) else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
