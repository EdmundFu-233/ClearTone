import XCTest
@testable import ClearTone

final class HelperProcessHardeningTests: XCTestCase {
    // MARK: - 环境变量白名单

    func testDropsInjectionVariables() {
        let env = HelperProcessManager.makeHelperEnvironment(
            from: [
                "HOME": "/Users/tester",
                "TMPDIR": "/tmp/tester",
                "PATH": "/usr/bin:/bin",
                "NODE_OPTIONS": "--require /tmp/evil.js",
                "NODE_EXTRA_CA_CERTS": "/tmp/evil.pem",
                "NODE_TLS_REJECT_UNAUTHORIZED": "0",
                "DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib",
                "LD_PRELOAD": "/tmp/evil.so",
                "HTTP_PROXY": "http://evil.example:8080",
                "HTTPS_PROXY": "http://evil.example:8080",
                "RANDOM_ATTACKER_VALUE": "1",
            ],
            port: 23456,
            authToken: "fixture-token"
        )

        XCTAssertEqual(env["HOME"], "/Users/tester")
        XCTAssertEqual(env["TMPDIR"], "/tmp/tester")
        XCTAssertEqual(env["PATH"], "/usr/bin:/bin")
        XCTAssertNil(env["NODE_OPTIONS"])
        XCTAssertNil(env["NODE_EXTRA_CA_CERTS"])
        XCTAssertNil(env["NODE_TLS_REJECT_UNAUTHORIZED"])
        XCTAssertNil(env["DYLD_INSERT_LIBRARIES"])
        XCTAssertNil(env["LD_PRELOAD"])
        XCTAssertNil(env["RANDOM_ATTACKER_VALUE"])
        XCTAssertEqual(env["HTTP_PROXY"], "")
        XCTAssertEqual(env["HTTPS_PROXY"], "")
        XCTAssertEqual(env["http_proxy"], "")
        XCTAssertEqual(env["https_proxy"], "")
    }

    func testSetsRequiredHelperVariables() {
        let env = HelperProcessManager.makeHelperEnvironment(
            from: [:], port: 21001, authToken: "token-123"
        )
        XCTAssertEqual(env["PORT"], "21001")
        XCTAssertEqual(env["HOST"], "127.0.0.1")
        XCTAssertEqual(env["CT_AUTH_TOKEN"], "token-123")
        XCTAssertEqual(env["NODE_ENV"], "production")
    }

    // MARK: - 日志权限

    func testLogFileIsOwnerOnly() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ct-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("helper.log")
        let handle = HelperProcessManager.makeLogHandle(at: url, maxBytes: 1024)
        defer { try? handle.close() }

        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(mode.intValue & 0o777, 0o600)
    }

    func testExistingWidePermissionsAreTightenedAndRotationStaysOwnerOnly() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ct-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("helper.log")
        try Data(repeating: 0x41, count: 256).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: url.path
        )

        let handle = HelperProcessManager.makeLogHandle(at: url, maxBytes: 128)
        defer { try? handle.close() }

        let rotated = url.appendingPathExtension("1")
        for target in [url, rotated] {
            let mode = try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber
            )
            XCTAssertEqual(mode.intValue & 0o777, 0o600, "\(target.lastPathComponent) 必须仅当前用户可读")
        }
    }
}
