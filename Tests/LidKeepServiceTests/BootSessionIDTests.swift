import XCTest
@testable import LidKeepService

final class BootSessionIDTests: XCTestCase {
    func testRestartedStoresUseKernelSessionRatherThanWallClock() throws {
        let directory = NSTemporaryDirectory() + "lidkeep-boot-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let first = try SecureStore(directory: directory, requireRoot: false)
        let restarted = try SecureStore(directory: directory, requireRoot: false)
        XCTAssertNotNil(UUID(uuidString: first.boot))
        XCTAssertEqual(first.boot, restarted.boot)
        XCTAssertEqual(restarted.boot, try BootSessionID.read())
    }

    func testMalformedKernelValuesFailClosed() {
        let valid = Array("462C1380-F699-4F87-BDB8-C02B56A0C4E6".utf8) + [0]
        for bytes in [[], Array("1789741087.852226".utf8) + [0],
                      Array(valid.dropLast()), valid + [0], [UInt8](repeating: 0, count: 37),
                      [UInt8](repeating: 255, count: 36) + [0]] {
            XCTAssertThrowsError(try BootSessionID.decode(bytes))
        }
    }

    func testUUIDCaseCanonicalizesAndDifferentBootsStayDifferent() throws {
        let first = "462C1380-F699-4F87-BDB8-C02B56A0C4E6"
        XCTAssertEqual(try BootSessionID.decode(Array(first.lowercased().utf8) + [0]), first)
        XCTAssertNotEqual(try BootSessionID.decode(Array(first.utf8) + [0]),
                          try BootSessionID.decode(Array(UUID().uuidString.utf8) + [0]))
    }

    func testLegacySleepIntentIsNotReplayedUnderNewBootIdentity() throws {
        let directory = NSTemporaryDirectory() + "lidkeep-legacy-boot-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let legacy = try SecureStore(directory: directory, requireRoot: false, testBoot: "1789741087.852226")
        _ = try legacy.latch("old episode", sleep: true, token: "old-token")
        let current = try SecureStore(directory: directory, requireRoot: false)
        XCTAssertNil(try current.pendingSleepRequest())
        let latch = try current.latch("new helper session")
        XCTAssertEqual(latch.boot, current.boot)
        XCTAssertFalse(latch.sleepRequested)
        XCTAssertNil(try current.pendingSleepRequest())
    }
}
