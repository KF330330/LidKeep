import Foundation
import Darwin
import LidKeepCore

struct ResourceSamplingError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct ProcessCounter {
    var pid: Int32
    var startTime: UInt64
    var name: String
    var residentBytes: UInt64
    var cpuTicks: UInt64
    var sampledAt: Double

    func sample(previous: ProcessCounter?, secondsPerTick: Double) -> ProcessSample {
        var cpu: Double?
        var delta: Int64?
        if let previous, previous.pid == pid, previous.startTime == startTime {
            let elapsed = sampledAt - previous.sampledAt
            if elapsed > 0, elapsed.isFinite, secondsPerTick > 0, secondsPerTick.isFinite,
               cpuTicks >= previous.cpuTicks {
                let rate = Double(cpuTicks - previous.cpuTicks) * secondsPerTick / elapsed * 100
                if rate.isFinite { cpu = rate }
            }
            if elapsed > 0, elapsed.isFinite,
               residentBytes <= UInt64(Int64.max), previous.residentBytes <= UInt64(Int64.max) {
                delta = Int64(residentBytes) - Int64(previous.residentBytes)
            }
        }
        return ProcessSample(pid: pid, startTime: startTime, name: name, residentBytes: residentBytes,
                             cpuPercent: cpu, memoryDeltaBytes: delta)
    }
}

/// Call sample/reset only on one serial utility queue, separately from the power controller.
public final class ResourceSampler {
    private static let processLimit = 4096
    private var previous: [Int32: ProcessCounter] = [:]
    private var previousCPUTicks: [UInt32]?
    private let secondsPerTick: Double

    public init() {
        var info = mach_timebase_info_data_t()
        let result = mach_timebase_info(&info)
        secondsPerTick = result == KERN_SUCCESS && info.denom > 0
            ? Double(info.numer) / Double(info.denom) / 1_000_000_000 : .nan
    }

    public func reset() {
        previous.removeAll(keepingCapacity: false)
        previousCPUTicks = nil
    }

    public func sample(context: DiagnosticContext) throws -> ResourceSnapshot {
        let started = ProcessInfo.processInfo.systemUptime
        let timestamp = Date()
        var warnings: [String] = []
        guard let total: UInt64 = Self.sysctlValue("hw.memsize", initial: UInt64(0)), total > 0 else {
            throw ResourceSamplingError(message: "无法读取物理内存总量；本次资源检查失败。")
        }
        let memory = Self.memoryPages()
        if memory == nil { warnings.append("无法读取空闲页与压缩内存，相关指标未知。") }
        let swap = Self.sysctlValue("vm.swapusage", initial: xsw_usage())?.xsu_used
        if swap == nil { warnings.append("无法读取交换内存，相关指标未知。") }
        let pressure = Self.pressureLabel(Self.sysctlValue("kern.memorystatus_vm_pressure_level", initial: UInt32(0)))
        if pressure == "unknown" { warnings.append("无法识别系统内存压力等级。") }
        var loads = [Double](repeating: 0, count: 3)
        let loadCount = getloadavg(&loads, 3)
        let load = loadCount > 0 && loads[0].isFinite && loads[0] >= 0 ? loads[0] : nil
        if load == nil { warnings.append("无法读取系统负载。") }

        let cpuTicks = Self.systemCPUTicks()
        let systemCPU = cpuTicks.flatMap { Self.systemCPUPercent(current: $0, previous: previousCPUTicks,
                                                                 logicalCPUs: ProcessInfo.processInfo.activeProcessorCount) }
        previousCPUTicks = cpuTicks
        if cpuTicks == nil { warnings.append("无法读取系统 CPU 计数，CPU 占用未知。") }
        if !secondsPerTick.isFinite { warnings.append("无法读取 Mach 时钟单位，进程 CPU 占用未知。") }

        var pids = [Int32](repeating: 0, count: Self.processLimit)
        let capacity = pids.count * MemoryLayout<Int32>.stride
        let bytes = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count)) }
        guard bytes > 0, Int(bytes) <= capacity, Int(bytes) % MemoryLayout<Int32>.stride == 0 else {
            reset()
            throw ResourceSamplingError(message: "无法读取进程列表；本次资源检查失败。")
        }
        let ownPID = getpid()
        let listed = Array(Set(pids.prefix(Int(bytes) / MemoryLayout<Int32>.stride).filter { $0 > 0 })).sorted {
            if ($0 == ownPID) != ($1 == ownPID) { return $0 == ownPID }
            return $0 < $1
        }
        var truncated = Int(bytes) == capacity
        if truncated { warnings.append("进程列表达到 4096 项上限，榜单可能不完整。") }
        var counters: [Int32: ProcessCounter] = [:]
        counters.reserveCapacity(listed.count)
        var unreadable = 0
        var deadlineReached = false
        for pid in listed {
            // Avoid making a diagnostic task itself a sustained source of CPU work.
            if ProcessInfo.processInfo.systemUptime - started > 2 {
                deadlineReached = true
                break
            }
            guard let counter = Self.processCounter(pid: pid) else { unreadable += 1; continue }
            counters[pid] = counter
        }
        if deadlineReached {
            truncated = true
            warnings.append("资源采样达到 2 秒工作预算，剩余进程未扫描。")
        }
        if unreadable > 0 { warnings.append("\(unreadable) 个进程已退出或不允许读取，未按零内存计入。") }
        let services = Self.mergeServiceCounters(context.serviceProcesses, into: counters, now: started,
                                                 secondsPerTick: secondsPerTick,
                                                 logicalCPUs: ProcessInfo.processInfo.activeProcessorCount)
        counters = services
        let samples = counters.values.map { $0.sample(previous: previous[$0.pid], secondsPerTick: secondsPerTick) }
        previous = counters
        if samples.isEmpty { warnings.append("未获得可读进程；进程资源占用未知。") }
        let selected = Self.selectProcesses(samples, ownPID: getpid())
        if samples.filter({ Self.isLidKeep($0, ownPID: getpid()) }).count > 16 {
            warnings.append("LidKeep 同名进程超过 16 个，附加列表已截断。")
        }
        return ResourceSnapshot(timestamp: timestamp, uptime: started, context: context, totalMemoryBytes: total,
                                freeMemoryBytes: memory?.free, compressedBytes: memory?.compressed, swapUsedBytes: swap,
                                memoryPressure: pressure, systemCPUPercent: systemCPU, loadAverage: load,
                                processCount: listed.count, unreadableProcessCount: unreadable, processListTruncated: truncated,
                                processes: selected, collectionSeconds: ProcessInfo.processInfo.systemUptime - started,
                                warnings: warnings)
    }

    private static func sysctlValue<T>(_ name: String, initial: T) -> T? {
        var value = initial
        var size = MemoryLayout<T>.size
        let result = withUnsafeMutablePointer(to: &value) { sysctlbyname(name, $0, &size, nil, 0) }
        return result == 0 && size == MemoryLayout<T>.size ? value : nil
    }

    static func pressureLabel(_ value: UInt32?) -> String {
        // This sysctl returns dispatch pressure flags, not the kernel's internal enum.
        switch value { case 1: return "normal"; case 2: return "warning"; case 4: return "critical"; default: return "unknown" }
    }

    static func mergeServiceCounters(_ reports: [ServiceResourceCounter]?, into native: [Int32: ProcessCounter],
                                     now: Double, secondsPerTick: Double, logicalCPUs: Int) -> [Int32: ProcessCounter] {
        var result = native
        var acceptedNames = Set<String>()
        var acceptedPIDs = Set<Int32>()
        guard now.isFinite, now >= 0, secondsPerTick.isFinite, secondsPerTick > 0, logicalCPUs > 0 else { return result }
        for report in (reports ?? []).prefix(2) {
            let age = now - report.sampledUptime
            guard ["lidkeep-daemon", "lidkeep-watchdog"].contains(report.name), report.pid > 0, report.startTime > 0,
                  report.sampledUptime.isFinite, report.sampledUptime >= 0, age >= 0, age <= 15,
                  report.residentBytes <= UInt64(Int64.max),
                  Double(report.cpuTicks) * secondsPerTick <= report.sampledUptime * Double(logicalCPUs) * 1.1 + 1,
                  !acceptedNames.contains(report.name), !acceptedPIDs.contains(report.pid) else { continue }
            // A native observation of another process with the same PID defeats an older self-report.
            if let current = native[report.pid], current.startTime != report.startTime || current.sampledAt >= report.sampledUptime { continue }
            if result[report.pid] == nil, result.count >= processLimit,
               let evicted = result.keys.filter({ $0 != getpid() && !acceptedPIDs.contains($0) }).max() {
                result.removeValue(forKey: evicted)
            }
            acceptedNames.insert(report.name)
            acceptedPIDs.insert(report.pid)
            result[report.pid] = ProcessCounter(pid: report.pid, startTime: report.startTime, name: report.name,
                                               residentBytes: report.residentBytes, cpuTicks: report.cpuTicks,
                                               sampledAt: report.sampledUptime)
        }
        return result
    }

    private static func memoryPages() -> (free: UInt64, compressed: UInt64)? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var pageSize: vm_size_t = 0
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let expected = count
        guard host_page_size(host, &pageSize) == KERN_SUCCESS, pageSize > 0 else { return nil }
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        guard status == KERN_SUCCESS, count >= expected else { return nil }
        return (UInt64(info.free_count) * UInt64(pageSize), UInt64(info.compressor_page_count) * UInt64(pageSize))
    }

    private static func systemCPUTicks() -> [UInt32]? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let expected = count
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard status == KERN_SUCCESS, count >= expected else { return nil }
        return withUnsafeBytes(of: info.cpu_ticks) { Array($0.bindMemory(to: UInt32.self)) }
    }

    static func systemCPUPercent(current: [UInt32], previous: [UInt32]?, logicalCPUs: Int) -> Double? {
        guard let previous, current.count == 4, previous.count == 4, logicalCPUs > 0 else { return nil }
        // Darwin exposes 32-bit cumulative ticks; unsigned subtraction handles one wrap.
        let deltas = zip(current, previous).map { UInt64($0 &- $1) }
        let total = deltas.reduce(0, +)
        guard total > 0 else { return nil }
        let busy = total - deltas[Int(CPU_STATE_IDLE)]
        return Double(busy) / Double(total) * Double(logicalCPUs) * 100
    }

    private static func processCounter(pid: Int32) -> ProcessCounter? {
        var info = proc_taskallinfo()
        let size = Int32(MemoryLayout<proc_taskallinfo>.size)
        let bytes = withUnsafeMutablePointer(to: &info) { proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, $0, size) }
        guard bytes == size, info.pbsd.pbi_pid == UInt32(pid), info.pbsd.pbi_start_tvsec > 0,
              info.pbsd.pbi_start_tvusec < 1_000_000 else { return nil }
        let seconds = info.pbsd.pbi_start_tvsec.multipliedReportingOverflow(by: 1_000_000)
        let start = seconds.partialValue.addingReportingOverflow(info.pbsd.pbi_start_tvusec)
        let cpu = info.ptinfo.pti_total_user.addingReportingOverflow(info.ptinfo.pti_total_system)
        guard !seconds.overflow, !start.overflow, !cpu.overflow else { return nil }
        let registeredName = withUnsafeBytes(of: info.pbsd.pbi_name) { name(from: Array($0)) }
        let shortName = withUnsafeBytes(of: info.pbsd.pbi_comm) { name(from: Array($0)) }
        return ProcessCounter(pid: pid, startTime: start.partialValue, name: registeredName.isEmpty ? shortName : registeredName,
                              residentBytes: info.ptinfo.pti_resident_size, cpuTicks: cpu.partialValue,
                              sampledAt: ProcessInfo.processInfo.systemUptime)
    }

    static func name(from bytes: [UInt8]) -> String {
        let decoded = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        let basename = decoded.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let scalars = basename.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(64)
        return String(String.UnicodeScalarView(scalars))
    }

    private static func isLidKeep(_ process: ProcessSample, ownPID: Int32) -> Bool {
        process.pid == ownPID || ["lidkeep", "lidkeep-service", "local.rl.lidkeep.service", "lidkeep-daemon", "lidkeep-watchdog"].contains(process.name.lowercased())
    }

    static func selectProcesses(_ processes: [ProcessSample], ownPID: Int32) -> [ProcessSample] {
        func ranked(_ candidates: [ProcessSample], _ score: (ProcessSample) -> Double) -> [ProcessSample] {
            Array(candidates.sorted { score($0) == score($1) ? $0.pid < $1.pid : score($0) > score($1) }.prefix(8))
        }
        let memory = ranked(processes) { Double($0.residentBytes) }
        let cpu = ranked(processes.filter { $0.cpuPercent != nil }) { $0.cpuPercent ?? -1 }
        let growth = ranked(processes.filter { $0.memoryDeltaBytes != nil }) { $0.memoryDeltaBytes.map(Double.init) ?? -Double.infinity }
        let related = processes.filter { isLidKeep($0, ownPID: ownPID) }.sorted {
            if ($0.pid == ownPID) != ($1.pid == ownPID) { return $0.pid == ownPID }
            return $0.pid < $1.pid
        }.prefix(16)
        var seen = Set<Int32>()
        return (memory + cpu + growth + related).filter { seen.insert($0.pid).inserted }
            .sorted { $0.residentBytes == $1.residentBytes ? $0.pid < $1.pid : $0.residentBytes > $1.residentBytes }
    }
}
