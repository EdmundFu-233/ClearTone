import XCTest
@testable import ClearTone

/// `HelperProcessManager` 的查询串编码。
///
/// 回归：`URLComponents.queryItems` **不会**编码 `+`，而辅助进程是 Express 5，
/// 默认用 Node 的 `querystring` 解析，会把字面 `+` 解码成空格 ——
/// macOS 搜「C++」到上游变成「C  」。这里锁死转义行为。
final class HelperURLTests: XCTestCase {

    func testQueryEncodingEscapesPlusAndReserved() {
        let encoded = HelperProcessManager.percentEncodedQuery([
            "keywords": "C++ a&b=c",
            "limit": "30",
        ])
        // key 排序后 keywords 在前
        XCTAssertEqual(encoded, "keywords=C%2B%2B%20a%26b%3Dc&limit=30")
    }

    func testQueryEncodingIsDeterministic() {
        XCTAssertEqual(
            HelperProcessManager.percentEncodedQuery(["b": "2", "a": "1"]),
            "a=1&b=2"
        )
    }

    func testEmptyQueryEncodesToEmptyString() {
        XCTAssertEqual(HelperProcessManager.percentEncodedQuery([:]), "")
    }
}
