import XCTest
@testable import ClearTone

final class ResponseCacheIsolationTests: XCTestCase {
    private func key(cookie: String? = "session-A") -> String {
        NeteaseProvider.cacheKey(path: "/msg/notices", query: [:], cookie: cookie)
    }

    func testAuthenticatedAccountsDoNotShareResponseCache() async {
        let provider = NeteaseProvider()
        let generation = await provider.responseCacheGeneration
        await provider.cacheResponse(Data("private-A".utf8), forKey: key(), ttl: 60, generation: generation)
        let a = await provider.cachedResponse(forKey: key())
        let b = await provider.cachedResponse(forKey: key(cookie: "session-B"))
        let anonymous = await provider.cachedResponse(forKey: key(cookie: nil))
        XCTAssertEqual(a, Data("private-A".utf8))
        XCTAssertNil(b)
        XCTAssertNil(anonymous)
        XCTAssertFalse(key().contains("session-A"))
        XCTAssertEqual(key(cookie: nil), key(cookie: ""))
    }

    func testClearingCacheRejectsLateResponseFromPreviousGeneration() async {
        let provider = NeteaseProvider()
        let oldGeneration = await provider.responseCacheGeneration
        await provider.clearCache()
        await provider.cacheResponse(Data("old".utf8), forKey: key(), ttl: 60, generation: oldGeneration)
        let old = await provider.cachedResponse(forKey: key())
        XCTAssertNil(old)
        let currentGeneration = await provider.responseCacheGeneration
        await provider.cacheResponse(Data("new".utf8), forKey: key(), ttl: 60, generation: currentGeneration)
        let current = await provider.cachedResponse(forKey: key())
        XCTAssertEqual(current, Data("new".utf8))
    }

    func testWriteInvalidationRejectsLateReadButKeepsUnrelatedCache() async {
        let provider = NeteaseProvider()
        let oldGeneration = await provider.responseCacheGeneration
        let commentsKey = NeteaseProvider.cacheKey(path: "/comment/new", query: ["id": "42"], cookie: "session-A")
        await provider.cacheResponse(Data("notices".utf8), forKey: key(), ttl: 60, generation: oldGeneration)
        await provider.cacheResponse(Data("stale".utf8), forKey: commentsKey, ttl: 60, generation: oldGeneration)
        await provider.invalidateCache(pathPrefix: "/comment/new")
        await provider.cacheResponse(Data("late-stale".utf8), forKey: commentsKey, ttl: 60, generation: oldGeneration)
        let comments = await provider.cachedResponse(forKey: commentsKey)
        let notices = await provider.cachedResponse(forKey: key())
        XCTAssertNil(comments)
        XCTAssertEqual(notices, Data("notices".utf8))
    }

    func testQuerySeparatorsCannotCollideWithOtherParameters() {
        let a = NeteaseProvider.cacheKey(path: "/cloudsearch", query: ["a": "x&b=y"], cookie: nil)
        let b = NeteaseProvider.cacheKey(path: "/cloudsearch", query: ["a": "x", "b": "y"], cookie: nil)
        XCTAssertNotEqual(a, b)
        let ordered = NeteaseProvider.cacheKey(path: "/cloudsearch", query: ["b": "y", "a": "x"], cookie: nil)
        XCTAssertEqual(b, ordered)
    }

    func testExpiredResponseIsNotReturned() async {
        let provider = NeteaseProvider()
        let generation = await provider.responseCacheGeneration
        await provider.cacheResponse(Data("old".utf8), forKey: key(), ttl: -1, generation: generation)
        let response = await provider.cachedResponse(forKey: key())
        XCTAssertNil(response)
    }
}
