import Foundation
import Darwin
import LidKeepCore

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 1, ["--daemon", "--watchdog", "--restore", "--diagnose"].contains(arguments[0]) else {
    fputs("Usage: lidkeep-service --daemon | --watchdog | --restore | --diagnose\n", stderr)
    exit(64)
}
do {
    if arguments[0] == "--diagnose" {
        let sampler = SystemSampler()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print("Read-only sensor check; this does not validate closed-lid operation.")
        print("Fingerprint: \(SystemSampler.fingerprint)")
        print("Boot session: \(try BootSessionID.read())")
        print(String(decoding: try encoder.encode(sampler.sample()), as: UTF8.self))
        let result = try PMSetRunner().run(["-g"])
        try PowerController.checkCommand(result)
        print("SleepDisabled: \(try PowerController.parseSleepDisabled(result.output))")
        exit(0)
    }
    let store = try SecureStore()
    switch arguments[0] {
    case "--restore":
        // --restore is maintenance-safe even after an uninstall removes identity.json.
        _ = try store.latch("安装维护恢复：已撤销本程序保活。")
        let power = PowerController(store: store)
        try power.restore()
        guard try !power.readActual() else { throw ServiceError("其他工具仍禁用系统休眠；未覆盖外部设置。") }
        print("LidKeep owned sleep setting restored; unrelated settings preserved.")
    case "--daemon":
        // Ownership recovery precedes identity and policy decoding, so corrupted
        // app metadata can never skip cleanup of a prior enable transaction.
        _ = try store.latch("主服务启动前恢复遗留设置。")
        try PowerController(store: store).restore()
        let service = try Daemon(store: store, manifest: SecureStore.identity())
        try service.start()
        withExtendedLifetime(service) { CFRunLoopRun() }
    default:
        _ = try store.latch("独立监护启动前恢复遗留设置。")
        try PowerController(store: store).restore()
        _ = try SecureStore.identity()
        let watchdog = Watchdog(store: store)
        try watchdog.start()
        withExtendedLifetime(watchdog) { CFRunLoopRun() }
    }
} catch {
    fputs("LidKeep: \(error.localizedDescription)\n", stderr)
    exit(1)
}
