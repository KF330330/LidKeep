import Foundation
import Darwin

enum BootSessionID {
    static func read() throws -> String {
        // kern.boottime is a wall-clock timestamp and can change after clock
        // corrections. The kernel's boot UUID survives helper restarts instead.
        var bytes = [UInt8](repeating: 0, count: 37)
        var size = bytes.count
        let result = bytes.withUnsafeMutableBytes {
            sysctlbyname("kern.bootsessionuuid", $0.baseAddress, &size, nil, 0)
        }
        guard result == 0, size == bytes.count else {
            throw ServiceError("无法读取本次开机 UUID，保持停止保活。")
        }
        return try decode(bytes)
    }

    static func decode(_ bytes: [UInt8]) throws -> String {
        guard bytes.count == 37, bytes.last == 0,
              let text = String(bytes: bytes.dropLast(), encoding: .utf8),
              let uuid = UUID(uuidString: text) else {
            throw ServiceError("本次开机 UUID 无效，保持停止保活。")
        }
        return uuid.uuidString
    }
}
