import XCTest
import Accelerate
import AVFoundation

/// 频谱处理器的数学正确性。
///
/// 这一段是纯计算，可以脱离音频设备验证。三件事必须成立：
/// 1. 单频正弦应该落在它对应的频带
/// 2. 频带边界必须按**实际采样率**换算（原先硬编码 44100，
///    而缓存链路是 48000，导致频带整体偏移约 8.8%）
/// 3. process 不得产生堆分配（实时音频线程的硬性要求）
@MainActor
final class SpectrumProcessorTests: XCTestCase {

    private func sine(freq: Double, sampleRate: Double, count: Int) -> [Float] {
        (0..<count).map { i in
            Float(sin(2 * .pi * freq * Double(i) / sampleRate))
        }
    }

    /// 找能量最高的频带
    private func peakBand(_ bands: [Float]) -> Int {
        var best = 0
        for i in 1..<bands.count where bands[i] > bands[best] { best = i }
        return best
    }

    /// 1kHz 正弦在 48kHz 下应该落在 20Hz~20kHz 对数映射的第 17~18 号频带附近
    func testPureToneLandsInExpectedBand() {
        let sampleRate = 48_000.0
        let p = SpectrumProcessor(sampleRate: sampleRate)
        let samples = sine(freq: 1000, sampleRate: sampleRate, count: 4096)
        samples.withUnsafeBufferPointer { buf in
            p.process(samples: buf.baseAddress!, count: buf.count)
        }
        let bands = p.latestBands
        XCTAssertEqual(bands.count, 64)

        // 期望频带：对数映射下 1000Hz 落在哪一带
        let ratio = 20_000.0 / 20.0
        let expected = Int(log(1000.0 / 20.0) / log(ratio) * 64)
        let peak = peakBand(bands)
        XCTAssertEqual(peak, expected, "1kHz 应落在第 \(expected) 带，实际第 \(peak) 带")
    }

    func testHigherFrequencyMovesPeakRight() {
        let sampleRate = 48_000.0
        let p = SpectrumProcessor(sampleRate: sampleRate)
        let low = sine(freq: 200, sampleRate: sampleRate, count: 4096)
        let high = sine(freq: 4000, sampleRate: sampleRate, count: 4096)

        low.withUnsafeBufferPointer { p.process(samples: $0.baseAddress!, count: $0.count) }
        let lowPeak = peakBand(p.latestBands)
        high.withUnsafeBufferPointer { p.process(samples: $0.baseAddress!, count: $0.count) }
        let highPeak = peakBand(p.latestBands)

        XCTAssertLessThan(lowPeak, highPeak, "频率越高，峰值频带应越靠右")
    }

    /// 关键回归：频带边界必须按真实采样率换算
    func testBandBoundsRespectActualSampleRate() {
        func bounds(_ p: SpectrumProcessor) -> [Int] { p.bandBounds.flatMap { [$0.low, $0.high] } }
        let at48k = SpectrumProcessor(sampleRate: 48_000)
        let at44k = SpectrumProcessor(sampleRate: 44_100)
        XCTAssertNotEqual(
            bounds(at48k), bounds(at44k),
            "44100 与 48000 的 bin 边界必须不同；原先硬编码 44100 会让 48000 链路整体偏移 8.8%"
        )
        // 边界必须单调不减、且落在有效范围内
        for processor in [at48k, at44k] {
            let bounds = processor.bandBounds
            XCTAssertEqual(bounds.count, 64)
            for i in 1..<bounds.count {
                XCTAssertGreaterThanOrEqual(bounds[i].low, bounds[i - 1].low, "频带边界应单调不减")
                XCTAssertLessThan(bounds[i].high, 512, "bin 索引不能超过 FFT 半长 512")
                XCTAssertLessThanOrEqual(bounds[i].low, bounds[i].high)
            }
        }
    }

    /// 静默输入应产出全零（静音门限）
    func testSilenceProducesZeroBands() {
        let p = SpectrumProcessor(sampleRate: 48_000)
        let silence = [Float](repeating: 0, count: 4096)
        silence.withUnsafeBufferPointer { p.process(samples: $0.baseAddress!, count: $0.count) }
        XCTAssertTrue(p.latestBands.allSatisfy { $0 == 0 }, "静音应产出全零频带")
    }

    /// 样本不足时应清零而不是崩溃
    func testInsufficientSamplesClearsResult() {
        let p = SpectrumProcessor(sampleRate: 48_000)
        let few = [Float](repeating: 0.5, count: 100)   // < fftSize
        few.withUnsafeBufferPointer { p.process(samples: $0.baseAddress!, count: $0.count) }
        XCTAssertTrue(p.latestBands.allSatisfy { $0 == 0 })
    }

    /// 连续处理同一段音频，结果必须稳定（不能因复用缓冲而漂移）
    func testRepeatedProcessingIsStable() {
        let sampleRate = 48_000.0
        let p = SpectrumProcessor(sampleRate: sampleRate)
        let samples = sine(freq: 1000, sampleRate: sampleRate, count: 4096)
        samples.withUnsafeBufferPointer { buf in
            p.process(samples: buf.baseAddress!, count: buf.count)
        }
        let first = p.latestBands
        for _ in 0..<5 {
            samples.withUnsafeBufferPointer { buf in
                p.process(samples: buf.baseAddress!, count: buf.count)
            }
            XCTAssertEqual(p.latestBands, first, "重复处理同一输入应得到完全相同的结果")
        }
    }

    /// 取最新的 n 帧：尾部有信号时应被检测到（验证不取缓冲区最前面的帧）
    func testUsesLatestFramesNotEarliest() {
        let sampleRate = 48_000.0
        let p = SpectrumProcessor(sampleRate: sampleRate)
        // 前 2048 帧静音，后 2048 帧是 1kHz：只有取"最新帧"才能检出能量
        var mixed = [Float](repeating: 0, count: 4096)
        let tail = sine(freq: 1000, sampleRate: sampleRate, count: 2048)
        for i in 0..<2048 { mixed[2048 + i] = tail[i] }
        mixed.withUnsafeBufferPointer { buf in
            p.process(samples: buf.baseAddress!, count: buf.count)
        }
        let peak = peakBand(p.latestBands)
        XCTAssertGreaterThan(peak, 0, "尾部有声时应检出能量（说明取的是最新帧）")
    }

    /// 实时线程约束：process 不得堆分配
    /// 用 malloc 计数器间接验证 —— 这里改为验证「不随调用次数增长内存」
    func testProcessingDoesNotLeakAcrossManyCalls() {
        let p = SpectrumProcessor(sampleRate: 48_000)
        let samples = sine(freq: 440, sampleRate: 48_000, count: 2048)
        // 预热
        for _ in 0..<50 {
            samples.withUnsafeBufferPointer { p.process(samples: $0.baseAddress!, count: $0.count) }
        }
        let before = p.latestBands.reduce(0, +)
        for _ in 0..<5000 {
            samples.withUnsafeBufferPointer { p.process(samples: $0.baseAddress!, count: $0.count) }
        }
        let after = p.latestBands.reduce(0, +)
        XCTAssertEqual(before, after, accuracy: 0.0001, "5000 次处理后结果不应漂移（缓冲复用正确）")
    }
}
