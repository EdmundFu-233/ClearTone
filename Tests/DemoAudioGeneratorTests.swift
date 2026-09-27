import XCTest
import AVFoundation

/// 测试音频合成的回归测试。
///
/// `writeWAV` 手写了裸指针写入，属于最容易写错的地方：
/// 曾把 RIFF 约定值 `36 + dataSize`（= 文件大小 - 8）误当作文件长度来分配，
/// 导致每个文件少写 8 字节、尾部被截断。这里用字节级对比 + 真实生成来锁死。
final class DemoAudioGeneratorTests: XCTestCase {

    private var scratchDir: URL!

    override func setUp() {
        super.setUp()
        scratchDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ct-wavtest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratchDir)
        super.tearDown()
    }

    /// 头部与数据长度必须自洽：文件大小 = 44 + dataSize，RIFF 字段 = 文件大小 - 8
    func testWAVFileLengthMatchesHeader() throws {
        let url = scratchDir.appendingPathComponent("t.wav")
        // generate 固定产出 30 秒 / 44100Hz / 单声道 Int16
        DemoAudioGenerator.generate(type: "tone_440.wav", to: url)

        let data = try Data(contentsOf: url)
        let expectedDataSize = 30 * 44100 * 2
        XCTAssertEqual(data.count, 44 + expectedDataSize, "文件长度应为 44 + dataSize，曾因把 RIFF 约定值当文件长度而少 8 字节")

        // 校验头部四个关键字段
        XCTAssertEqual(Array(data[0..<4]), [0x52, 0x49, 0x46, 0x46], "RIFF 魔数")
        XCTAssertEqual(Array(data[8..<12]), [0x57, 0x41, 0x56, 0x45], "WAVE 魔数")
        let riffSize = data[4..<8].withUnsafeBytes { UInt32(littleEndian: $0.load(as: UInt32.self)) }
        XCTAssertEqual(Int(riffSize), data.count - 8, "RIFF 字段应等于文件大小减 8")
        let chunkSize = data[40..<44].withUnsafeBytes { UInt32(littleEndian: $0.load(as: UInt32.self)) }
        XCTAssertEqual(Int(chunkSize), expectedDataSize, "data 块长度")
    }

    /// 幅度边界：+1 / -1 不能溢出 Int16，0 必须精确为 0
    func testSampleClampingIsExact() throws {
        // noise.wav 覆盖整个 [-1, 1] 区间，能自然取到边界值
        let url = scratchDir.appendingPathComponent("noise.wav")
        DemoAudioGenerator.generate(type: "noise.wav", to: url)
        let data = try Data(contentsOf: url)
        let pcm = data.dropFirst(44)
        let values = pcm.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Int16.self).map { Int($0) })
        }
        XCTAssertFalse(values.isEmpty)
        XCTAssertTrue(values.allSatisfy { $0 >= -32767 && $0 <= 32767 }, "转换后不应溢出 Int16")
        // 全零输入（silence）必须精确为 0
        let silenceURL = scratchDir.appendingPathComponent("silence.wav")
        DemoAudioGenerator.generate(type: "silence.wav", to: silenceURL)
        let silence = try Data(contentsOf: silenceURL).dropFirst(44)
        XCTAssertTrue(silence.allSatisfy { $0 == 0 }, "静音样本应全为 0")
    }

    /// 真实生成的 WAV 能被系统解码（走 AVAudioFile 解析）
    func testGeneratedWAVIsDecodable() throws {
        let url = scratchDir.appendingPathComponent("sweep.wav")
        DemoAudioGenerator.generate(type: "sweep.wav", to: url)
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 44100, accuracy: 1)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertGreaterThan(file.length, 44, "应读到实际音频样本")
    }

    /// ensureFiles 幂等：已存在且非空的文件不应被重写
    func testEnsureFilesIsIdempotent() async throws {
        await DemoAudioGenerator.ensureFiles()
        let tone = DemoAudioGenerator.directory().appendingPathComponent("tone_440.wav")
        let firstSize = try FileManager.default.attributesOfItem(atPath: tone.path)[.size] as? Int
        let firstMtime = try FileManager.default.attributesOfItem(atPath: tone.path)[.modificationDate] as? Date

        try await Task.sleep(for: .milliseconds(1100))
        await DemoAudioGenerator.ensureFiles()

        let secondSize = try FileManager.default.attributesOfItem(atPath: tone.path)[.size] as? Int
        let secondMtime = try FileManager.default.attributesOfItem(atPath: tone.path)[.modificationDate] as? Date
        XCTAssertEqual(firstSize, secondSize, "已存在的测试音频不应被重新生成")
        XCTAssertEqual(firstMtime, secondMtime, "mtime 不应变化")
        XCTAssertGreaterThan(firstSize ?? 0, 44, "生成的音频不应只有头部")
    }

    /// 截断的残留文件（上次生成中断）应被重新生成
    func testTruncatedFileIsRegenerated() async throws {
        let tone = DemoAudioGenerator.directory().appendingPathComponent("tone_440.wav")
        try? FileManager.default.removeItem(at: tone)
        FileManager.default.createFile(atPath: tone.path, contents: Data([0x52, 0x49, 0x46, 0x46]))
        await DemoAudioGenerator.ensureFiles()
        let size = try FileManager.default.attributesOfItem(atPath: tone.path)[.size] as? Int
        XCTAssertGreaterThan(size ?? 0, 44, "只有 RIFF 魔数的残留文件应被判定为无效并重新生成")
    }
}
