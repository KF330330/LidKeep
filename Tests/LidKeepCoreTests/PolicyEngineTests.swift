import XCTest
@testable import LidKeepCore

final class PolicyEngineTests: XCTestCase {
    private func env(_ time: Double = 0, battery: Double? = 80, ac: Bool = false,
                     thermal: ThermalLevel = .nominal, closed: Bool? = false,
                     displays: Int? = 0, network: Bool = true) -> Environment {
        Environment(now: time, batteryPercent: battery, onAC: ac, thermal: thermal,
                    lidClosed: closed, externalDisplayCount: displays, networkConnected: network)
    }

    private func activeEngine() -> PolicyEngine {
        var engine = PolicyEngine()
        engine.verified = true
        XCTAssertTrue(engine.evaluate(env()).keepAwake)
        return engine
    }

    func testDefaultPreferenceDoesNotBypassPhysicalVerification() throws {
        var engine = PolicyEngine()
        XCTAssertTrue(engine.preferences.enabled)
        XCTAssertFalse(engine.evaluate(env()).keepAwake)
        XCTAssertEqual(engine.mode, .awaitingValidation)
        XCTAssertFalse(try engine.handle(Request(.setEnabled, enabled: true), environment: env()).keepAwake)
        XCTAssertThrowsError(try engine.handle(Request(.confirmTest, testSucceeded: true), environment: env()))
    }

    func testStrictBelowTenBoundaryAndOneSleepPerEpisode() {
        var engine = activeEngine()
        XCTAssertTrue(engine.evaluate(env(1, battery: 11)).keepAwake)
        let atTen = engine.evaluate(env(2, battery: 10))
        XCTAssertTrue(atTen.keepAwake)
        XCTAssertFalse(atTen.requestSleep)
        let below = engine.evaluate(env(3, battery: 9))
        XCTAssertFalse(below.keepAwake)
        XCTAssertTrue(below.requestSleep)
        XCTAssertFalse(engine.evaluate(env(4, battery: 9)).requestSleep)
        engine.observedSleep()
        XCTAssertFalse(engine.evaluate(env(5, battery: 9)).requestSleep)
        XCTAssertFalse(engine.evaluate(env(6, battery: 10)).keepAwake)
    }

    func testLowBatteryAtStartupDoesNotForceRepeatedSleep() {
        var engine = PolicyEngine()
        engine.verified = true
        XCTAssertFalse(engine.evaluate(env(battery: 9)).requestSleep)
        XCTAssertFalse(engine.evaluate(env(5, battery: 9)).requestSleep)
    }

    func testChargingDoesNotExemptLowBatteryProtection() {
        var engine = activeEngine()
        XCTAssertTrue(engine.evaluate(env(1, battery: 9, ac: true)).requestSleep)
        XCTAssertFalse(engine.evaluate(env(2, battery: 10, ac: true)).keepAwake)
    }

    func testRecoveryRequiresTwentyAndSixtyContinuousNominalSeconds() {
        var engine = activeEngine()
        _ = engine.evaluate(env(1, battery: 9))
        engine.observedSleep()
        XCTAssertFalse(engine.evaluate(env(50, battery: 19)).keepAwake)
        XCTAssertFalse(engine.evaluate(env(100, battery: 20)).keepAwake)
        XCTAssertFalse(engine.evaluate(env(159, battery: 20)).keepAwake)
        XCTAssertTrue(engine.evaluate(env(160, battery: 20)).keepAwake)
        XCTAssertTrue(engine.evaluate(env(161, battery: 9)).requestSleep)
    }

    func testFairThermalStateResetsRecoveryTimer() {
        var engine = activeEngine()
        XCTAssertTrue(engine.evaluate(env(1, thermal: .serious)).requestSleep)
        XCTAssertFalse(engine.evaluate(env(2)).keepAwake)
        XCTAssertFalse(engine.evaluate(env(40, thermal: .fair)).keepAwake)
        XCTAssertFalse(engine.evaluate(env(41)).keepAwake)
        XCTAssertFalse(engine.evaluate(env(100)).keepAwake)
        XCTAssertTrue(engine.evaluate(env(101)).keepAwake)
    }

    func testCriticalThermalStateAndUnavailableBatteryStopKeepalive() {
        var engine = activeEngine()
        XCTAssertTrue(engine.evaluate(env(1, thermal: .critical)).requestSleep)
        for bad: Double? in [nil, -.infinity, .infinity, -1, 101, .nan] {
            var other = activeEngine()
            XCTAssertFalse(other.evaluate(env(1, battery: bad)).keepAwake)
            XCTAssertFalse(other.evaluate(env(2, battery: bad)).requestSleep)
        }
    }

    func testManualOffSurvivesRecoveryAndSerialization() throws {
        var engine = activeEngine()
        _ = engine.evaluate(env(1, battery: 9))
        _ = try engine.handle(Request(.setEnabled, enabled: false), environment: env(2))
        let data = try JSONEncoder().encode(engine)
        var restored = try JSONDecoder().decode(PolicyEngine.self, from: data)
        restored.restart()
        XCTAssertFalse(restored.evaluate(env(500, battery: 100)).keepAwake)
        XCTAssertFalse(restored.evaluate(env(1000, battery: 100)).keepAwake)
        XCTAssertFalse(restored.preferences.enabled)
        XCTAssertEqual(restored.mode, .disabled)
    }

    func testProtectionSurvivesRestartAndCannotReuseMonotonicRecoveryTime() throws {
        var engine = activeEngine()
        _ = engine.evaluate(env(1, battery: 9))
        _ = engine.evaluate(env(2))
        var restored = try JSONDecoder().decode(PolicyEngine.self, from: JSONEncoder().encode(engine))
        restored.restart()
        XCTAssertFalse(restored.evaluate(env(500)).keepAwake)
        XCTAssertFalse(restored.evaluate(env(559)).keepAwake)
        XCTAssertTrue(restored.evaluate(env(560)).keepAwake)
    }

    func testWatchdogInterruptionSuppressesDuplicateSleepFromDaemon() {
        var engine = activeEngine()
        _ = engine.interrupt(reason: "guardian already requested sleep")
        XCTAssertFalse(engine.evaluate(env(1, battery: 9)).requestSleep)
    }

    func testExplicitSleepWorksEvenWhenManualSwitchOff() throws {
        var engine = PolicyEngine()
        _ = try engine.handle(Request(.setEnabled, enabled: false), environment: env())
        let sleep = try engine.handle(Request(.sleepNow), environment: env())
        XCTAssertTrue(sleep.requestSleep)
        XCTAssertFalse(sleep.keepAwake)
        XCTAssertFalse(engine.evaluate(env(1)).requestSleep)
    }

    func testThresholdValidationIsAtomicAndImmediatelyAffectsProtection() throws {
        var engine = activeEngine()
        for pair in [(10.0, 10.0), (20, 10), (0, 20), (10, 101), (.nan, 20), (10, .infinity)] {
            XCTAssertThrowsError(try engine.handle(Request(.setThresholds, stopPercent: pair.0,
                                                         resumePercent: pair.1), environment: env()))
            XCTAssertEqual(engine.preferences.stopPercent, 10)
            XCTAssertEqual(engine.preferences.resumePercent, 20)
        }
        let decision = try engine.handle(Request(.setThresholds, stopPercent: 30, resumePercent: 40),
                                         environment: env(1, battery: 20))
        XCTAssertTrue(decision.requestSleep)
        XCTAssertEqual(engine.preferences.stopPercent, 30)
    }

    func testTrialPreflightRejectsWrongPhysicalEnvironment() {
        let badEnvironments = [env(ac: true), env(displays: 1), env(displays: nil),
                               env(closed: true), env(closed: nil), env(network: false),
                               env(battery: 19), env(thermal: .fair)]
        for environment in badEnvironments {
            var engine = PolicyEngine()
            XCTAssertThrowsError(try engine.handle(Request(.beginTest), environment: environment))
            XCTAssertFalse(engine.verified)
        }
    }

    private func completedTrial(closesLid: Bool = true) throws -> PolicyEngine {
        var engine = PolicyEngine()
        XCTAssertTrue(try engine.handle(Request(.beginTest), environment: env()).keepAwake)
        for step in stride(from: 5, through: 180, by: 5) {
            let decision = engine.evaluate(env(Double(step), closed: closesLid && step <= 100))
            XCTAssertEqual(decision.keepAwake, step < 180)
        }
        return engine
    }

    func testTrialAutomaticallyStopsAndRequiresExplicitTaskConfirmation() throws {
        var engine = try completedTrial()
        XCTAssertEqual(engine.mode, .awaitingConfirmation)
        XCTAssertFalse(engine.verified)
        XCTAssertFalse(engine.evaluate(env(185)).keepAwake)
        XCTAssertTrue(try engine.handle(Request(.confirmTest, testSucceeded: true), environment: env(190)).keepAwake)
        XCTAssertTrue(engine.verified)
    }

    func testFailedManualConfirmationCannotEnableDefaultAlwaysOn() throws {
        var engine = try completedTrial()
        XCTAssertFalse(try engine.handle(Request(.confirmTest, testSucceeded: false), environment: env(185)).keepAwake)
        XCTAssertFalse(engine.verified)
    }

    func testTrialWithoutActualLidClosureCannotBeApproved() throws {
        var engine = try completedTrial(closesLid: false)
        XCTAssertEqual(engine.mode, .awaitingValidation)
        XCTAssertThrowsError(try engine.handle(Request(.confirmTest, testSucceeded: true), environment: env(185)))
    }

    func testTrialCannotCountMultipleShortClosuresAsOneMinute() throws {
        var engine = PolicyEngine()
        _ = try engine.handle(Request(.beginTest), environment: env())
        for step in stride(from: 5, through: 180, by: 5) {
            _ = engine.evaluate(env(Double(step), closed: step % 50 != 0))
        }
        XCTAssertEqual(engine.mode, .awaitingValidation)
        XCTAssertFalse(engine.verified)
    }

    func testTrialFailsOnSleepGapPowerChangeAndNetworkLoss() throws {
        for interruption in [env(20, closed: true), env(5, ac: true), env(5, network: false),
                             env(5, displays: 1), env(5, closed: nil), env(-1)] {
            var engine = PolicyEngine()
            _ = try engine.handle(Request(.beginTest), environment: env())
            XCTAssertFalse(engine.evaluate(interruption).keepAwake)
            XCTAssertNotEqual(engine.mode, .awaitingConfirmation)
            XCTAssertThrowsError(try engine.handle(Request(.confirmTest, testSucceeded: true), environment: env(185)))
        }
        var sleeping = PolicyEngine()
        _ = try sleeping.handle(Request(.beginTest), environment: env())
        sleeping.observedSleep()
        XCTAssertFalse(sleeping.evaluate(env(5)).keepAwake)
        XCTAssertFalse(sleeping.verified)
    }

    func testRestartAndManualOffCancelTrial() throws {
        var engine = PolicyEngine()
        _ = try engine.handle(Request(.beginTest), environment: env())
        engine.restart()
        XCTAssertFalse(engine.evaluate(env(500)).keepAwake)
        _ = try engine.handle(Request(.beginTest), environment: env(600))
        XCTAssertFalse(try engine.handle(Request(.setEnabled, enabled: false), environment: env(605)).keepAwake)
        XCTAssertThrowsError(try engine.handle(Request(.confirmTest, testSucceeded: true), environment: env(800)))
    }

    func testUnconfirmedProofCannotSurviveRestartOrSystemUpgrade() throws {
        var engine = try completedTrial()
        engine.restart()
        XCTAssertThrowsError(try engine.handle(Request(.confirmTest, testSucceeded: true), environment: env(900)))
        XCTAssertFalse(engine.verified)
    }

    func testRequestAndResponseRoundTripWithoutUnsafeObjects() throws {
        let request = Request(.setThresholds, stopPercent: 15, resumePercent: 30)
        let decoded = try JSONDecoder().decode(Request.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded.command, .setThresholds)
        XCTAssertEqual(decoded.resumePercent, 30)
        let status = RuntimeStatus(preferences: Preferences(), mode: .awaitingValidation,
                                   reason: "等待验收", batteryPercent: 100, onAC: true,
                                   thermal: .nominal, sleepDisabled: false, verified: false)
        let reply = try JSONDecoder().decode(Response.self, from: JSONEncoder().encode(Response(status: status)))
        XCTAssertEqual(reply.status?.mode, .awaitingValidation)
        XCTAssertEqual(reply.status?.sleepDisabled, false)
    }
}
