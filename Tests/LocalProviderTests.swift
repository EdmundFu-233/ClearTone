import XCTest

/// 本地曲库导入去重。
///
/// `contains` 只检查已入库的 `importedSongs`，不看本次调用里已收下的，
/// 于是同一批里出现重复路径（或目录遍历同时给出符号链接与目标）会导入两次。
@MainActor
final class LocalProviderTests: XCTestCase {

    func testImportDeduplicatesWithinBatch() async throws {
        await DemoAudioGenerator.ensureFiles()
        let fileURL = DemoAudioGenerator.directory().appendingPathComponent("tone_440.wav")
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw XCTSkip("测试音频生成失败")
        }

        let provider = LocalProvider()
        let imported = try await provider.importFiles([fileURL, fileURL, fileURL])

        XCTAssertEqual(imported.count, 1, "同一批内的重复路径只应导入一次")
        let all = await provider.allSongs()
        XCTAssertEqual(all.count, 1)
    }
}
