import Foundation
import LidKeepCore

enum DiagnosticReport {
    private struct Identity: Hashable { let pid: Int32; let start: UInt64 }
    private struct ProcessSummary {
        let identity: Identity
        let name: String
        let firstBytes: UInt64
        var peakBytes: UInt64
        var peakCPU: Double?
        let firstSeen: Date
        var samples: Int
    }

    static func render(session: DiagnosticSession, snapshots: [ResourceSnapshot], ending: DiagnosticEnding?,
                       recording: Bool, interrupted: Bool, damaged: Bool) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        func time(_ date: Date) -> String { formatter.string(from: date) }
        let kind = session.kind == "manual" ? "手动检查" : session.kind == "lid" || session.kind == "lidClosed" ? "合盖检查" : clean(session.kind)
        let state = recording ? "仍在采集（本报告只包含生成前已保存的样本）" : interrupted ? "采集中断（无法确定中断后的状态）" : "已结束"
        var lines = ["# LidKeep 资源诊断报告", "", "- 类型：\(kind)", "- 状态：\(state)",
                     "- 会话：\(session.id)；第 \(session.segment) 段", "- 开始：\(time(session.startedAt))",
                     "- 最后观测：\(snapshots.last.map { time($0.timestamp) } ?? "没有有效样本")"]
        if let ending { lines.append("- 结束：\(time(ending.at))；原因：\(clean(ending.reason))") }
        if let previous = session.previousID {
            lines.append("- 续接会话：\(previous)；\(clean(session.continuationReason ?? "达到记录上限"))")
        }
        lines += ["", "采样默认每 30 秒一次。记录只反映采样时刻，不能证明两个样本之间始终正常；超过 60 秒的间隔单独标记。", ""]
        if damaged { lines += ["注意：文件含未完成或无效记录，以下结论只使用成功解码的样本。", ""] }
        guard !snapshots.isEmpty else {
            return (lines + ["没有有效采样，无法判断内存、CPU 或温控状况。", ""]).joined(separator: "\n")
        }

        var gaps: [String] = []
        var observedIntervals: TimeInterval = 0
        for (first, second) in zip(snapshots, snapshots.dropFirst()) {
            let interval = second.timestamp.timeIntervalSince(first.timestamp)
            if interval > 60 {
                gaps.append("\(time(first.timestamp)) → \(time(second.timestamp))：\(Int(interval)) 秒无采样")
            } else if interval >= 0 { observedIntervals += interval }
            else { gaps.append("\(time(second.timestamp))：墙钟时间倒退，区间覆盖率无法可靠比较") }
        }
        if let first = snapshots.first, first.timestamp.timeIntervalSince(session.startedAt) > 60 {
            gaps.insert("开始 → 首个样本：\(Int(first.timestamp.timeIntervalSince(session.startedAt))) 秒无采样", at: 0)
        }
        if let last = snapshots.last, let ending, ending.at.timeIntervalSince(last.timestamp) > 60 {
            gaps.append("最后样本 → 结束：\(Int(ending.at.timeIntervalSince(last.timestamp))) 秒无采样")
        }
        let end = ending?.at ?? snapshots.last!.timestamp
        let duration = max(0, end.timeIntervalSince(session.startedAt))
        let coverage = duration > 0 ? String(format: "%.1f%%", min(100, observedIntervals / duration * 100)) : "单次采样，不计算"
        let peakNonFree = snapshots.compactMap { value -> UInt64? in
            guard let free = value.freeMemoryBytes, free <= value.totalMemoryBytes else { return nil }
            return value.totalMemoryBytes - free
        }.max()
        let peakSwap = snapshots.compactMap(\.swapUsedBytes).max()
        let peakCompressed = snapshots.compactMap(\.compressedBytes).max()
        let thermalOrder: [ThermalLevel] = [.nominal, .fair, .serious, .critical]
        let thermal = snapshots.map(\.context.thermal).filter { $0 != .unknown }.max {
            thermalOrder.firstIndex(of: $0)! < thermalOrder.firstIndex(of: $1)!
        }
        let pressures = Set(snapshots.map { clean($0.memoryPressure) }).sorted().joined(separator: "、")
        let systemCPU = snapshots.compactMap(\.systemCPUPercent).max()
        lines += ["## 观测摘要", "", "- 样本数：\(snapshots.count)；相邻有效区间占报告时段：\(coverage)（仅统计间隔 ≤60 秒的区间）",
                  "- 超过 60 秒的缺口或时间异常：\(gaps.count) 处",
                  "- 物理内存：\(bytes(snapshots.map(\.totalMemoryBytes).max()))；非空闲内存估算峰值：\(bytes(peakNonFree))",
                  "- 压缩内存峰值：\(bytes(peakCompressed))；交换区使用峰值：\(bytes(peakSwap))",
                  "- 内存压力观测值：\(pressures)", "- 系统 CPU 观测峰值：\(percent(systemCPU))",
                  "- 系统热状态最高观测值：\(thermal?.label ?? "未知")；未知热状态样本：\(snapshots.filter { $0.context.thermal == .unknown }.count)",
                  "- 后台状态过期/不可用样本：\(snapshots.filter { !$0.context.statusFresh }.count)",
                  "- 进程列表截断样本：\(snapshots.filter(\.processListTruncated).count)；最多无法读取进程数：\(snapshots.map(\.unreadableProcessCount).max() ?? 0)", "",
                  "非空闲内存是“物理内存减空闲页”的估算，包含缓存等，不等于应用独占内存。进程内存使用 RSS，含共享页；多个进程 RSS 相加会重复计算，不能与活动监视器的“内存”列直接等同。进程 CPU 可超过 100%（多核）；CPU 高或内存增长本身不能证明泄漏，也不能单独确定发热原因。", ""]

        var processes: [Identity: ProcessSummary] = [:]
        let initial = Set(snapshots[0].processes.map { Identity(pid: $0.pid, start: $0.startTime) })
        for snapshot in snapshots {
            for process in snapshot.processes {
                let identity = Identity(pid: process.pid, start: process.startTime)
                if var summary = processes[identity] {
                    summary.peakBytes = max(summary.peakBytes, process.residentBytes)
                    if let cpu = process.cpuPercent { summary.peakCPU = max(summary.peakCPU ?? cpu, cpu) }
                    summary.samples += 1
                    processes[identity] = summary
                } else {
                    processes[identity] = ProcessSummary(identity: identity, name: process.name, firstBytes: process.residentBytes,
                                                         peakBytes: process.residentBytes, peakCPU: process.cpuPercent,
                                                         firstSeen: snapshot.timestamp, samples: 1)
                }
            }
        }
        let sorted = processes.values.sorted {
            $0.peakBytes == $1.peakBytes ? ($0.identity.pid, $0.identity.start) < ($1.identity.pid, $1.identity.start) : $0.peakBytes > $1.peakBytes
        }
        lines += ["## LidKeep 自身的可读进程", "", "此处列出采样器和已验证后台状态提供的可读进程。后台状态过期或不可用时可能缺少两个管理员后台；不能将 App 一行当作三个进程的总和。", ""]
        let own = sorted.filter { $0.name.lowercased().contains("lidkeep") }
        if own.isEmpty { lines.append("本段没有采集到可读的 LidKeep 进程数据。") }
        for process in own.prefix(20) {
            lines.append("- \(clean(process.name))（PID \(process.identity.pid) / \(process.identity.start)）：RSS 峰值 \(bytes(process.peakBytes))；相对首次最大增长 +\(bytes(process.peakBytes - process.firstBytes))；CPU 峰值 \(percent(process.peakCPU))")
        }
        lines.append("")
        lines += ["## 进程观测峰值（按 RSS 前 20）", "", "PID 与启动标识一起区分进程，PID 复用不合并。表格只含采样器选中的进程；短命或未入榜的进程可能遗漏。", "",
                  "| 进程 | PID / 启动标识 | RSS 峰值 | 相对首次最大增长 | CPU 峰值 | 观测次数 |", "| --- | --- | ---: | ---: | ---: | ---: |"]
        for process in sorted.prefix(20) {
            lines.append("| \(clean(process.name)) | \(process.identity.pid) / \(process.identity.start) | \(bytes(process.peakBytes)) | +\(bytes(process.peakBytes - process.firstBytes)) | \(percent(process.peakCPU)) | \(process.samples) |")
        }
        lines += ["", "## 采样期间新出现的进程（按 RSS 峰值前 20）", "", "“新出现”指首个样本未见、后续被观测到；可能是新启动，也可能是后来进入采样排行榜。", ""]
        let newcomers = sorted.filter { !initial.contains($0.identity) }
        if newcomers.isEmpty { lines.append("未观测到新出现的进程。") }
        for process in newcomers.prefix(20) {
            lines.append("- \(clean(process.name))，PID \(process.identity.pid) / \(process.identity.start)，首次见于 \(time(process.firstSeen))，RSS 峰值 \(bytes(process.peakBytes))")
        }
        lines += ["", "## 保活与保护状态变化", "", "仅记录与上个有效样本不同的状态；过期状态不代表当时实际情况。", ""]
        var changes: [String] = []
        var previousState: String?
        for snapshot in snapshots {
            let context = snapshot.context
            let state = "模式 \(clean(context.mode ?? "未知"))；\(clean(context.reason ?? "原因不可用"))；热状态 \(context.thermal.label)；后台状态\(context.statusFresh ? "有效" : "过期/不可用")；\(context.sleepDisabled.map { $0 ? "已禁用休眠" : "正常休眠" } ?? "休眠设置未知")"
            if state != previousState { changes.append("- \(time(snapshot.timestamp))：\(state)"); previousState = state }
        }
        if changes.count > 80 { lines.append("状态变化共 \(changes.count) 次，以下保留最后 80 次。") }
        lines += changes.suffix(80)
        lines += ["", "## 采样缺口", ""]
        lines += gaps.isEmpty ? ["未发现超过 60 秒的采样间隔。"] : gaps.map { "- " + $0 }
        if interrupted { lines.append("- 最后样本之后的中断时长未知；该时段没有数据，不能推断其状态。") }
        let warnings = Set(snapshots.flatMap(\.warnings).map(clean)).sorted()
        if !warnings.isEmpty { lines += ["", "## 采集提示", ""] + warnings.prefix(40).map { "- " + $0 } }
        lines += ["", "## 采样时间线", "", "| 时间 | 合盖 | 电量 | 热状态 | 内存压力 | 非空闲估算 | 交换区 | 系统 CPU | 保活状态 |", "| --- | --- | ---: | --- | --- | ---: | ---: | ---: | --- |"]
        for snapshot in snapshots.prefix(720) {
            let used = snapshot.freeMemoryBytes.flatMap { $0 <= snapshot.totalMemoryBytes ? snapshot.totalMemoryBytes - $0 : nil }
            let lid = snapshot.context.lidClosed.map { $0 ? "合盖" : "开盖" } ?? "未知"
            let awake = snapshot.context.sleepDisabled.map { $0 ? "已禁用休眠" : "正常休眠" } ?? "未知"
            lines.append("| \(time(snapshot.timestamp)) | \(lid) | \(percent(snapshot.context.batteryPercent)) | \(snapshot.context.thermal.label) | \(clean(snapshot.memoryPressure)) | \(bytes(used)) | \(bytes(snapshot.swapUsedBytes)) | \(percent(snapshot.systemCPUPercent)) | \(awake)\(snapshot.context.statusFresh ? "" : "（状态过期）") |")
        }
        lines += ["", "记录仅保存在本机：在启动或产生／更新记录时，按 7 天、正常记录 20 段、系统事件另 8 段、记录与报告合计 32 MiB 清理；总容量不足时优先清理事件。每段最多 720 次采样或 8 MiB，达到上限会继续下一段。", ""]
        return lines.joined(separator: "\n")
    }

    private static func clean(_ string: String) -> String {
        String(string.prefix(200)).replacingOccurrences(of: "|", with: "／")
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "<", with: "＜").replacingOccurrences(of: ">", with: "＞")
    }
    private static func bytes(_ value: UInt64?) -> String {
        guard let value else { return "未知" }
        return String(format: "%.1f MiB", Double(value) / 1_048_576)
    }
    private static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "未知" }
        return String(format: "%.1f%%", value)
    }
}
