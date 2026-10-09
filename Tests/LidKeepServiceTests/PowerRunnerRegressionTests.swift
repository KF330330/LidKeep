import XCTest
import Foundation
import Darwin
@testable import LidKeepService

private final class RestoreSequenceRunner: CommandRunning {
    var operations: [[String]] = []
    var disabled = true
    var restored = false
    var failWrite = false
    var failReadback = false
    var ignoreWrite = false
    func run(_ arguments: [String]) throws -> CommandResult {
        operations.append(arguments)
        if arguments == ["-a", "disablesleep", "0"] {
            if failWrite { throw ServiceError("injected restore write failure") }
            restored = true
            if !ignoreWrite { disabled = false }
            return CommandResult(status: 0, output: "")
        }
        if arguments == ["-g"] {
            // Reads before the safety write model the reported failed preflight.
            guard restored, !failReadback else { throw ServiceError("injected read failure") }
            return CommandResult(status: 0, output: "SleepDisabled \(disabled ? 1 : 0)\n")
        }
        throw ServiceError("unexpected command")
    }
}

final class PowerRunnerRegressionTests: XCTestCase {
    private func descriptorCount() throws -> Int {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let estimate = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        guard estimate > 0 else { throw ServiceError("cannot size descriptor inventory") }
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(estimate) / stride + 64)
        let capacity = descriptors.count * stride
        let bytes = descriptors.withUnsafeMutableBytes {
            proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, $0.baseAddress!, Int32($0.count))
        }
        guard bytes > 0, bytes < capacity else { throw ServiceError("incomplete descriptor inventory") }
        return Int(bytes) / stride
    }

    func testReadOnlyPowerSamplingDoesNotAccumulateDescriptors() throws {
        // Deliberately keep one outer autorelease pool alive across all calls.
        // Only -g is executed; this test never changes system power settings.
        try autoreleasepool {
            let runner = PMSetRunner()
            for _ in 0..<3 { _ = try runner.run(["-g"]) }
            let baseline = try descriptorCount()
            for _ in 0..<96 {
                let result = try runner.run(["-g"])
                XCTAssertEqual(result.status, 0)
                _ = try PowerController.parseSleepDisabled(result.output)
            }
            XCTAssertLessThanOrEqual(try descriptorCount(), baseline + 4,
                                     "Repeated reads must release their pipe descriptors before returning")
        }
    }

    func testArbitraryArgumentsAreRejectedBeforeLaunching() {
        let runner = PMSetRunner()
        for arguments in [[], ["-g", "assertions"], ["-a", "disablesleep", "2"],
                          ["-a", "disablesleep", "0", "extra"], ["/bin/sh"], ["sleepnow", "extra"]] {
            XCTAssertThrowsError(try runner.run(arguments)) { error in
                XCTAssertEqual(error.localizedDescription, "不允许的电源命令。")
            }
        }
    }

    private func withStore(_ body: (SecureStore, RestoreSequenceRunner, PowerController) throws -> Void) throws {
        let directory = NSTemporaryDirectory() + "lidkeep-power-runner-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let store = try SecureStore(directory: directory, requireRoot: false, testBoot: "regression")
        let runner = RestoreSequenceRunner()
        try body(store, runner, PowerController(store: store, runner: runner))
    }

    func testOwnedRestoreWritesBeforeAnyReadAndClearsJournalOnlyAfterConfirmation() throws {
        try withStore { store, runner, power in
            try store.write(Ownership(boot: store.boot, baseline: 0, createdAt: Date()), to: "ownership.json")
            try power.restore()
            XCTAssertEqual(runner.operations, [["-a", "disablesleep", "0"], ["-g"]])
            XCTAssertFalse(runner.disabled)
            XCTAssertNil(try store.read("ownership.json", as: Ownership.self))
        }
    }

    func testRestoreWriteOrReadbackFailureRetainsOwnership() throws {
        for failure in 0..<3 {
            try withStore { store, runner, power in
                try store.write(Ownership(boot: store.boot, baseline: 0, createdAt: Date()), to: "ownership.json")
                runner.failWrite = failure == 0
                runner.failReadback = failure == 1
                runner.ignoreWrite = failure == 2
                XCTAssertThrowsError(try power.restore())
                XCTAssertEqual(runner.operations.first, ["-a", "disablesleep", "0"])
                XCTAssertNotNil(try store.read("ownership.json", as: Ownership.self))
                XCTAssertFalse(runner.operations.contains(["sleepnow"]))
            }
        }
    }

    func testRestoreWithoutOwnershipOrWithInvalidBaselineNeverWrites() throws {
        try withStore { store, runner, power in
            try power.restore()
            XCTAssertTrue(runner.operations.isEmpty)
            try store.write(Ownership(boot: store.boot, baseline: 1, createdAt: Date()), to: "ownership.json")
            XCTAssertThrowsError(try power.restore())
            XCTAssertTrue(runner.operations.isEmpty)
            XCTAssertTrue(runner.disabled)
        }
    }
}
