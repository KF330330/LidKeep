import XCTest
import Darwin
import LidKeepCore
@testable import LidKeepService

final class FakePMSet: CommandRunning {
    var disabled = false
    var operations: [[String]] = []
    var refuseEnable = false
    var refuseRestore = false
    var falseSuccess = false
    var errorTextWithZero = false
    var beforeEnable: (() throws -> Void)?
    func run(_ arguments: [String]) throws -> CommandResult {
        operations.append(arguments)
        if arguments == ["-g"] { return CommandResult(status: 0, output: "System-wide power settings:\n SleepDisabled \(disabled ? 1 : 0)\n") }
        if arguments == ["-a", "disablesleep", "1"] {
            try beforeEnable?()
            if refuseEnable { throw ServiceError("enable failed") }
            if !falseSuccess { disabled = true }
        }
        if arguments == ["-a", "disablesleep", "0"] {
            if refuseRestore { throw ServiceError("restore failed") }
            if !falseSuccess { disabled = false }
        }
        return CommandResult(status: 0, output: errorTextWithZero ? "Unable to sleep system: error 0x123" : "")
    }
}

final class RuntimeTests: XCTestCase {
    func testServiceDiagnosticsOnlyReadSelfAndRejectOtherNames() throws {
        let own = try XCTUnwrap(ServiceResourceReading.current(name: "lidkeep-daemon"))
        XCTAssertEqual(own.pid, getpid())
        XCTAssertGreaterThan(own.startTime, 0)
        XCTAssertGreaterThan(own.residentBytes, 0)
        XCTAssertLessThanOrEqual(own.sampledUptime, ProcessInfo.processInfo.systemUptime)
        XCTAssertNil(ServiceResourceReading.current(name: "arbitrary-process"))
    }

    func testOldGuardianStateDecodesWithoutDiagnosticCounters() throws {
        let data = Data("{\"boot\":\"old\",\"monotonic\":1,\"sleepDisabled\":false}".utf8)
        let guardian = try JSONDecoder().decode(GuardianState.self, from: data)
        XCTAssertNil(guardian.diagnostic)
        XCTAssertEqual(guardian.boot, "old")
    }

    func testGuardianDiagnosticFreshnessBoundariesPreserveDaemonCounter() throws {
        let own = ServiceResourceCounter(pid: 100, startTime: 10, name: "lidkeep-daemon",
                                         residentBytes: 1_000, cpuTicks: 100, sampledUptime: 100)
        let child = ServiceResourceCounter(pid: 101, startTime: 11, name: "lidkeep-watchdog",
                                           residentBytes: 2_000, cpuTicks: 200, sampledUptime: 100)
        func merge(at: Double, boot: String = "same", includeDiagnostic: Bool = true) -> [ServiceResourceCounter] {
            let guardian = GuardianState(boot: boot, monotonic: at, sleepDisabled: nil, error: nil,
                                         diagnostic: includeDiagnostic ? child : nil)
            return ServiceResourceReading.includingFreshGuardian(own: own, guardian: guardian, boot: "same", now: 100)
        }
        for time in [100.0, 85.0] {
            let result = merge(at: time)
            XCTAssertEqual(result.map(\.pid), [100, 101])
            XCTAssertEqual(result[0].residentBytes, own.residentBytes)
            XCTAssertEqual(result[0].cpuTicks, own.cpuTicks)
            XCTAssertEqual(result[1].name, "lidkeep-watchdog")
        }
        for result in [merge(at: 84.999), merge(at: 100.001), merge(at: 100, boot: "previous"),
                       merge(at: 100, includeDiagnostic: false), merge(at: .nan), merge(at: .infinity)] {
            XCTAssertEqual(result.map(\.pid), [100])
            XCTAssertEqual(result.first?.residentBytes, own.residentBytes)
        }
        let old = try JSONDecoder().decode(GuardianState.self, from: Data("{\"boot\":\"same\",\"monotonic\":100}".utf8))
        XCTAssertEqual(ServiceResourceReading.includingFreshGuardian(own: own, guardian: old, boot: "same", now: 100).map(\.pid), [100])
        XCTAssertEqual(ServiceResourceReading.includingFreshGuardian(own: own, guardian: nil, boot: "same", now: 100).map(\.pid), [100])
    }

    func testFreshGuardianDiagnosticSurvivesUnavailableDaemonSample() {
        let child = ServiceResourceCounter(pid: 101, startTime: 11, name: "lidkeep-watchdog",
                                           residentBytes: 2_000, cpuTicks: 200, sampledUptime: 100)
        let guardian = GuardianState(boot: "same", monotonic: 100, sleepDisabled: nil, error: nil, diagnostic: child)
        XCTAssertEqual(ServiceResourceReading.includingFreshGuardian(own: nil, guardian: guardian, boot: "same", now: 100).map(\.pid), [101])
        XCTAssertTrue(ServiceResourceReading.includingFreshGuardian(own: nil, guardian: guardian, boot: "other", now: 100).isEmpty)
    }

    func testGuardianClockIsReadAfterNewHeartbeatForRuntimeAndDiagnostics() {
        let oldEnvironmentTime = 100.0
        var clock = oldEnvironmentTime
        var calls: [String] = []
        let counter = ServiceResourceCounter(pid: 101, startTime: 11, name: "lidkeep-watchdog",
                                              residentBytes: 2_000, cpuTicks: 200, sampledUptime: 100.1)
        let observation = ServiceResourceReading.readGuardian(read: {
            calls.append("read"); clock = 100.1
            return GuardianState(boot: "same", monotonic: clock, sleepDisabled: true, error: nil, diagnostic: counter)
        }, clock: { calls.append("clock"); return clock })
        XCTAssertEqual(calls, ["read", "clock"])
        XCTAssertFalse(ServiceResourceReading.guardianReady(observation.guardian, boot: "same", now: oldEnvironmentTime))
        XCTAssertTrue(ServiceResourceReading.guardianReady(observation.guardian, boot: "same", now: observation.checkedAt))
        XCTAssertEqual(ServiceResourceReading.includingFreshGuardian(own: nil, guardian: observation.guardian,
                                                                     boot: "same", now: observation.checkedAt).map(\.pid), [101])
    }

    func testGuardianRuntimeRejectsRealFutureExpiredWrongBootErrorsAndMissing() {
        func ready(at: Double, boot: String = "same", error: String? = nil) -> Bool {
            let guardian = GuardianState(boot: boot, monotonic: at, sleepDisabled: nil, error: error)
            return ServiceResourceReading.guardianReady(guardian, boot: "same", now: 100)
        }
        XCTAssertTrue(ready(at: 100)); XCTAssertTrue(ready(at: 70))
        XCTAssertFalse(ready(at: 69.999)); XCTAssertFalse(ready(at: 100.001))
        XCTAssertFalse(ready(at: 100, boot: "other")); XCTAssertFalse(ready(at: 100, error: "fault"))
        XCTAssertFalse(ready(at: .nan)); XCTAssertFalse(ready(at: .infinity))
        XCTAssertFalse(ServiceResourceReading.guardianReady(nil, boot: "same", now: 100))
    }

    var directory: String!
    var store: SecureStore!
    var runner: FakePMSet!
    var power: PowerController!
    override func setUpWithError() throws {
        directory = NSTemporaryDirectory() + "lidkeep-runtime-tests-" + UUID().uuidString
        store = try SecureStore(directory: directory, requireRoot: false, testBoot: "test-boot")
        runner = FakePMSet(); power = PowerController(store: store, runner: runner)
    }
    override func tearDownWithError() throws {
        power = nil; store = nil
        try FileManager.default.removeItem(atPath: directory)
    }
    func own() throws { try store.write(Ownership(boot: store.boot, baseline: 0, createdAt: Date()), to: "ownership.json") }
    func environment(now: Double = 100, battery: Double? = 90, thermal: ThermalLevel = .nominal) -> Environment {
        Environment(now: now, batteryPercent: battery, onAC: false, thermal: thermal,
                    lidClosed: false, externalDisplayCount: 0, networkConnected: true)
    }
    func desired(now: Double = 100, gui: Double? = 100, deadline: Double? = nil) -> DesiredState {
        DesiredState(boot: store.boot, session: "test-session", monotonic: now,
                     guiHeartbeat: gui, guiUID: 501, wantsAwake: true, mode: .active,
                     stopPercent: 10, testDeadline: deadline, acknowledgedSafety: nil, sleepToken: nil)
    }
    func watchdog(_ environment: Environment) -> Watchdog {
        Watchdog(store: store, power: power, sample: { environment }, consoleUser: { 501 })
    }
    func testParserRequiresUniqueExactSleepDisabled() throws {
        XCTAssertTrue(try PowerController.parseSleepDisabled("  SleepDisabled 1\n sleep 1"))
        XCTAssertFalse(try PowerController.parseSleepDisabled("SleepDisabled 0"))
        for text in ["", "sleepdisabled 1", "SleepDisabled 7", "SleepDisabled 1\nSleepDisabled 0", "SleepDisabled 1 extra", "SleepDisabled 0\nSleepDisabled 1 garbage"] {
            XCTAssertThrowsError(try PowerController.parseSleepDisabled(text))
        }
    }
    func testZeroExitWithErrorOutputRejected() {
        for output in ["Sleep error 0x0001", "Unable to sleep system: error 0x01", "You must run this as root."] {
            XCTAssertThrowsError(try PowerController.checkCommand(CommandResult(status: 0, output: output)))
        }
    }
    func testFalseEnableSuccessLeavesOwnershipForRecovery() throws {
        runner.falseSuccess = true
        XCTAssertThrowsError(try store.withLock { try power.enableLocked() })
        XCTAssertNotNil(try store.read("ownership.json", as: Ownership.self))
    }
    func testOwnershipDurableBeforeCommandEvenIfCommandFails() throws {
        runner.beforeEnable = { XCTAssertNotNil(try self.store.read("ownership.json", as: Ownership.self)) }
        runner.refuseEnable = true
        XCTAssertThrowsError(try store.withLock { try power.enableLocked() })
        XCTAssertNotNil(try store.read("ownership.json", as: Ownership.self))
        try power.restore()
        XCTAssertNil(try store.read("ownership.json", as: Ownership.self))
    }
    func testForeignDisabledSettingIsNeverChanged() throws {
        runner.disabled = true
        XCTAssertThrowsError(try store.withLock { try power.enableLocked() })
        try power.restore()
        XCTAssertTrue(runner.disabled)
        XCTAssertFalse(runner.operations.contains(["-a", "disablesleep", "0"]))
        XCTAssertFalse(runner.operations.contains(["-a", "disablesleep", "1"]))
        XCTAssertNil(try store.read("ownership.json", as: Ownership.self))
    }
    func testRestoreFailureRetainsJournalAndPreventsSleep() throws {
        try own(); runner.disabled = true; runner.refuseRestore = true
        XCTAssertThrowsError(try store.withLock { try power.sleepLocked(token: "episode") })
        XCTAssertNotNil(try store.read("ownership.json", as: Ownership.self))
        XCTAssertFalse(runner.operations.contains(["sleepnow"]))
        XCTAssertNil(try store.read("sleep-receipt.json", as: SleepReceipts.self))
    }
    func testRestoreFalseSuccessRetainsJournal() throws {
        try own(); runner.disabled = true; runner.falseSuccess = true
        XCTAssertThrowsError(try power.restore())
        XCTAssertNotNil(try store.read("ownership.json", as: Ownership.self))
    }
    func testSleepReceiptPreventsRepeatAfterManualWake() throws {
        try own(); runner.disabled = true
        try store.withLock { try power.sleepLocked(token: "episode") }
        try store.withLock { try power.sleepLocked(token: "episode") }
        XCTAssertEqual(runner.operations.filter { $0 == ["sleepnow"] }.count, 1)
        XCTAssertFalse(runner.disabled)
        XCTAssertNil(try store.read("ownership.json", as: Ownership.self))
    }
    func testFailedSleepCommandStillDoesNotRetryEpisode() throws {
        runner.errorTextWithZero = true
        XCTAssertThrowsError(try store.withLock { try power.sleepLocked(token: "episode") })
        runner.errorTextWithZero = false
        try store.withLock { try power.sleepLocked(token: "episode") }
        XCTAssertEqual(runner.operations.filter { $0 == ["sleepnow"] }.count, 1)
    }
    func testPreflightCancelsEnableAfterJournalBeforeCommand() throws {
        XCTAssertThrowsError(try store.withLock {
            try power.enableLocked { throw ServiceError("new protection latch") }
        })
        XCTAssertFalse(runner.operations.contains(["-a", "disablesleep", "1"]))
        try power.restore()
        XCTAssertNil(try store.read("ownership.json", as: Ownership.self))
    }
    func testSymlinkedStateAndUnsafePermissionsRejected() throws {
        let target = directory + "/unsafe.json"
        try Data("{}".utf8).write(to: URL(fileURLWithPath: target))
        XCTAssertEqual(chmod(target, 0o644), 0)
        XCTAssertThrowsError(try store.data("unsafe.json"))
        XCTAssertEqual(symlink(target, directory + "/link.json"), 0)
        XCTAssertThrowsError(try store.write(Data("safe".utf8), to: "link.json"))
        XCTAssertThrowsError(try store.data("link.json"))
        XCTAssertThrowsError(try store.data("../elsewhere"))
    }
    func testAtomicReplacementPreservesAlreadyOpenedSnapshot() throws {
        let old = Data("{\"generation\":1}".utf8)
        let new = Data("{\"generation\":2}".utf8)
        try store.write(old, to: "guardian.json")
        let file = open(directory + "/guardian.json", O_RDONLY | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(file, 0)
        defer { close(file) }

        // Reproduce the real ordering: reader opens, writer replaces, reader validates.
        try store.write(new, to: "guardian.json")
        var metadata = stat()
        XCTAssertEqual(fstat(file, &metadata), 0)
        XCTAssertEqual(metadata.st_nlink, 0)
        XCTAssertEqual(try store.readSnapshot(file, name: "guardian.json"), old)
        XCTAssertEqual(try store.data("guardian.json"), new)
        XCTAssertTrue(try store.exists("guardian.json"))
    }
    func testUnlinkedSnapshotStillRejectsUnsafePermissionsAndExcessSize() throws {
        try store.write(Data("snapshot".utf8), to: "guardian.json")
        let file = open(directory + "/guardian.json", O_RDONLY | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(file, 0)
        defer { close(file) }
        try store.remove("guardian.json")
        XCTAssertNil(try store.data("guardian.json"))
        XCTAssertThrowsError(try store.readSnapshot(file, name: "guardian.json", limit: 1))
        XCTAssertEqual(fchmod(file, 0o644), 0)
        XCTAssertThrowsError(try store.readSnapshot(file, name: "guardian.json"))
    }
    func testHardLinkedStateAndLocksRemainRejected() throws {
        for name in ["guardian.json", "power.lock", "safety.lock"] {
            try store.write(Data(), to: name)
            XCTAssertEqual(link(directory + "/" + name, directory + "/" + name + ".alias"), 0)
            XCTAssertThrowsError(try store.exists(name))
            XCTAssertThrowsError(try store.data(name))
            XCTAssertThrowsError(try store.write(Data(), to: name))
        }
        XCTAssertThrowsError(try store.withLock {})
        XCTAssertThrowsError(try store.latch("unsafe lock"))
    }
    func testNonRegularStateReadDoesNotBlock() throws {
        XCTAssertEqual(mkfifo(directory + "/pipe", 0o600), 0)
        XCTAssertThrowsError(try store.data("pipe"))
        XCTAssertEqual(mkdir(directory + "/nested", 0o700), 0)
        XCTAssertThrowsError(try store.data("nested"))
        XCTAssertNil(try store.data("missing.json"))
    }
    func testPowerLockTimesOutInsteadOfWaitingForever() throws {
        let fd = open(directory + "/power.lock", O_RDWR | O_CREAT, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX), 0)
        let start = Monotonic.now
        XCTAssertThrowsError(try store.withLock(timeout: 0.06) {})
        XCTAssertLessThan(Monotonic.now - start, 0.5)
    }
    func testSafetyCompareAndRemovePreservesConcurrentUpgrade() throws {
        let original = try store.latch("test")
        let updated = try store.latch("overheat", sleep: true)
        XCTAssertEqual(original.id, updated.id, "One protection episode deduplicates sleep")
        XCTAssertNotEqual(original.acknowledgment, updated.acknowledgment)
        XCTAssertFalse(try store.removeLatch(ifMatching: original))
        XCTAssertEqual(try store.read("safety.json", as: SafetyLatch.self), updated)
        XCTAssertTrue(try store.removeLatch(ifMatching: updated))
    }
    func testGuardianRevokesExpiredPrimaryAndGUILesse() throws {
        for value in [desired(now: 69), desired(gui: 69)] {
            runner.disabled = true; try own()
            try store.write(value, to: "desired.json")
            try store.withLock { try watchdog(environment()).reconcileLocked() }
            XCTAssertFalse(runner.disabled)
            XCTAssertNotNil(try store.read("safety.json", as: SafetyLatch.self))
        }
    }
    func testGuardianRejectsOtherBootAndUserAndFutureLease() throws {
        var values = [desired(), desired(), desired()]
        values[0].boot = "other-boot"; values[1].guiUID = 502; values[2].monotonic = 101
        for value in values {
            try store.write(value, to: "desired.json")
            try store.withLock { try watchdog(environment()).reconcileLocked() }
            XCTAssertFalse(runner.disabled)
        }
    }
    func testGuardianLowBatterySleepsOnceAndInvalidBatteryOnlyRestores() throws {
        try store.write(desired(), to: "desired.json"); try own(); runner.disabled = true
        let monitor = watchdog(environment(battery: 9))
        try store.withLock { try monitor.reconcileLocked() }
        try store.withLock { try monitor.reconcileLocked() }
        XCTAssertFalse(runner.disabled)
        XCTAssertEqual(runner.operations.filter { $0 == ["sleepnow"] }.count, 1)
        try own(); runner.disabled = true
        try store.withLock { try watchdog(environment(battery: nil)).reconcileLocked() }
        XCTAssertFalse(runner.disabled)
        XCTAssertEqual(runner.operations.filter { $0 == ["sleepnow"] }.count, 1)
    }
    func testGuardianTemperatureProtectionIndependentOfExpiredDaemon() throws {
        try store.write(desired(now: 50, gui: 50), to: "desired.json"); try own(); runner.disabled = true
        try store.withLock { try watchdog(environment(thermal: .serious)).reconcileLocked() }
        XCTAssertEqual(runner.operations.filter { $0 == ["sleepnow"] }.count, 1)
        XCTAssertFalse(runner.disabled)
    }
    func testGuardianNewLatchCannotBeClearedByOldAcknowledgment() throws {
        let prior = try store.latch("old")
        var intent = desired(); intent.acknowledgedSafety = prior.acknowledgment
        try store.write(intent, to: "desired.json")
        let updated = try store.latch("new protection", sleep: true)
        try store.withLock { try watchdog(environment()).reconcileLocked() }
        XCTAssertFalse(runner.disabled)
        XCTAssertEqual(try store.read("safety.json", as: SafetyLatch.self), updated)
    }
    func testGuardianMaintenanceMarkerBlocksEnabling() throws {
        try store.write(desired(), to: "desired.json")
        try store.write(Data(), to: "maintenance")
        try store.withLock { try watchdog(environment()).reconcileLocked() }
        XCTAssertFalse(runner.operations.contains(["-a", "disablesleep", "1"]))
    }
    func testGuardianDeadlineRollbackPreservesCompletedProof() throws {
        var engine = PolicyEngine()
        _ = try engine.handle(Request(.beginTest), environment: environment(now: 100))
        for tick in stride(from: 105.0, through: 275, by: 5) {
            var input = environment(now: tick); input.lidClosed = tick <= 170
            _ = engine.evaluate(input)
        }
        var intent = desired(now: 275, gui: 275, deadline: engine.testDeadline)
        intent.mode = .testing
        try store.write(intent, to: "desired.json"); try own(); runner.disabled = true
        let final = environment(now: 280)
        try store.withLock { try watchdog(final).reconcileLocked() }
        XCTAssertFalse(runner.disabled)
        XCTAssertNil(try store.read("safety.json", as: SafetyLatch.self))
        XCTAssertEqual(engine.evaluate(final).mode, .awaitingConfirmation)
    }
    func testGuardianEnablesOnlyAfterAcknowledgedRecovery() throws {
        let latch = try store.latch("recovery")
        var intent = desired(); intent.acknowledgedSafety = latch.acknowledgment
        try store.write(intent, to: "desired.json")
        try store.withLock { try watchdog(environment()).reconcileLocked() }
        XCTAssertTrue(runner.disabled)
        XCTAssertNil(try store.read("safety.json", as: SafetyLatch.self))
    }
    func testGuardianCompletesSleepIntentAfterOwnershipWasAlreadyRestored() throws {
        try store.write(desired(), to: "desired.json")
        try own(); runner.disabled = true
        let latch = try store.latch("low battery", sleep: true)
        try power.restore() // Simulate a crash between rollback and sleep dispatch.
        XCTAssertNil(try store.read("ownership.json", as: Ownership.self))
        XCTAssertEqual(try store.pendingSleepRequest(), latch.requestToken)
        let monitor = watchdog(environment(battery: 9))
        try store.withLock { try monitor.reconcileLocked() }
        try store.withLock { try monitor.reconcileLocked() } // Manual wake, same episode.
        XCTAssertEqual(runner.operations.filter { $0 == ["sleepnow"] }.count, 1)
        XCTAssertNil(try store.pendingSleepRequest())
    }
    func testPendingSleepIntentSurvivesExpiredDaemonAndMissingBattery() throws {
        try store.write(desired(now: 50, gui: 50), to: "desired.json")
        let latch = try store.latch("already authorized protection", sleep: true)
        let monitor = watchdog(environment(battery: nil))
        try store.withLock { try monitor.reconcileLocked() }
        XCTAssertEqual(runner.operations.filter { $0 == ["sleepnow"] }.count, 1)
        XCTAssertEqual(try store.read("sleep-receipt.json", as: SleepReceipts.self)?.tokens, [latch.requestToken!])
    }
    func testManualIntentAndDesiredUseSameTokenWithoutDuplicateSleep() throws {
        let first = try store.latch("manual", sleep: true, token: "manual-first")
        var intent = desired(); intent.wantsAwake = false; intent.sleepToken = first.requestToken
        try store.write(intent, to: "desired.json")
        let monitor = watchdog(environment())
        try store.withLock { try monitor.reconcileLocked() }
        try store.withLock { try monitor.reconcileLocked() }
        XCTAssertEqual(runner.operations.filter { $0 == ["sleepnow"] }.count, 1)
        let second = try store.latch("manual", sleep: true, token: "manual-second")
        XCTAssertEqual(first.id, second.id)
        XCTAssertNotEqual(first.acknowledgment, second.acknowledgment)
        intent.sleepToken = second.requestToken
        try store.write(intent, to: "desired.json")
        try store.withLock { try monitor.reconcileLocked() }
        try store.withLock { try monitor.reconcileLocked() }
        XCTAssertEqual(runner.operations.filter { $0 == ["sleepnow"] }.count, 2)
    }
    func testPendingSleepSuppressedDuringMaintenance() throws {
        _ = try store.latch("pending", sleep: true)
        try store.write(Data(), to: "maintenance")
        try store.withLock { try watchdog(environment()).reconcileLocked() }
        XCTAssertFalse(runner.operations.contains(["sleepnow"]))
        XCTAssertNotNil(try store.pendingSleepRequest())
    }
    func testOldBootSleepIntentCannotSleepNewBoot() throws {
        var latch = try store.latch("old", sleep: true)
        latch.boot = "previous-boot"
        try store.write(latch, to: "safety.json")
        XCTAssertNil(try store.pendingSleepRequest())
        let replacement = try store.latch("new boot startup")
        XCTAssertNotEqual(latch.id, replacement.id)
        XCTAssertNil(replacement.requestToken)
    }

}
