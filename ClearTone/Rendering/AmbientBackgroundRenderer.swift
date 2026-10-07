import MetalKit
import SwiftUI

/// Metal 背景渲染器：封面取色流动背景 + 频谱绘制
public final class AmbientBackgroundRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var startTime: CFAbsoluteTime = 0

    // 封面颜色（最多 5 色）
    public var colors: [SIMD3<Float>] = [
        SIMD3(0.1, 0.1, 0.12),
        SIMD3(0.15, 0.15, 0.18),
        SIMD3(0.2, 0.2, 0.25),
        SIMD3(0.12, 0.12, 0.15),
        SIMD3(0.18, 0.18, 0.22),
    ]

    // 频谱数据（0..1）
    public var spectrumData: [Float] = Array(repeating: 0, count: 64)
    public var spectrumEnabled: Bool = false
    public var animationEnabled: Bool = true
    public var renderScale: Float = 0.5  // 降低渲染比例节省能耗

    /// 目标帧率，由 SwiftUI 侧按性能模式设置
    public var targetFramesPerSecond: Int = 60

    private var frameCount: UInt64 = 0

    /// draw 循环内零分配用的定长存储（定长元组不能用下标，改用固定结构体）
    private struct Palette {
        var c0 = SIMD3<Float>(0.1, 0.1, 0.12)
        var c1 = SIMD3<Float>(0.15, 0.15, 0.18)
        var c2 = SIMD3<Float>(0.2, 0.2, 0.25)
        var c3 = SIMD3<Float>(0.12, 0.12, 0.15)
        var c4 = SIMD3<Float>(0.18, 0.18, 0.22)

        subscript(i: Int) -> SIMD3<Float> {
            get {
                switch i {
                case 0: return c0
                case 1: return c1
                case 2: return c2
                case 3: return c3
                default: return c4
                }
            }
            set {
                switch i {
                case 0: c0 = newValue
                case 1: c1 = newValue
                case 2: c2 = newValue
                case 3: c3 = newValue
                default: c4 = newValue
                }
            }
        }
    }

    private var colorStorage = Palette()
    private var spectrumStorage = [Float](repeating: 0, count: 64)

    /// 在途 GPU 帧的背压闸门。
    ///
    /// 原先是裸 `var inFlightFrames`：draw 线程 `+= 1`、Metal completion 线程
    /// `-=`，跨线程非原子读-改-写。丢一次 `-=` 计数就单调爬升、
    /// 背压判断每帧早退、画面冻在最后一帧且不可恢复；丢一次 `+=` 则
    /// 背压失效、command queue 无界堆积。判定与配对规则见 `InFlightGate`。
    private let inFlightGate = InFlightGate(maxInFlight: 2)

    /// 按目标帧率算出跳帧间隔
    private var frameInterval: Int {
        let fps = max(1, min(targetFramesPerSecond, 120))
        return max(1, 60 / fps)
    }

    /// 由 SwiftUI 侧在 updateNSView 调用（不在 draw 线程）
    public func updateBuffers(colors: [SIMD3<Float>], spectrum: [Float]) {
        let palette: [SIMD3<Float>] = [
            SIMD3(0.1, 0.1, 0.12), SIMD3(0.15, 0.15, 0.18), SIMD3(0.2, 0.2, 0.25),
            SIMD3(0.12, 0.12, 0.15), SIMD3(0.18, 0.18, 0.22),
        ]
        for i in 0..<5 {
            if i < colors.count { colorStorage[i] = colors[i] } else { colorStorage[i] = palette[i] }
        }
        for i in 0..<64 {
            spectrumStorage[i] = i < spectrum.count ? spectrum[i] : 0
        }
    }

    public override init() {
        device = MTLCreateSystemDefaultDevice()
        commandQueue = device?.makeCommandQueue()
        super.init()
        startTime = CFAbsoluteTimeGetCurrent()
        setupPipeline()
    }

    /// MTKView 也要用同一个 device：多 GPU 配置下若 view 的 drawable 属于
    /// Device A 而 command queue 属于 Device B，会拿不到 drawable 或渲染异常
    public var metalDevice: MTLDevice? { device }

    private func setupPipeline() {
        guard let device = device else { return }

        let library: MTLLibrary
        do {
            library = try device.makeDefaultLibrary(bundle: Bundle.main)
        } catch {
            CTLog.render.error("Metal shader 加载失败: \(error.localizedDescription)")
            return
        }

        guard let vertexFunc = library.makeFunction(name: "vertex_main"),
              let fragmentFunc = library.makeFunction(name: "fragment_ambient") else {
            CTLog.render.error("Metal shader 函数未找到")
            return
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunc
        descriptor.fragmentFunction = fragmentFunc
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            CTLog.render.error("Metal pipeline 创建失败: \(error.localizedDescription)")
        }
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // `autoResizeDrawable = false` 后 MTKView 不再自动跟随 bounds，
        // 而实时缩放窗口并不保证触发 `updateNSView`。这里按当前 renderScale
        // 重算，否则 Metal 图层会被拉伸成错误的宽高比 / 糊掉。
        applyDrawableSize(for: view)
    }

    /// 按当前 `renderScale` 设置 drawable 尺寸（降分辨率渲染的真实来源）。
    /// 设置 `drawableSize` 会再次回调 `drawableSizeWillChange`，靠等值判断防递归。
    func applyDrawableSize(for view: MTKView) {
        let scale = CGFloat(max(0.25, min(renderScale, 1.0)))
        let target = CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
        if target.width >= 1, target.height >= 1, view.drawableSize != target {
            view.drawableSize = target
        }
    }

    public func draw(in view: MTKView) {
        // 暂停由 SwiftUI 侧的 isAnimating（绑 scenePhase）→ MTKView.isPaused 承担，
        // 这里原先还有一个从没人调用的 pause()/resume() + isPaused 判断，纯死代码
        guard animationEnabled,
              device != nil,
              let commandQueue = commandQueue,
              let pipelineState = pipelineState,
              let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor else {
            return
        }

        // GPU 背压：若已提交的命令还没回来，说明 GPU 落后于提交速度。
        // 不加这个判断，command queue 会无限堆积、显存单调增长直到被内存压力杀掉。
        // 这里只做**只读**判断；真正的占位在下方紧贴 commit 处 ——
        // 反过来写的话，下面的降帧 / makeCommandBuffer 早退各漏一个名额，
        // 几帧之后就被自己锁死。
        if inFlightGate.isFull { return }

        frameCount += 1
        let time = Float(CFAbsoluteTimeGetCurrent() - startTime)

        // 真实降帧：原先这个 if 块是空的，降帧从未发生。
        // 按 renderScale 降档，节能模式 20fps / 自动 30fps / 高质量 60fps。
        if frameCount % UInt64(max(1, frameInterval)) != 0 { return }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        encoder.setRenderPipelineState(pipelineState)

        // 传递 uniforms
        var uniforms = AmbientUniforms(
            time: time,
            resolution: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
            colorCount: UInt32(min(5, colors.count)),
            spectrumEnabled: spectrumEnabled ? 1 : 0,
            renderScale: renderScale
        )
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<AmbientUniforms>.size, index: 0)

        // 传递颜色：预分配的定长存储，draw 内零分配。
        // 原先是 `var colorArray = colors` + `+= Array(repeating:)`，
        // 取色结果通常少于 5 个颜色所以每帧都会走 += 分支 = 每秒 120 次堆分配。
        encoder.setFragmentBytes(&colorStorage, length: MemoryLayout<SIMD3<Float>>.size * 5, index: 1)

        // 传递频谱：同样是预分配存储
        if spectrumEnabled {
            encoder.setFragmentBytes(&spectrumStorage, length: MemoryLayout<Float>.size * 64, index: 2)
        }

        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()

        // 占位必须紧贴 commit：它的上面没有任何早退点。
        // 若挪到函数开头（背压判断那里），降帧与 makeCommandBuffer 失败两条早退
        // 会各漏一个名额 —— 计数只增不减，几帧之后每帧都被背压挡掉。
        guard inFlightGate.tryAcquire() else { return }
        // 只捕获闸门，不捕获 self：完成回调跑在 Metal 的 completion 线程上，
        // 而 AmbientBackgroundRenderer 不是 Sendable —— 捕获 self 会触发
        // Sendable 警告，而这里要做的事也只有一句归还。
        let gate = inFlightGate
        commandBuffer.addCompletedHandler { _ in
            gate.release()
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

public struct AmbientUniforms {
    var time: Float
    var resolution: SIMD2<Float>
    var colorCount: UInt32
    var spectrumEnabled: UInt32
    var renderScale: Float
}

// MARK: - SwiftUI 封装
public struct MetalBackgroundView: NSViewRepresentable {
    @Binding var colors: [Color]
    @Binding var spectrum: [Float]
    @Binding var isAnimating: Bool
    @Binding var showSpectrum: Bool
    var renderScale: Float = 0.5

    public init(colors: Binding<[Color]>, spectrum: Binding<[Float]>, isAnimating: Binding<Bool>, showSpectrum: Binding<Bool>, renderScale: Float = 0.5) {
        self._colors = colors
        self._spectrum = spectrum
        self._isAnimating = isAnimating
        self._showSpectrum = showSpectrum
        self.renderScale = renderScale
    }

    public func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        // 复用 renderer 的 device：多 GPU 配置下两者必须是同一个
        view.device = context.coordinator.metalDevice
        view.delegate = context.coordinator
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.framebufferOnly = true
        view.layer?.isOpaque = false
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.preferredFramesPerSecond = max(1, min(context.coordinator.targetFramesPerSecond, 120))
        return view
    }

    public func updateNSView(_ nsView: MTKView, context: Context) {
        let renderer = context.coordinator
        let converted = colors.prefix(5).map { color -> SIMD3<Float> in
            let nsColor = NSColor(color)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            nsColor.getRed(&r, green: &g, blue: &b, alpha: &a)
            return SIMD3(Float(r), Float(g), Float(b))
        }
        renderer.colors = converted
        renderer.spectrumData = spectrum
        renderer.spectrumEnabled = showSpectrum
        renderer.animationEnabled = isAnimating
        renderer.renderScale = renderScale
        // 数据搬运放在这里（主线程），draw 循环内只读预分配存储
        renderer.updateBuffers(colors: converted, spectrum: spectrum)

        let fps = targetFramesPerSecond
        if nsView.preferredFramesPerSecond != fps {
            nsView.preferredFramesPerSecond = fps
        }

        // 真正的降分辨率：按 renderScale 缩小 drawableSize（shader 里不再重复缩放 UV）。
        nsView.autoResizeDrawable = false
        renderer.applyDrawableSize(for: nsView)

        // 窗口不可见时停帧
        nsView.isPaused = !isAnimating
    }

    /// 节能 / 自动 / 高质量对应的目标帧率
    private var targetFramesPerSecond: Int {
        switch renderScale {
        case ..<0.4: return 20
        case ..<0.6: return 30
        default: return 60
        }
    }

    public func makeCoordinator() -> AmbientBackgroundRenderer {
        AmbientBackgroundRenderer()
    }
}
