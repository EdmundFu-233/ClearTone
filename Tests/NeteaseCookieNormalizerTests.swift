import XCTest
@testable import ClearTone

/// 网易云 cookie 归一化。
///
/// ## 这条测试对应一个真实的数据缺陷
///
/// `api/module/login_qr_check.js` 返回 `cookie: result.cookie.join(';')`，
/// 而 `result.cookie` 是**一整组 `Set-Cookie` 响应头**。每个元素本身就形如
/// `MUSIC_U=xxx; Max-Age=...; Expires=...; Path=/`，再按 `;` 一拼，
/// 实测那条 cookie 有 **134 段**、其中只有 6 个是真 cookie。
/// 原实现原样存进钥匙串，于是每个请求的 `Cookie:` 头都带着
/// `Expires=Mon, 18 Oct 2094 00:19:44 GMT` 这种**未编码的非法值**。
final class NeteaseCookieNormalizerTests: XCTestCase {

    /// 实测那条 cookie 的开头几段（用户真实凭据的结构，值已打码）
    private static let realWorldSample = [
        "MUSIC_R_T=1439570921116",
        "Max-Age=2147483647",
        "Expires=Mon, 18 Oct 2094 00:19:44 GMT",
        "Path=/openapi/clientlog",
        "MUSIC_A_T=1439570921113",
        "__csrf=b3e16df935cbc74e23017ffc0e6ea12c",
        "MUSIC_U=005BA38F62CFF322CC7F662320D503E7CE5BBC41",
        "MUSIC_SNS=",
        "Max-Age=0",
    ].joined(separator: "; ")

    func testDropsCookieAttributes() {
        let result = NeteaseCookieNormalizer.normalize(Self.realWorldSample)
        for attribute in ["Expires=", "Max-Age=", "Path="] {
            XCTAssertFalse(result.contains(attribute), "\(attribute) 是 cookie 属性，不该发回上游")
        }
    }

    func testKeepsRealCredentials() {
        let result = NeteaseCookieNormalizer.normalize(Self.realWorldSample)
        XCTAssertTrue(result.contains("__csrf=b3e16df935cbc74e23017ffc0e6ea12c"))
        XCTAssertTrue(result.contains("MUSIC_U=005BA38F62CFF322CC7F662320D503E7CE5BBC41"))
    }

    /// 空值 cookie（`MUSIC_SNS=` 配 `Max-Age=0`，服务端正在删它）不该留下 ——
    /// 留在请求里只会让上游看到一个自相矛盾的凭据。
    func testDropsEmptyValues() {
        let result = NeteaseCookieNormalizer.normalize(Self.realWorldSample)
        XCTAssertFalse(result.contains("MUSIC_SNS"))
    }

    /// 真实那条 cookie 里 `MUSIC_R_U` 出现了两次。必须去重。
    func testDeduplicatesRepeatedNames() {
        let raw = "MUSIC_R_U=AAAA; MUSIC_U=BBBB; Path=/x; MUSIC_R_U=CCCC"
        let result = NeteaseCookieNormalizer.normalize(raw)
        XCTAssertEqual(result, "MUSIC_R_U=AAAA; MUSIC_U=BBBB")
    }

    /// 134 段 → 6 段。这是对真实凭据形状的断言。
    func testRealWorldCookieShrinksToSixEntries() {
        let raw = [
            "MUSIC_R_T=1", "Max-Age=2147483647", "Expires=Mon, 18 Oct 2094 00:19:44 GMT", "Path=/openapi/clientlog",
            "MUSIC_A_T=2", "Max-Age=2147483647", "Expires=Mon, 18 Oct 2094 00:19:44 GMT", "Path=/eapi/clientlog",
            "MUSIC_R_U=R", "Max-Age=15552000", "Expires=Sun, 28 Mar 2027 21:05:37 GMT", "Path=/eapi/login/token/refresh",
            "__csrf=CSRF", "Max-Age=1296010", "Expires=Wed, 14 Oct 2026 21:05:47 GMT", "Path=/",
            "MUSIC_R_U=R", "Max-Age=15552000", "Expires=Sun, 28 Mar 2027 21:05:37 GMT", "Path=/api/login/token/refresh",
            "MUSIC_U=U", "Max-Age=15552000", "Expires=Sun, 28 Mar 2027 21:05:37 GMT", "Path=/",
            "MUSIC_SNS=", "Max-Age=0", "Expires=Tue, 29 Sep 2026 21:05:37 GMT", "Path=/",
        ].joined(separator: "; ")
        let result = NeteaseCookieNormalizer.normalize(raw)
        let pairs = result.split(separator: ";")
        XCTAssertEqual(pairs.count, 5, "应为 5 个：MUSIC_R_T / MUSIC_A_T / MUSIC_R_U / __csrf / MUSIC_U")
        XCTAssertEqual(result, "MUSIC_R_T=1; MUSIC_A_T=2; MUSIC_R_U=R; __csrf=CSRF; MUSIC_U=U")
    }

    /// 值里带 `=` 时不能被截断（只切第一个 `=`）
    func testValueContainingEqualsIsPreserved() {
        XCTAssertEqual(
            NeteaseCookieNormalizer.normalize("TOKEN=a=b=c; X=1"),
            "TOKEN=a=b=c; X=1"
        )
    }

    /// 已经是规范形式的输入必须原样重建 —— 这是「读路径也能调」的根据。
    func testAlreadyNormalizedInputIsUnchanged() {
        let clean = "MUSIC_U=U; __csrf=C"
        XCTAssertEqual(NeteaseCookieNormalizer.normalize(clean), clean)
    }

    /// 幂等：归一化两次的结果与一次相同。
    /// 读路径每次都调，**必须**幂等，否则每读一次就再改一次字符串。
    func testNormalizeIsIdempotent() {
        let once = NeteaseCookieNormalizer.normalize(Self.realWorldSample)
        let twice = NeteaseCookieNormalizer.normalize(once)
        XCTAssertEqual(once, twice)
    }

    func testEmptyAndGarbageInputProduceEmptyString() {
        XCTAssertEqual(NeteaseCookieNormalizer.normalize(""), "")
        XCTAssertEqual(NeteaseCookieNormalizer.normalize("   "), "")
        XCTAssertEqual(NeteaseCookieNormalizer.normalize(";;;"), "")
        XCTAssertEqual(NeteaseCookieNormalizer.normalize("no-equals-sign"), "")
    }

    /// 属性名大小写不敏感（`expires` 与 `Expires` 都该被丢掉）
    func testAttributeNamesAreCaseInsensitive() {
        let result = NeteaseCookieNormalizer.normalize("A=1; expires=x; MAX-AGE=1; Path=/; b=2")
        XCTAssertEqual(result, "A=1; b=2")
    }

    // MARK: - 读路径

    /// `loadLoginCookie()` 不会自我递归。
    ///
    /// 这条是被一次真实的启动崩溃逼出来的：为了把 18 处 cookie 读取点
    /// 收敛到 `loadLoginCookie()`，做了一次全局字符串替换，结果连它自己
    /// 体内那一行也被替换成 `try Self.loadLoginCookie()` —— 无限递归、
    /// 栈溢出，`EXC_BAD_ACCESS`，App 一起就崩。
    ///
    /// 崩溃栈全是 `loadLoginCookie`，但**没有任何编译期或静态检查会报**；
    /// 而且这个函数在测试里**可调用**（`KeychainStore` 走
    /// `PlaintextCredentialStore`，持久化已被 `run-tests.sh` 重定向），
    /// 所以一条「调用它不崩」的断言就足以锁住。
    func testLoadLoginCookieDoesNotRecurseInForever() throws {
        // 不管有没有存过凭据，都必须正常返回而不是把栈打爆
        let cookie = try NeteaseProvider.loadLoginCookie()
        if let cookie {
            // 存在凭据时，返回的必然是归一化后的形式
            XCTAssertFalse(cookie.contains("Expires="))
            XCTAssertFalse(cookie.contains("Path="))
            XCTAssertFalse(cookie.contains("Max-Age="))
        }
    }
}
