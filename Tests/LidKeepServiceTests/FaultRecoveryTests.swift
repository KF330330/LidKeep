import XCTest
import Darwin
import LidKeepCore
@testable import LidKeepService

private final class FaultRunner: CommandRunning {
    var disabled = true
    var unreadable = true
    var refuseRestore = false
    var writes = 0
    func run(_ arguments: [String]) throws -> CommandResult {
        if arguments == ["-g"] {
            if unreadable { throw ServiceError("simulated EBADF") }
            return CommandResult(status: 0, output: "SleepDisabled \(disabled ? 1 : 0)")
        }
        if arguments == ["-a", "disablesleep", "0"] {
            writes += 1
            if refuseRestore { throw ServiceError("simulated restore failure") }
            disabled = false; unreadable = false
            return CommandResult(status: 0, output: "")
        }
        XCTFail("Fault recovery must never enable or sleep: \(arguments)")
        throw ServiceError("unexpected command")
    }
}

final class FaultRecoveryTests: XCTestCase {
    private var directory: String!
    private var store: SecureStore!
    private var runner: FaultRunner!
    private var power: PowerController!
    private let environment = Environment(now: 100, batteryPercent: 80, onAC: false, thermal: .nominal)

    override func setUpWithError() throws {
        directory = NSTemporaryDirectory() + "lidkeep-fault-tests-" + UUID().uuidString
        store = try SecureStore(directory: directory, requireRoot: false, testBoot: "test")
        runner = FaultRunner(); power = PowerController(store: store, runner: runner)
        try store.write(Ownership(boot: store.boot, baseline: 0, createdAt: Date()), to: "ownership.json")
        var policy = PolicyEngine(); policy.verified = true
        XCTAssertTrue(policy.evaluate(environment).keepAwake)
        try store.write(policy, to: "policy.json")
        let desired = DesiredState(boot: store.boot, session: "old", monotonic: 100,
                                   guiHeartbeat: 100, guiUID: getuid(), wantsAwake: true, mode: .active,
                                   stopPercent: 10, testDeadline: nil, acknowledgedSafety: nil, sleepToken: nil)
        try store.write(desired, to: "desired.json")
    }

    override func tearDownWithError() throws {
        power = nil; store = nil
        try FileManager.default.removeItem(atPath: directory)
    }

    private func daemon() throws -> Daemon {
        try Daemon(store: store, manifest: IdentityManifest(clientRequirement: "test", serviceRequirement: "test"), power: power)
    }

    func testUnreadableStatusRevokesPublishedLeaseAndRestoresOwnedPower() throws {
        let daemon = try daemon()
        let status = daemon.status(environment)
        XCTAssertEqual(status.mode, .fault)
        XCTAssertNil(status.sleepDisabled)
        XCTAssertFalse(runner.disabled)
        XCTAssertGreaterThan(runner.writes, 0)
        let safe = try XCTUnwrap(store.read("desired.json", as: DesiredState.self))
        XCTAssertFalse(safe.wantsAwake)
        XCTAssertNil(safe.guiHeartbeat)
        XCTAssertNil(safe.guiUID)
        XCTAssertEqual(safe.mode, .fault)
        XCTAssertNil(try store.read("ownership.json", as: Ownership.self))
        let recovering = try daemon.enforceRuntime(Decision(true, mode: .active, reason: "stale"), environment: environment)
        XCTAssertFalse(recovering.keepAwake)
    }

    func testCorruptSafetyMetadataDoesNotSkipRestoration() throws {
        try store.write(Data("{}".utf8), to: "safety.json")
        _ = try daemon().status(environment)
        XCTAssertFalse(runner.disabled)
        XCTAssertGreaterThan(runner.writes, 0)
        XCTAssertFalse(try XCTUnwrap(store.read("desired.json", as: DesiredState.self)).wantsAwake)
    }

    func testUnconfirmedRecoveryCannotAcceptNewEnableIntent() throws {
        runner.refuseRestore = true
        let daemon = try daemon()
        _ = daemon.status(environment)
        XCTAssertThrowsError(try daemon.enforceRuntime(Decision(true, mode: .active, reason: "new"), environment: environment))
        XCTAssertFalse(try XCTUnwrap(store.read("desired.json", as: DesiredState.self)).wantsAwake)
        XCTAssertNotNil(try store.read("ownership.json", as: Ownership.self))
    }

    func testWatchdogRestartsAfterThreeFailedRecoveries() throws {
        runner.refuseRestore = true
        var restarts = 0
        let watchdog = Watchdog(store: store, power: power, restartAfterFailure: { restarts += 1 })
        for _ in 0..<2 { watchdog.fail(ServiceError("fault")) }
        XCTAssertEqual(restarts, 0)
        watchdog.fail(ServiceError("fault"))
        XCTAssertEqual(restarts, 1)
        XCTAssertNotNil(try store.read("ownership.json", as: Ownership.self))
        XCTAssertNotNil(try store.read("guardian.json", as: GuardianState.self)?.error)
    }

    func testSuccessfulRecoveryResetsRestartCountEvenWithBadSafetyMetadata() throws {
        try store.write(Data("{}".utf8), to: "safety.json")
        runner.refuseRestore = true
        var restarts = 0
        let watchdog = Watchdog(store: store, power: power, restartAfterFailure: { restarts += 1 })
        for _ in 0..<2 { watchdog.fail(ServiceError("fault")) }
        runner.refuseRestore = false
        watchdog.fail(ServiceError("fault"))
        XCTAssertFalse(runner.disabled)
        runner.unreadable = true
        for _ in 0..<2 { watchdog.fail(ServiceError("fault")) }
        XCTAssertEqual(restarts, 0)
        watchdog.fail(ServiceError("fault"))
        XCTAssertEqual(restarts, 1)
    }
}
