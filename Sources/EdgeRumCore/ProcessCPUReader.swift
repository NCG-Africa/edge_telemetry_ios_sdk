// Sources/EdgeRumCore/ProcessCPUReader.swift
//
// Whole-process CPU reader (F26 / roadmap tranche 1). CPU seconds =
// live threads (`TASK_THREAD_TIMES_INFO`) + terminated threads
// (`MACH_TASK_BASIC_INFO` user/system time). `sample()` returns the
// delta over monotonic wall time as per-core percent — one busy core
// is 100, so values may exceed 100. Feeds `hang.cpu_usage`; tranche 5
// reuses it for the `cpu_usage` metric.
//

import Foundation
import Darwin

public final class ProcessCPUReader: @unchecked Sendable {

    private let lock = NSLock()
    private var last: (cpu: Double, wall: UInt64)?

    /// Primes the baseline so the first `sample()` already has a delta.
    public init() {
        _ = sample()
    }

    /// Per-core CPU percent of the whole process since the previous
    /// call. `nil` on the priming call or when Mach refuses the read.
    public func sample() -> Double? {
        guard let cpu = Self.processCPUSeconds() else { return nil }
        let wall = DispatchTime.now().uptimeNanoseconds
        lock.lock(); defer { lock.unlock() }
        defer { last = (cpu, wall) }
        guard let last, wall > last.wall else { return nil }
        return max(0, cpu - last.cpu) / (Double(wall - last.wall) / 1e9) * 100
    }

    static func processCPUSeconds() -> Double? {
        var live = task_thread_times_info_data_t()
        var liveCount = mach_msg_type_number_t(
            MemoryLayout<task_thread_times_info_data_t>.size / MemoryLayout<natural_t>.size)
        var dead = mach_task_basic_info_data_t()
        var deadCount = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let liveOK = withUnsafeMutablePointer(to: &live) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(liveCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &liveCount)
            }
        }
        let deadOK = withUnsafeMutablePointer(to: &dead) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(deadCount)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &deadCount)
            }
        }
        guard liveOK == KERN_SUCCESS, deadOK == KERN_SUCCESS else { return nil }
        func seconds(_ t: time_value_t) -> Double { Double(t.seconds) + Double(t.microseconds) / 1e6 }
        return seconds(live.user_time) + seconds(live.system_time)
            + seconds(dead.user_time) + seconds(dead.system_time)
    }
}
