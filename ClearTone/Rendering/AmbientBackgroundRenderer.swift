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

    private var isPaused: Bool = false
    private var frameCount: UInt64 = 0

    public override init() {
        device = MTLCreateSystemDefaultDevice()
        commandQueue = device?.makeCommandQueue()
        super.init()
        startTime = CFAbsoluteTimeGetCurrent()
        setupPipeline()
    }

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

    public func pause() {
        isPaused = true
    }

    public func resume() {
        isPaused = false
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        guard !isPaused, animationEnabled,
              let device = device,
              let commandQueue = commandQueue,
              let pipelineState = pipelineState,
              let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor else {
            return
        }

        frameCount += 1
        let time = Float(CFAbsoluteTimeGetCurrent() - startTime)

        // 限制帧率（自动模式）
        if frameCount % 2 == 0 && renderScale < 1.0 {
            // 节能模式降帧
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        encoder.setRenderPipelineState(pipelineState)

        // 传递 uniforms
        var uniforms = AmbientUniforms(
            time: time,
            resolution: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
            colorCount: min(5, UInt32(colors.count)),
            spectrumEnabled: spectrumEnabled ? 1 : 0,
            renderScale: renderScale
        )
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<AmbientUniforms>.size, index: 0)

        // 传递颜色
        var colorArray = colors
        if colorArray.count < 5 {
            colorArray += Array(repeating: SIMD3(0.15, 0.15, 0.18), count: 5 - colorArray.count)
        }
        encoder.setFragmentBytes(&colorArray, length: MemoryLayout<SIMD3<Float>>.size * 5, index: 1)

        // 传递频谱
        if spectrumEnabled {
            var spectrum = spectrumData
            if spectrum.count < 64 {
                spectrum += Array(repeating: 0, count: 64 - spectrum.count)
            }
            encoder.setFragmentBytes(&spectrum, length: MemoryLayout<Float>.size * 64, index: 2)
        }

        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()

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
        view.device = MTLCreateSystemDefaultDevice()
        view.delegate = context.coordinator
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.framebufferOnly = false
        view.layer?.isOpaque = false
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        return view
    }

    public func updateNSView(_ nsView: MTKView, context: Context) {
        let renderer = context.coordinator
        renderer.colors = colors.prefix(5).map { color in
            let nsColor = NSColor(color)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            nsColor.getRed(&r, green: &g, blue: &b, alpha: &a)
            return SIMD3(Float(r), Float(g), Float(b))
        }
        renderer.spectrumData = spectrum
        renderer.spectrumEnabled = showSpectrum
        renderer.animationEnabled = isAnimating
        renderer.renderScale = renderScale
        nsView.isPaused = !isAnimating
    }

    public func makeCoordinator() -> AmbientBackgroundRenderer {
        AmbientBackgroundRenderer()
    }
}
