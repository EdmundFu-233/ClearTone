import Foundation
import Accelerate
import AVFoundation
import CoreMedia
import AudioToolbox
import MediaToolbox

/// 频谱处理器：vDSP 实数 FFT（R2R），输出 64 条对数频带。
///
/// ## 当前状态：FFT 数学部分可用，但**尚未接入音频**
///
/// 曾尝试用 `MTAudioProcessingTap` 把本地文件（96kbps OPUS 缓存）
/// 的音频接进来，结果播放卡在 `waitingToPlayAtSpecifiedRate`（界面显示「缓冲中」）。
/// 两个原因：
/// 1. `MTAudioProcessingTapStorage` 这个 C 结构体在 SDK 头文件里根本不存在，
///    `MTAudioProcessingTapGetStorage` 返回的是 `void**` 而非 handler 指针，
///    纯 Swift 里无法安全地把 handler 传进实时音频回调；
/// 2. 即便类型正确，在 KVO 回调里创建 tap 会触发音频管线重新协商格式，
///    对 48kHz OPUS/CAF 缓存文件尤其不稳。
///
/// 所以这里只保留已经修好并有测试覆盖的 FFT 处理器（实时线程安全、采样率正确），
/// 等拿到可靠的接入方式（例如用 ObjC 封装或改用 AVAssetReader 离线分析）再接。
/// 在那之前，界面回退到环境动画 —— 播放稳定比频谱重要得多。
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
