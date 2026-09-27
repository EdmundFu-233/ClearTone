import Foundation

/// 合成测试音频（WAV）。
///
/// 演示模式已移除，但**播放器异步状态的单元测试仍然需要一段真实可被 AVPlayer
/// 播放的本地音频** —— `PlayerControllerTests` 用它验证「停止作废在途请求」、
/// 「切歌停表」、「加载期暂停/续播」、「切音质保进度」这几条只靠桩 Provider
/// 测不出来的时序。
///
/// 生产代码不调用这里任何东西，所以 App 启动时不再合成这约 16MB 音频。
public enum DemoAudioGenerator {
    /// 音频目录。
    ///
    /// 尊重 `CLEARTONE_TEST_STORAGE_DIR`，与 `PersistenceStore.storageURL` 用同一个
    /// 开关。这里原先硬编码 Application Support 路径，于是「截断文件应重新生成」
    /// 那条测试会**删掉并重新生成开发者真实 App 目录下的 tone_440.wav** ——
    /// 而同一个文件正被其它测试的 AVPlayer 打开着。
    public static func directory() -> URL {
        PersistenceStore.storageRoot
            .appendingPathComponent("DemoAudio", isDirectory: true)
    }

    /// 音频文件名清单
    public static let files = [
        "tone_440.wav", "tone_1000.wav", "tone_5000.wav", "silence.wav", "sweep.wav", "noise.wav",
    ]

    /// 确保音频已就绪，在后台线程执行。
    ///
    /// 原实现在 `App.init` 里同步调用：6 × 132 万样本、约 530 万次 sin()、
    /// 约 32MB 写入全部阻塞主线程，首帧前会白屏数秒。
    public static func ensureFiles() async {
        await withTaskGroup(of: Void.self) { group in
            for file in files {
                group.addTask {
                    generateIfNeeded(for: file)
                }
            }
        }
    }

    /// 生成单个测试音频文件（已存在且非空则跳过）。
    public static func generateIfNeeded(for file: String) {
        let dir = directory()
        let url = dir.appendingPathComponent(file)
        // 文件存在且有内容就认为已生成：避免每次跑测试都重走一遍完整生成逻辑
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 44 {
            return
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        generate(type: file, to: url)
    }

    /// 合成一段 30 秒单声道 44.1kHz PCM 正弦/噪声并写成 WAV。
    public static func generate(type: String, to url: URL) {
        let sampleRate: Double = 44100
        let duration: Double = 30 // 30 秒
        let frameCount = Int(sampleRate * duration)
        var samples = [Float](repeating: 0, count: frameCount)

        let twoPi: Double = 2 * .pi
        switch type {
        case "tone_440.wav":
            let freq: Double = 440
            for i in 0..<frameCount {
                let t = Double(i) / sampleRate
                samples[i] = Float(sin(twoPi * freq * t) * 0.5)
            }
        case "tone_1000.wav":
            let freq: Double = 1000
            for i in 0..<frameCount {
                let t = Double(i) / sampleRate
                samples[i] = Float(sin(twoPi * freq * t) * 0.5)
            }
        case "tone_5000.wav":
            let freq: Double = 5000
            for i in 0..<frameCount {
                let t = Double(i) / sampleRate
                samples[i] = Float(sin(twoPi * freq * t) * 0.3)
            }
        case "silence.wav":
            break
        case "sweep.wav":
            for i in 0..<frameCount {
                let t = Double(i) / sampleRate
                let freq = 20 + (20000 - 20) * t / duration
                samples[i] = Float(sin(twoPi * freq * t) * 0.4)
            }
        case "noise.wav":
            for i in 0..<frameCount { samples[i] = Float.random(in: -0.3...0.3) }
        default:
            let freq: Double = 440
            for i in 0..<frameCount {
                let t = Double(i) / sampleRate
                samples[i] = Float(sin(twoPi * freq * t) * 0.5)
            }
        }

        writeWAV(samples: samples, sampleRate: sampleRate, to: url)
    }

    private static func writeWAV(samples: [Float], sampleRate: Double, to url: URL) {
        let dataSize = samples.count * 2
        // WAV 头固定 44 字节；RIFF 字段按约定存「文件大小 - 8」= 36 + dataSize
        let headerSize = 44
        let fileSize = headerSize + dataSize
        let riffSize = fileSize - 8

        // 一次性分配：原先逐样本 append 会产生上百万次 Data 扩容拷贝。
        // 头部与样本区都在同一个 withUnsafeMutableBytes 里写完，避免在块外操作裸指针。
        var data = Data(count: fileSize)
        data.withUnsafeMutableBytes { raw in
            let base = raw.baseAddress!

            func put<T: FixedWidthInteger>(_ value: T, at offset: Int) {
                var v = value.littleEndian
                withUnsafeBytes(of: &v) { src in
                    UnsafeMutableRawPointer(base + offset)
                        .copyMemory(from: src.baseAddress!, byteCount: MemoryLayout<T>.size)
                }
            }
            func putBytes(_ bytes: [UInt8], at offset: Int) {
                let dst = UnsafeMutableRawPointer(base + offset).assumingMemoryBound(to: UInt8.self)
                for (i, b) in bytes.enumerated() { dst[i] = b }
            }
            putBytes([0x52, 0x49, 0x46, 0x46], at: 0)      // "RIFF"
            put(UInt32(riffSize), at: 4)
            putBytes([0x57, 0x41, 0x56, 0x45], at: 8)      // "WAVE"
            putBytes([0x66, 0x6D, 0x74, 0x20], at: 12)     // "fmt "
            put(UInt32(16), at: 16)
            put(UInt16(1), at: 20)                         // PCM
            put(UInt16(1), at: 22)                         // mono
            put(UInt32(sampleRate), at: 24)
            put(UInt32(sampleRate * 2), at: 28)            // byte rate
            put(UInt16(2), at: 32)                         // block align
            put(UInt16(16), at: 34)                        // bits
            putBytes([0x64, 0x61, 0x74, 0x61], at: 36)     // "data"
            put(UInt32(dataSize), at: 40)

            // 样本区批量转换写入，替代逐样本 append（偏移 44 对 Int16 是对齐的）
            let dst = UnsafeMutableRawPointer(base + 44).assumingMemoryBound(to: Int16.self)
            for (i, sample) in samples.enumerated() {
                dst[i] = Int16(max(-1, min(1, sample)) * 32767)
            }
        }

        try? data.write(to: url)
    }
}
