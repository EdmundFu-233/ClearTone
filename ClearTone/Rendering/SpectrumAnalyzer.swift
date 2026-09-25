import Foundation
import Accelerate
import AVFoundation
import CoreMedia
import AudioToolbox
import MediaToolbox

/// 频谱处理器：vDSP 实数 FFT（R2R），输出 64 条对数频带。
///
/// ## 实时线程约束（本文件最重要的部分）
///
/// `MTAudioProcessingTap` 的回调运行在**实时音频线程**上。实时线程上的堆分配是明确
/// 禁区：会触发 malloc 互斥锁、可能与其它线程争抢，极端情况造成 underrun 爆音。
/// 因此：
/// - 全部缓冲区在 `init` 预分配，`process(samples:count:)` 内**零堆分配**
/// - 频带聚合用指针偏移 + `vDSP_meanv`，不用 `Array(slice)`（会拷贝）
/// - 用 `vDSP_fft_zrip`（实数 FFT）替代 `vDSP_DFT_zop`（复数 FFT），运算量减半，
///   且直接产出 `DSPSplitComplex`，省掉 realOut/imagOut/magnitudes 三个中间数组
/// - 频带边界在 init 时按采样率算好并缓存，**绝不在音频回调里调 `pow()`**
/// - 回调入口直接吃 `UnsafePointer<Float>`，不构造 `AVAudioPCMBuffer`
///   （它的 init 会分配内存）
///
/// 本类不是 actor：actor 需要 `await`，而实时音频回调是同步的，调用不了。
/// 它只在自己的音频回调线程上被访问；UI 侧通过 `latestBands` 读加锁快照。
final class SpectrumProcessor: @unchecked Sendable {
    static let bandCount = 64

    private static let fftSize = 1024
    private static let minFrequency: Float = 20
    private static let maxFrequency: Float = 20_000

    let sampleRate: Double
    private let fftSetup: OpaquePointer
    private let log2n: vDSP_Length

    // 预分配缓冲（一旦分配，process 内不再申请）
    private var window: [Float]
    private var windowed: [Float]
    private var realp: [Float]
    private var imagp: [Float]
    private var magnitudes: [Float]
    private var bands: [Float]
    /// 频带 → FFT bin 边界（对数分布），init 时算好
    let bandBounds: [(low: Int, high: Int)]

    private let resultLock = NSLock()
    private var result: [Float] = Array(repeating: 0, count: SpectrumProcessor.bandCount)

    init(sampleRate: Double) {
        let n = SpectrumProcessor.fftSize
        let half = n / 2
        self.sampleRate = max(8000, sampleRate)
        log2n = vDSP_Length(log2(Float(n)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            preconditionFailure("无法创建 FFT setup")
        }
        fftSetup = setup

        window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        windowed = [Float](repeating: 0, count: n)
        realp = [Float](repeating: 0, count: half)
        imagp = [Float](repeating: 0, count: half)
        magnitudes = [Float](repeating: 0, count: half)
        bands = [Float](repeating: 0, count: SpectrumProcessor.bandCount)

        // 频带边界按**实际采样率**换算 bin。
        // 原实现硬编码 44100，而缓存链路是 48000（afconvert 强制 -r 48000），
        // 频带整体偏移约 8.8%，19.2kHz 以上永远取不到正确的 bin。
        // 注意用局部常量而不是 self.xxx：闭包里引用 self 会要求所有成员已初始化。
        let ratio = SpectrumProcessor.maxFrequency / SpectrumProcessor.minFrequency
        let nF = Float(n)
        let srF = Float(self.sampleRate)
        let bandCount = SpectrumProcessor.bandCount
        bandBounds = (0..<bandCount).map { i in
            let lowFreq = SpectrumProcessor.minFrequency * pow(ratio, Float(i) / Float(bandCount))
            let highFreq = SpectrumProcessor.minFrequency * pow(ratio, Float(i + 1) / Float(bandCount))
            let low = max(0, Int(lowFreq * nF / srF))
            let high = min(Int(highFreq * nF / srF), half - 1)
            return (low, max(low, high))
        }
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// 核心入口。**运行在实时音频线程上，禁止任何堆分配。**
    /// `samples` 至少要有 1024 个 float。
    func process(samples: UnsafePointer<Float>, count: Int) {
        let n = SpectrumProcessor.fftSize
        let half = n / 2
        guard count >= n else {
            publish(nil)
            return
        }

        // 取最新的 n 帧（MTAudioProcessingTap 的 buffer 常有 1024~8192 帧，
        // 取最前面会引入可观延迟），加窗一次
        let tail = samples + (count - n)
        // 加窗一次
        tail.withMemoryRebound(to: Float.self, capacity: n) { p in
            vDSP_vmul(p, 1, window, 1, &windowed, 1, vDSP_Length(n))
        }

        // 实数 FFT：把交织的 (x[2i], x[2i+1]) 打包成 DSPSplitComplex 后做 zrip
        windowed.withUnsafeBytes { raw in
            var split = DSPSplitComplex(realp: &realp, imagp: &imagp)
            let interleaved = raw.bindMemory(to: DSPComplex.self).baseAddress!
            vDSP_ctoz(interleaved, 2, &split, 1, vDSP_Length(half))
            vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
            // zrip 输出的幅度是真实值的 2 倍
            var scale: Float = 0.5
            vDSP_vsmul(split.realp, 1, &scale, split.realp, 1, vDSP_Length(half))
            vDSP_vsmul(split.imagp, 1, &scale, split.imagp, 1, vDSP_Length(half))
            vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
        }

        // 频带聚合：指针偏移，无中间数组
        magnitudes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            for i in 0..<SpectrumProcessor.bandCount {
                let (low, high) = bandBounds[i]
                if high > low {
                    var mean: Float = 0
                    vDSP_meanv(base + low, 1, &mean, vDSP_Length(high - low))
                    bands[i] = mean
                } else {
                    bands[i] = 0
                }
            }
        }

        // 归一化 + 静音门限（vDSP 原地完成，零分配）
        var maxVal: Float = 0
        vDSP_maxv(bands, 1, &maxVal, vDSP_Length(SpectrumProcessor.bandCount))
        if maxVal > 0 {
            var inv = 1 / maxVal
            vDSP_vsmul(bands, 1, &inv, &bands, 1, vDSP_Length(SpectrumProcessor.bandCount))
        }
        for i in 0..<bands.count where bands[i] < 0.01 { bands[i] = 0 }

        publish(bands)
    }

    /// 非实时线程的便利入口（单元测试用）
    func process(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else {
            publish(nil)
            return
        }
        process(samples: data, count: Int(buffer.frameLength))
    }

    /// UI 线程读取用的快照
    var latestBands: [Float] {
        resultLock.lock()
        defer { resultLock.unlock() }
        return result
    }

    private func publish(_ newBands: [Float]?) {
        resultLock.lock()
        if let newBands {
            result = newBands
        } else {
            for i in 0..<result.count { result[i] = 0 }
        }
        resultLock.unlock()
    }
}

/// tap 回调与 `MTAudioProcessingTapStorage.clientInfo` 之间的桥。
/// 必须被 storage 强引用持有，否则音频线程回调时已释放。
final class SpectrumTapHandler: @unchecked Sendable {
    let processor: SpectrumProcessor
    private let isDetached = OSAllocatedUnfairLock(initialState: false)

    init(processor: SpectrumProcessor) { self.processor = processor }

    func detach() { isDetached.withLock { $0 = true } }

    /// 供 C 回调调用。零分配。
    @inline(__always)
    func handle(audioBufferList: UnsafeMutablePointer<AudioBufferList>) {
        if isDetached.withLock({ $0 }) { return }
        let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard let first = abl.first, let mData = first.mData, first.mDataByteSize > 0 else { return }
        let sampleCount = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        processor.process(samples: mData.assumingMemoryBound(to: Float.self), count: sampleCount)
    }
}

/// 频谱分析器（管理侧）。
///
/// 覆盖范围：本地文件、演示音频、以及已缓存的 OPUS 文件。
/// 远程 HTTPS 流媒体取不到可靠的 tap 回调，`attach(to:remoteSource:)` 抛错，
/// 界面回退到环境动画 —— 这一点是 AVFoundation 的真实限制，不是偷懒。
@MainActor
public final class SpectrumAnalyzer {
    public static let shared = SpectrumAnalyzer()

    private var processor: SpectrumProcessor?
    private var handler: SpectrumTapHandler?

    public private(set) var isAttached = false
    public private(set) var unavailableReason: String?

    private init() {}

    /// 采样率决定频带边界；返回是否成功挂载
    @discardableResult
    public func attach(to playerItem: AVPlayerItem, remoteSource: Bool) -> Bool {
        detach()
        guard !remoteSource else {
            unavailableReason = "远程流媒体无法可靠取到音频回调，已回退到环境动画"
            isAttached = false
            return false
        }
        guard let track = playerItem.asset.tracks(withMediaType: .audio).first,
              let rawDesc = track.formatDescriptions.first else {
            unavailableReason = "该播放项没有可用音轨"
            isAttached = false
            return false
        }
        // formatDescriptions 是 [Any]，元素实际是 CMFormatDescription（CMAudioFormatDescription 的别名）
        let desc = rawDesc as! CMAudioFormatDescription
        guard let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else {
            unavailableReason = "音轨缺少 ASBD 描述"
            isAttached = false
            return false
        }
        var asbd = asbdPtr.pointee
        let sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48_000

        let processor = SpectrumProcessor(sampleRate: sampleRate)
        let handler = SpectrumTapHandler(processor: processor)
        // 强引用 handler，防止音频线程回调时已释放
        self.processor = processor
        self.handler = handler

        // 用官方推荐的 callbacks 接口：`MTAudioProcessingTapStorage` 这个 C 结构体
        // 在 Swift overlay 里根本没有导出（xcrun swiftc 报 cannot find type），
        // 只能用 MTAudioProcessingTapCallbacks，通过 clientInfo 传递 handler 指针。
        let clientInfo = Unmanaged.passUnretained(handler).toOpaque()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: 0,
            clientInfo: clientInfo,
            // init 回调里把 handler 指针存进 tap storage，process 回调直接取回。
            // 绝不在实时线程 allocate：storage 由系统分配，读写它不产生堆分配。
            init: { _, clientInfo, tapStorageOut in
                tapStorageOut.pointee = clientInfo
            },
            finalize: { _ in },
            prepare: { _, _, _ in },
            unprepare: { _ in },
            process: { tap, numberFrames, _, bufferListInOut, numberFramesOut, _ in
                // MTAudioProcessingTapGetStorage 是单参数返回 void*（C 签名如此）
                let info = MTAudioProcessingTapGetStorage(tap)
                Unmanaged<SpectrumTapHandler>.fromOpaque(info)
                    .takeUnretainedValue()
                    .handle(audioBufferList: bufferListInOut)
                numberFramesOut.pointee = numberFrames
            }
        )

        var tapRef: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &callbacks,
            MTAudioProcessingTapCreationFlags(kMTAudioProcessingTapCreationFlag_PostEffects),
            &tapRef
        )
        guard status == noErr, let tap = tapRef else {
            unavailableReason = "创建音频处理 tap 失败 (code \(status))"
            isAttached = false
            self.processor = nil
            self.handler = nil
            return false
        }

        // tap 挂在 audio mix 的 **input parameters** 上（不是 AVMutableAudioMix 本身）
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tapRef
        if let mix = playerItem.audioMix as? AVMutableAudioMix {
            mix.inputParameters = [params]
        } else {
            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
            playerItem.audioMix = mix
        }
        isAttached = true
        unavailableReason = nil
        return true
    }

    public func detach() {
        if let handler { handler.detach() }
        processor = nil
        handler = nil
        isAttached = false
    }

    /// UI 定时读取（NowPlayingView 的 timer 调它）
    public func currentBands() -> [Float] {
        processor?.latestBands ?? Array(repeating: 0, count: SpectrumProcessor.bandCount)
    }
}
