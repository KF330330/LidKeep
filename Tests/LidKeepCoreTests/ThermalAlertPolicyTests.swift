import XCTest
@testable import LidKeepCore

final class ThermalAlertPolicyTests: XCTestCase {
    /// Observe every five seconds from `start` through `end` inclusive; returns the submission times.
    private func run(_ policy: inout ThermalAlertPolicy, _ observation: ThermalAlertPolicy.Observation,
                     from start: Double, through end: Double) -> [Double] {
        var submitted: [Double] = []
        var time = start
        while time <= end {
            if policy.observe(now: time, observation) != nil { submitted.append(time) }
            time += 5
        }
        return submitted
    }

    func testSustainedElevationSubmitsOnceAtFiveMinutes() throws {
        var policy = ThermalAlertPolicy()
        XCTAssertEqual(run(&policy, .elevated, from: 0, through: 295), [])
        XCTAssertNil(policy.observe(now: 299, .elevated))
        XCTAssertEqual(try XCTUnwrap(policy.observe(now: 300, .elevated)), 300, accuracy: 0.001)
        policy.delivered(at: 300)
        XCTAssertEqual(run(&policy, .elevated, from: 305, through: 7200), [])
    }

    func testUnknownReadingOrObservationGapDoesNotRepeatWithinEpisode() {
        var policy = ThermalAlertPolicy()
        XCTAssertEqual(run(&policy, .elevated, from: 0, through: 300), [300])
        policy.delivered(at: 300)
        XCTAssertNil(policy.observe(now: 305, .unknown))
        XCTAssertEqual(run(&policy, .elevated, from: 310, through: 7510), [])
        // A 31-second observation gap restarts only the timer, not the episode.
        XCTAssertEqual(run(&policy, .elevated, from: 7541, through: 14741), [])
    }

    func testUnknownBeforeAlertRestartsSustainTimer() {
        var policy = ThermalAlertPolicy()
        XCTAssertEqual(run(&policy, .elevated, from: 0, through: 295), [])
        XCTAssertNil(policy.observe(now: 299, .unknown))
        XCTAssertEqual(run(&policy, .elevated, from: 304, through: 900), [604])
    }

    func testNewEpisodeWaitsForThirtyMinuteInterval() {
        var policy = ThermalAlertPolicy()
        XCTAssertEqual(run(&policy, .elevated, from: 0, through: 300), [300])
        policy.delivered(at: 300)
        XCTAssertNil(policy.observe(now: 400, .cleared))
        XCTAssertEqual(run(&policy, .elevated, from: 500, through: 2095), [], "Still inside the 30-minute interval")
        XCTAssertNotNil(policy.observe(now: 2100, .elevated))
    }

    func testFailedSubmissionRetriesAfterFiveMinutes() {
        var policy = ThermalAlertPolicy()
        XCTAssertEqual(run(&policy, .elevated, from: 0, through: 300), [300])
        policy.failed(at: 300)
        XCTAssertEqual(run(&policy, .elevated, from: 305, through: 595), [])
        XCTAssertNotNil(policy.observe(now: 600, .elevated))
        policy.delivered(at: 600)
        XCTAssertEqual(run(&policy, .elevated, from: 605, through: 7200), [])
    }

    func testInFlightSubmissionIsNotRepeated() {
        var policy = ThermalAlertPolicy()
        XCTAssertEqual(run(&policy, .elevated, from: 0, through: 300), [300])
        XCTAssertEqual(run(&policy, .elevated, from: 305, through: 7200), [])
        policy.delivered(at: 7200)
        XCTAssertEqual(run(&policy, .elevated, from: 7205, through: 14400), [])
    }

    func testResetRestartsTimerAndKeepsInterval() {
        var policy = ThermalAlertPolicy()
        XCTAssertEqual(run(&policy, .elevated, from: 0, through: 200), [])
        policy.reset()
        XCTAssertEqual(run(&policy, .elevated, from: 205, through: 600), [505])
        policy.delivered(at: 505)
        policy.reset()
        XCTAssertEqual(run(&policy, .elevated, from: 510, through: 2300), [], "Reset keeps the 30-minute interval")
        XCTAssertNotNil(policy.observe(now: 2305, .elevated))
    }

    func testLateDeliveryFromClearedEpisodeDoesNotMarkNextEpisode() {
        var policy = ThermalAlertPolicy()
        XCTAssertEqual(run(&policy, .elevated, from: 0, through: 300), [300])
        XCTAssertNil(policy.observe(now: 305, .cleared))
        XCTAssertEqual(run(&policy, .elevated, from: 310, through: 400), [])
        policy.delivered(at: 400) // Callback for the first episode arrives during the second.
        XCTAssertEqual(run(&policy, .elevated, from: 405, through: 2195), [], "Interval counts from the accepted post")
        XCTAssertNotNil(policy.observe(now: 2200, .elevated))
        policy.delivered(at: 2200)
        XCTAssertEqual(run(&policy, .elevated, from: 2205, through: 7200), [])
    }

    func testLateDeliveryAfterResetDoesNotMarkNextEpisode() {
        var policy = ThermalAlertPolicy()
        XCTAssertEqual(run(&policy, .elevated, from: 0, through: 300), [300])
        policy.reset()
        XCTAssertEqual(run(&policy, .elevated, from: 305, through: 400), [])
        policy.delivered(at: 400)
        XCTAssertEqual(run(&policy, .elevated, from: 405, through: 2195), [])
        XCTAssertNotNil(policy.observe(now: 2200, .elevated))
    }

    func testClassifyOnlyClearsOnConfirmedFacts() {
        typealias Case = (lid: Bool?, fresh: Bool, awake: Bool, thermal: ThermalLevel,
                          expected: ThermalAlertPolicy.Observation)
        let cases: [Case] = [
            (false, true, true, .fair, .cleared),     // lid open
            (true, true, false, .fair, .cleared),     // fresh status, not keeping awake
            (true, true, true, .nominal, .cleared),   // fresh status, back to nominal
            (true, true, true, .fair, .elevated),
            (nil, true, true, .fair, .unknown),       // lid unreadable
            (true, false, true, .fair, .unknown),     // stale or missing status
            (true, true, true, .unknown, .unknown),
            (true, true, true, .serious, .unknown)    // transient serious before protection
        ]
        for item in cases {
            XCTAssertEqual(ThermalAlertPolicy.classify(lidClosed: item.lid, statusFresh: item.fresh,
                                                       keepingAwake: item.awake, thermal: item.thermal),
                           item.expected, "\(item)")
        }
    }
}
