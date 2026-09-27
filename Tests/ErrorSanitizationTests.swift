import XCTest

/// P2-5 / P2-6：错误文案与脱敏。
///
/// 这一组防的是**凭据泄漏到日志与界面**，以及随系统语言变化的错误文案。
@MainActor
final class ErrorSanitizationTests: XCTestCase {

    // MARK: - 脱敏

    /// 回归：原实现只认 `KEY=VALUE`，于是 JSON 形态的凭据整串进日志。
    /// 网易云 Cookie 注入请求体后正是 `"MUSIC_U":"..."` 这个形状。
    func testJSONShapedCredentialsAreRedacted() {
        let out = CTLog.sanitize(#"{"MUSIC_U":"abc123def","MUSIC_A":"99887766"}"#)
        XCTAssertFalse(out.contains("abc123def"), "MUSIC_U 的值漏出来了")
        XCTAssertFalse(out.contains("99887766"), "MUSIC_A 的值漏出来了")
        XCTAssertTrue(out.contains("MUSIC_U"), "键名应保留，否则无法定位是哪类凭据")
    }

    func testQueryShapedCredentialsAreRedacted() {
        let out = CTLog.sanitize("MUSIC_U=1a2b3c4d5e&other=keep")
        XCTAssertFalse(out.contains("1a2b3c4d5e"))
        XCTAssertTrue(out.contains("other=keep"), "相邻的非敏感参数不该被吃掉")
    }

    func testCookieHeaderIsRedacted() {
        let out = CTLog.sanitize("Cookie: MUSIC_U=xyz; __csrf=qqq; MTgI4.json")
        XCTAssertFalse(out.contains("xyz"))
        XCTAssertFalse(out.contains("qqq"))
        XCTAssertTrue(out.contains("MTgI4.json"), "cookie 段之后的独立内容不该被吃掉")
    }

    /// `Authorization: Bearer <jwt>` 的值里**含空格**。
    /// 只按空白截断的话会抹掉 `Bearer` 而把 JWT 整段留在日志里。
    func testBearerTokenValueWithSpacesIsFullyRedacted() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abcdef"
        let out = CTLog.sanitize("authorization=Bearer \(jwt)")
        XCTAssertFalse(out.contains(jwt), "JWT 整段漏出来了")
        XCTAssertFalse(out.contains("Bearer eyJ"), "只剩 Bearer 被抹掉不算脱敏")
    }

    /// 之前漏掉的字段
    func testPreviouslyMissedKeysAreCovered() {
        for key in ["MUSIC_A", "MUSIC_R", "__remember_me", "NMTID", "password", "secret"] {
            let out = CTLog.sanitize("\(key)=s3cr3t-value")
            XCTAssertFalse(out.contains("s3cr3t-value"), "\(key) 没有被脱敏")
        }
    }

    /// 过度脱敏也是缺陷：把正常文案啃掉会让日志失去诊断价值
    func testNormalMessagesAndLookalikeWordsAreUntouched() {
        let message = "加载歌单失败：接口错误 (400)：参数不对"
        XCTAssertEqual(CTLog.sanitize(message), message)

        for lookalike in ["cacheKey=abc", "monkey=def", "hotkey=1", "keyboard=zzz"] {
            XCTAssertEqual(CTLog.sanitize(lookalike), lookalike, "\(lookalike) 被误伤了")
        }
    }

    // MARK: - 错误归一化

    /// 回归：`error.localizedDescription` **随系统语言变化**。
    /// 英文系统上原本会显示 "The Internet connection appears to be offline."，
    /// 与 App 其它地方的中文文案不一致，单测也没法断言。
    func testURLNetworkErrorsMapToStableChineseMessages() {
        XCTAssertEqual(
            MusicError.from(URLError(.notConnectedToInternet)), .networkUnavailable
        )
        XCTAssertEqual(
            MusicError.from(URLError(.networkConnectionLost)), .networkUnavailable
        )
        XCTAssertEqual(MusicError.from(URLError(.timedOut)), .helperProcessTimeout)
        XCTAssertEqual(MusicError.from(URLError(.cannotFindHost)), .networkUnavailable)
    }

    /// 被取消的请求原来会被当成真实失败弹给用户
    func testCancellationIsNotSwallowedIntoUnknownError() {
        XCTAssertEqual(MusicError.from(URLError(.cancelled)), .cancelled)
    }

    /// 已经是 MusicError 的应当原样透传，不要二次包装丢掉语义
    func testMusicErrorPassesThrough() {
        XCTAssertEqual(MusicError.from(MusicError.rateLimited), .rateLimited)
        XCTAssertEqual(MusicError.from(MusicError.apiError(code: 400, message: "x")),
                       .apiError(code: 400, message: "x"))
    }

    /// 兜底也不能用 localizedDescription
    func testUnknownErrorDoesNotLeakLocalizedDescription() {
        struct Weird: LocalizedError { var errorDescription: String? { "The operation couldn’t be completed." } }
        let mapped = MusicError.from(Weird())
        guard case .unknown(let text) = mapped else {
            return XCTFail("应当落到 .unknown，实际是 \(mapped)")
        }
        XCTAssertFalse(text.contains("couldn"), "兜底文案里不该出现 localizedDescription：\(text)")
    }

    func testRetryableClassification() {
        XCTAssertTrue(MusicError.networkUnavailable.isRetryable)
        XCTAssertTrue(MusicError.rateLimited.isRetryable)
        XCTAssertTrue(MusicError.apiError(code: 502, message: "").isRetryable)
        XCTAssertTrue(MusicError.apiError(code: 429, message: "").isRetryable)
        // 4xx 是请求本身错了，重试没有意义
        XCTAssertFalse(MusicError.apiError(code: 400, message: "").isRetryable)
        XCTAssertFalse(MusicError.notLoggedIn.isRetryable)
        XCTAssertFalse(MusicError.cancelled.isRetryable)
    }

    // MARK: - UI 出口

    /// 服务端 message 直接进 UI 等于把内部细节抛给用户；
    /// 网易云在 Cookie 注入出错时会把凭据回显在 message 里。
    func testUserFacingMessageIsSanitized() {
        let error = MusicError.apiError(
            code: 400, message: #"invalid cookie {"MUSIC_U":"leaked-token"}"#
        )
        let shown = error.userFacingMessage
        XCTAssertFalse(shown.contains("leaked-token"), "服务端回显的凭据被原样显示：\(shown)")
    }

    /// `Error.ctUserMessage` 是 UI 的统一出口
    func testErrorProtocolUserMessagePrefersMusicErrorText() {
        let message = (MusicError.notLoggedIn as Error).ctUserMessage
        XCTAssertEqual(message, MusicError.notLoggedIn.errorDescription)
        XCTAssertFalse(message.isEmpty)
    }
}
