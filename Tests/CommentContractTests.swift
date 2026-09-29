import XCTest
@testable import ClearTone

final class CommentContractTests: XCTestCase {
    private struct Vectors: Decodable {
        struct Read: Decodable {
            let query: [String: String]
            let uri: String
            let payload: String
            let ciphertext: String
        }
        struct Write: Decodable { let query: [String: String]; let uri: String }
        let reads: [Read]
        let writes: [Write]
    }

    private func vectors() throws -> Vectors {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/NeteaseCommentVectors.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    // 期望 payload 与密文由仓库内真实 Node module + util/crypto.js 生成。
    func testSortingAndPaginationMatchBundledNodeModuleByteForByte() throws {
        for vector in try vectors().reads {
            let sort = try XCTUnwrap(CommentSort.allCases.first { String($0.apiValue) == vector.query["sortType"] })
            let query = NeteaseProvider.commentQuery(
                songID: "42", sort: sort, page: Int(vector.query["pageNo"]!)!,
                pageSize: 20, cursor: vector.query["cursor"]
            )
            XCTAssertEqual(query, vector.query)
            let endpoint = try XCTUnwrap(NeteaseEndpoint.endpoint(forRoute: "/comment/new"))
            XCTAssertEqual(endpoint.apiPath, vector.uri)
            XCTAssertEqual(endpoint.crypto, .eapi)
            let payload = try XCTUnwrap(NeteaseEndpoint.orderedPayload(forRoute: "/comment/new", query: query))
            XCTAssertEqual(OrderedJSON.encode(payload), vector.payload)
            XCTAssertEqual(try NeteaseCrypto.eapi(uri: vector.uri, payload: payload), vector.ciphertext)
        }
    }

    func testBothLikeActionsUseExistingHelperRouteWithSongType() throws {
        for vector in try vectors().writes {
            let query = NeteaseProvider.commentLikeQuery(songID: "42", commentID: "99", like: vector.query["t"] == "1")
            XCTAssertEqual(query, vector.query)
            XCTAssertEqual(vector.uri, query["t"] == "1" ? "/api/v1/comment/like" : "/api/v1/comment/unlike")
        }
        XCTAssertNil(NeteaseEndpoint.endpoint(forRoute: "/comment/unlike"))
    }

    func testProductionParserReadsNestedPageAndCommentID() throws {
        let raw = Data(#"{"code":200,"data":{"totalCount":60,"hasMore":true,"comments":[{"commentId":99,"id":42,"content":"好听","time":1758700000123,"likedCount":12,"liked":true,"user":{"userId":7,"nickname":"用户"},"beReplied":[{"content":"确实","user":{"nickname":"另一用户"}}]}]}}"#.utf8)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let page = try NeteaseProvider.mapCommentPage(json, myID: "7")
        XCTAssertEqual(page.total, 60)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.nextCursor, "1758700000123")
        let comment = try XCTUnwrap(page.comments.first)
        XCTAssertEqual(comment.id, "99")
        XCTAssertTrue(comment.isMine)
        XCTAssertTrue(comment.isLiked)
        XCTAssertEqual(comment.likedCount, 12)
        XCTAssertEqual(comment.replyToNickname, "另一用户")
        XCTAssertEqual(comment.time.timeIntervalSince1970, 1_758_700_000.123, accuracy: 0.001)
    }

    func testMalformedPageThrowsRatherThanBecomingEmptySuccess() {
        XCTAssertThrowsError(try NeteaseProvider.mapCommentPage(["code": 200], myID: nil))
    }
}
