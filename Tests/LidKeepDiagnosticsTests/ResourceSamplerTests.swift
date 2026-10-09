import XCTest
import Darwin
import LidKeepCore
@testable import LidKeepDiagnostics

final class ResourceSamplerTests: XCTestCase {
    func counter(pid: Int32 = 42, start: UInt64 = 10, memory: UInt64 = 100, ticks: UInt64 = 100,
                 at: Double = 10) -> ProcessCounter {
        ProcessCounter(pid: pid, startTime: start, name: "test", residentBytes: memory, cpuTicks: ticks, sampledAt: at)
    }

    func testFirstSampleAndReusedPIDHaveNoInventedRates() {
        XCTAssertNil(counter().sample(previous: nil, secondsPerTick: 1).cpuPercent)
        let reused = counter(start: 11, memory: 9, ticks: 1, at: 20).sample(previous: counter(), secondsPerTick: 1)
        XCTAssertNil(reused.cpuPercent)
        XCTAssertNil(reused.memoryDeltaBytes)
    }

    func testCPUUsesMachTimebaseAndOneHundredPercentPerCore() {
        // Apple silicon commonly uses a 24 MHz clock: 96 million ticks = four CPU seconds.
        let result = counter(memory: 150, ticks: 96_000_100, at: 12).sample(previous: counter(), secondsPerTick: 1 / 24_000_000)
        XCTAssertEqual(result.cpuPercent ?? -1, 200, accuracy: 0.0001)
        XCTAssertEqual(result.memoryDeltaBytes, 50)
    }

    func testCounterRegressionAndBadElapsedTimeAreUnknown() {
        XCTAssertNil(counter(ticks: 1, at: 20).sample(previous: counter(), secondsPerTick: 1).cpuPercent)
        XCTAssertNil(counter(ticks: 200).sample(previous: counter(), secondsPerTick: 1).cpuPercent)
        XCTAssertNil(counter(ticks: 200, at: 20).sample(previous: counter(), secondsPerTick: .nan).cpuPercent)
        XCTAssertEqual(counter(memory: 20, at: 20).sample(previous: counter(), secondsPerTick: 1).memoryDeltaBytes, -80)
    }

    func testPressureMapsPublicDispatchFlagsAndRejectsUnknown() {
        XCTAssertEqual(ResourceSampler.pressureLabel(1), "normal")
        XCTAssertEqual(ResourceSampler.pressureLabel(2), "warning")
        XCTAssertEqual(ResourceSampler.pressureLabel(4), "critical")
        let unknown: [UInt32?] = [nil, 0, 3, 999]
        for value in unknown { XCTAssertEqual(ResourceSampler.pressureLabel(value), "unknown") }
    }

    func testNamesAreBoundedBasenamesWithoutControlCharacters() {
        XCTAssertEqual(ResourceSampler.name(from: Array("/private/example/Claude\n\t\0secret".utf8)), "Claude")
        XCTAssertEqual(ResourceSampler.name(from: [0, 65]), "")
        XCTAssertLessThanOrEqual(ResourceSampler.name(from: Array(String(repeating: "a", count: 100).utf8)).count, 64)
    }

    func testSystemCPUUsesPerCoreScaleAndHandlesTickWrap() {
        XCTAssertNil(ResourceSampler.systemCPUPercent(current: [1, 2, 3, 4], previous: nil, logicalCPUs: 12))
        XCTAssertEqual(ResourceSampler.systemCPUPercent(current: [50, 0, 50, 0], previous: [0, 0, 0, 0], logicalCPUs: 12) ?? -1, 600)
        XCTAssertEqual(ResourceSampler.systemCPUPercent(current: [9, 0, 9, 0], previous: [.max, 0, .max, 0], logicalCPUs: 2) ?? -1, 100)
    }

    func testSelectionKeepsIndependentLeadersAndLidKeepWithoutDuplicates() {
        var processes: [ProcessSample] = []
        for n in 1...100 {
            let name = n == 99 ? "local.rl.lidkeep.service" : "p\(n)"
            let growth: Int64 = n > 40 && n < 49 ? 999 : 0
            processes.append(ProcessSample(pid: Int32(n), startTime: 1, name: name,
                                           residentBytes: UInt64(n), cpuPercent: Double(100 - n), memoryDeltaBytes: growth))
        }
        let result = ResourceSampler.selectProcesses(processes, ownPID: 60)
        let pids = Set(result.map(\.pid))
        XCTAssertTrue(pids.contains(100)); XCTAssertTrue(pids.contains(1)); XCTAssertTrue(pids.contains(44))
        XCTAssertTrue(pids.contains(99)); XCTAssertTrue(pids.contains(60))
        XCTAssertEqual(pids.count, result.count)
        XCTAssertLessThanOrEqual(result.count, 40)
    }

    func testReadOnlyLocalSamplingSmokeAndReset() throws {
        let sampler = ResourceSampler()
        let context = DiagnosticContext(lidClosed: nil, thermal: .unknown, batteryPercent: nil,
                                        onAC: nil, sleepDisabled: nil, mode: nil, reason: nil, statusFresh: false)
        let first = try sampler.sample(context: context)
        XCTAssertGreaterThan(first.totalMemoryBytes, 0)
        XCTAssertGreaterThan(first.processCount, 0)
        XCTAssertLessThanOrEqual(first.processCount, 4096)
        XCTAssertLessThanOrEqual(first.processes.count, 40)
        XCTAssertNil(first.systemCPUPercent)
        XCTAssertTrue(first.processes.allSatisfy { $0.cpuPercent == nil && $0.memoryDeltaBytes == nil })
        XCTAssertTrue(first.processes.contains { $0.pid == getpid() })
        XCTAssertNoThrow(try JSONDecoder().decode(ResourceSnapshot.self, from: JSONEncoder().encode(first)))
        sampler.reset()
        let reset = try sampler.sample(context: context)
        XCTAssertNil(reset.systemCPUPercent)
        XCTAssertTrue(reset.processes.allSatisfy { $0.cpuPercent == nil })
    }

    func testServiceCountersRejectStaleInvalidAndReusedPID() {
        func report(pid: Int32 = 42, start: UInt64 = 10, at: Double = 90, name: String = "lidkeep-daemon", ticks: UInt64 = 100) -> ServiceResourceCounter {
            ServiceResourceCounter(pid: pid, startTime: start, name: name, residentBytes: 200, cpuTicks: ticks, sampledUptime: at)
        }
        func merge(_ reports: [ServiceResourceCounter], native: [Int32: ProcessCounter] = [:]) -> [Int32: ProcessCounter] {
            ResourceSampler.mergeServiceCounters(reports, into: native, now: 100, secondsPerTick: 0.001, logicalCPUs: 12)
        }
        XCTAssertEqual(merge([report()])[42]?.residentBytes, 200)
        for invalid in [report(at: 84.99), report(at: 101), report(at: .nan), report(pid: 0), report(start: 0),
                        report(name: "unrelated"), report(ticks: .max)] {
            XCTAssertTrue(merge([invalid]).isEmpty)
        }
        XCTAssertEqual(merge([report(start: 11)], native: [42: counter(start: 12)])[42]?.startTime, 12)
        XCTAssertEqual(merge([report(), report(pid: 43)])[42]?.pid, 42)
        XCTAssertNil(merge([report(), report(pid: 43)])[43])
        let full = Dictionary(uniqueKeysWithValues: (1...4096).map { (Int32($0), counter(pid: Int32($0))) })
        let bounded = merge([report(pid: 99_999)], native: full)
        XCTAssertEqual(bounded.count, 4096); XCTAssertNotNil(bounded[99_999])
        let reused = merge([report(start: 11)])[42]!.sample(previous: counter(start: 10), secondsPerTick: 0.001)
        XCTAssertNil(reused.cpuPercent); XCTAssertNil(reused.memoryDeltaBytes)
    }

    func testRepeatedServiceTimestampDoesNotInventZeroRatesAndOldContextDecodes() throws {
        let same = counter().sample(previous: counter(), secondsPerTick: 0.001)
        XCTAssertNil(same.cpuPercent); XCTAssertNil(same.memoryDeltaBytes)
        let old = Data("{\"thermal\":\"unknown\",\"statusFresh\":false}".utf8)
        XCTAssertNil(try JSONDecoder().decode(DiagnosticContext.self, from: old).serviceProcesses)
    }
}
