import Foundation
import Darwin
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import CoreGraphics
import Network
import SystemConfiguration
import LidKeepCore

final class SystemSampler {
    private let network = NWPathMonitor()
    private let networkLock = NSLock()
    private var connected = false
    private var powerSource: CFRunLoopSource?
    private var thermalObserver: NSObjectProtocol?
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var rootPort: io_connect_t = 0
    var changed: (() -> Void)?
    var sleepEvent: ((_ isWake: Bool, _ acknowledge: @escaping () -> Void) -> Void)?

    init() {
        network.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.networkLock.lock(); self.connected = path.status == .satisfied; self.networkLock.unlock()
            self.changed?()
        }
        network.start(queue: DispatchQueue(label: "local.rl.lidkeep.network"))
    }
    func subscribe() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<SystemSampler>.fromOpaque(context).takeUnretainedValue().changed?()
        }, context)?.takeRetainedValue() {
            powerSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        thermalObserver = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                                                  object: nil, queue: nil) { [weak self] _ in self?.changed?() }
        rootPort = IORegisterForSystemPower(context, &notifyPort, { context, _, message, argument in
            guard let context else { return }
            let sampler = Unmanaged<SystemSampler>.fromOpaque(context).takeUnretainedValue()
            // IOMessage.h: iokit_common_msg(0x270/0x280/0x300); these C macros are not imported into Swift.
            let token = Int(bitPattern: argument)
            if message == 0xe0000270 {
                IOAllowPowerChange(sampler.rootPort, token)
            } else if message == 0xe0000280 {
                let acknowledge = { IOAllowPowerChange(sampler.rootPort, token); return () }
                if let handler = sampler.sleepEvent { handler(false, acknowledge) } else { acknowledge() }
            } else if message == 0xe0000300 {
                sampler.sleepEvent?(true, {})
            }
        }, &notifier)
        if let notifyPort, let source = IONotificationPortGetRunLoopSource(notifyPort)?.takeUnretainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }
    func sample() -> Environment {
        let battery = batteryState()
        let thermal: ThermalLevel
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = .nominal
        case .fair: thermal = .fair
        case .serious: thermal = .serious
        case .critical: thermal = .critical
        @unknown default: thermal = .unknown
        }
        networkLock.lock(); let connected = self.connected; networkLock.unlock()
        return Environment(now: Monotonic.now, batteryPercent: battery.percent, onAC: battery.onAC,
                           thermal: thermal, lidClosed: lidClosed(), externalDisplayCount: externalDisplays(),
                           networkConnected: connected)
    }
    private func batteryState() -> (percent: Double?, onAC: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return (nil, false) }
        for source in list {
            guard let data = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  data[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  data[kIOPSIsPresentKey] as? Bool == true else { continue }
            let onAC = data[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            guard let current = data[kIOPSCurrentCapacityKey] as? NSNumber,
                  let maximum = data[kIOPSMaxCapacityKey] as? NSNumber,
                  maximum.doubleValue > 0, current.doubleValue >= 0, current.doubleValue <= maximum.doubleValue else { return (nil, onAC) }
            return (100 * current.doubleValue / maximum.doubleValue, onAC)
        }
        return (nil, false)
    }
    private func lidClosed() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
    }
    private func externalDisplays() -> Int? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count <= 32 else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return nil }
        return displays.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }.count
    }
    static var consoleUID: uid_t? {
        var uid: uid_t = 0; var gid: gid_t = 0
        guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) as String?, uid > 0,
              name != "loginwindow", name != "_mbsetupuser" else { return nil }
        return uid
    }
    static var fingerprint: String {
        func string(_ key: String) -> String {
            var size = 0
            guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
            var bytes = [CChar](repeating: 0, count: size)
            guard sysctlbyname(key, &bytes, &size, nil, 0) == 0 else { return "unknown" }
            return String(cString: bytes)
        }
        return "\(string("hw.model"))|\(string("kern.osversion"))"
    }
}
