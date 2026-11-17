// Sources/EdgeRumCapture/MemorySampler.swift
//
// F10 / T10.2 — memory usage sampler.
//
// Two sources (PLAN-iOS.md §6.11, catalogue #264):
//
//   1. Periodic poll — every 30 s (F30), skipped while the
//      `SamplingGate` is closed: one `memory.usage` event, plus
//      `perf.cpu_usage` (whole-process, per-core percent, may exceed
//      100) from `ProcessCPUReader`. Reads `mach_task_basic_info`
//      (`resident_size`, `virtual_size`) and `task_vm_info`
//      (`phys_footprint`); `memory.usage_mb` is the footprint.
//   2. Memory-pressure source — `DispatchSource.makeMemoryPressureSource`
//      with `.all` mask. Each transition sends `memory.pressure` with
//      `memory.pressure_level` `normal` or `critical` (an iOS warning is
//      critical) and the same snapshot keys. Ungated.
//
// The `memory.*_kb` keys are kB (Int), `memory.usage_mb` binary MB.
// `makeAttributes(rssBytes:vszBytes:footprintBytes:)` is the shared seam.
//
// Recorder access: live `Recorder.shared` is fetched per emission;
// tests swap a probe via `Recorder.installShared(_:)`.
//
// Refs: PLAN-iOS.md §F10/T10.2, §6.11; CLAUDE.md "eventName values" +
//       "When in doubt checklist" items 1, 2, 4.
//

import Foundation
import Dispatch
#if canImport(Darwin)
import Darwin
#endif
import os.log
#if canImport(EdgeRumCore)
import EdgeRumCore
#endif

// MARK: - Pressure level

/// Wire-canonical memory pressure level. The enum's `rawValue` matches
/// the `memory.pressure` attribute string exactly (PLAN-iOS §6.11).
public enum MemoryPressureLevel: String, Sendable, Equatable {
    case normal
    case warning
    case critical
}

// MARK: - Sampler

/// F10 / T10.2 installer — periodic poll + memory-pressure dispatch
/// source.
public enum MemorySampler {

    // MARK: Diagnostics

    private static let log = OSLog(subsystem: "com.edge.rum", category: "MemorySampler")

    // MARK: Once token

    nonisolated(unsafe) private static let installLock: UnsafeMutablePointer<os_unfair_lock> = {
        let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        p.initialize(to: os_unfair_lock())
        return p
    }()

    nonisolated(unsafe) private static var _installed: Bool = false

    /// `true` once `install(...)` has armed both data sources.
    public static var isInstalled: Bool {
        os_unfair_lock_lock(installLock)
        defer { os_unfair_lock_unlock(installLock) }
        return _installed
    }

    // MARK: Public install

    /// Install the memory sampler. Idempotent and concurrent-safe.
    public static func install(debug: Bool = false) {
        os_unfair_lock_lock(installLock)
        if _installed {
            os_unfair_lock_unlock(installLock)
            return
        }
        let driver = Driver(debug: debug)
        driver.start()
        sharedDriver = driver
        _installed = true
        os_unfair_lock_unlock(installLock)
        if debug {
            os_log("MemorySampler installed", log: log, type: .info)
        }
    }

    // MARK: Pure attribute builder

    /// Translate a raw mach snapshot into the
    /// wire-canonical attribute bag. Inputs are in bytes; the `_kb`
    /// keys are kB and `value` (resident set) is MB. A `nil` input
    /// (kernel read failed) omits its keys — never a fake `0` (C21).
    public static func makeAttributes(
        rssBytes: UInt64?,
        vszBytes: UInt64?,
        footprintBytes: UInt64?
    ) -> [String: AttributeValue] {
        // Catalogue memory.usage (#264): usage = phys_footprint in MB
        // (binary), resident set when the footprint is unreadable.
        var attrs: [String: AttributeValue] = [:]
        if let rssBytes { attrs["memory.resident_kb"] = .int(Int(rssBytes / 1024)) }
        if let vszBytes { attrs["memory.virtual_kb"] = .int(Int(vszBytes / 1024)) }
        if let footprintBytes { attrs["memory.footprint_kb"] = .int(Int(footprintBytes / 1024)) }
        if let bytes = footprintBytes ?? rssBytes { attrs["memory.usage_mb"] = .double(Double(bytes) / 1_048_576) }
        return attrs
    }

    /// Convert a `DispatchSource.MemoryPressureEvent` bitmask into our
    /// canonical level. `.critical` wins over `.warning`; anything else
    /// (including `.normal` or an empty mask) is `.normal`.
    public static func pressureLevel(
        for event: DispatchSource.MemoryPressureEvent
    ) -> MemoryPressureLevel {
        if event.contains(.critical) { return .critical }
        if event.contains(.warning) { return .warning }
        return .normal
    }

    // MARK: Emission seam

    /// Emit one `memory.usage` event for the supplied snapshot.
    static func emit(
        rssBytes: UInt64?,
        vszBytes: UInt64?,
        footprintBytes: UInt64?
    ) {
        let recorder = Recorder.shared
        guard recorder.isEnabled else { return }
        recorder.recordEvent(
            name: "memory.usage",
            attributes: makeAttributes(
                rssBytes: rssBytes,
                vszBytes: vszBytes,
                footprintBytes: footprintBytes
            )
        )
    }

    // MARK: Mach reader

    /// Best-effort read of the current task's memory counters. A field
    /// is `nil` when its kernel call fails — the SDK never crashes the
    /// host app on a memory-stat read failure, and never reports a
    /// failed read as a value.
    static func readMachStats() -> (rss: UInt64?, vsz: UInt64?, footprint: UInt64?) {
        #if canImport(Darwin)
        var info = mach_task_basic_info()
        var basicCount = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let basicResult = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &basicCount
                )
            }
        }
        let basicOK = basicResult == KERN_SUCCESS

        var vmInfo = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let vmResult = withUnsafeMutablePointer(to: &vmInfo) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    $0,
                    &vmCount
                )
            }
        }
        return (
            basicOK ? UInt64(info.resident_size) : nil,
            basicOK ? UInt64(info.virtual_size) : nil,
            vmResult == KERN_SUCCESS ? UInt64(vmInfo.phys_footprint) : nil
        )
        #else
        return (nil, nil, nil)
        #endif
    }

    // MARK: Driver

    /// Timer cadence (F30: 10 s → 30 s).
    static let tickSeconds = 30

    /// Owns the dispatch queue, periodic timer, memory-pressure source
    /// and CPU reader. Once `start()`ed, the timer and pressure source
    /// call `tick` / `pressureChanged` on `queue`; tests call them
    /// directly on an un-started driver.
    final class Driver: @unchecked Sendable {

        private let queue: DispatchQueue
        private let debug: Bool
        private let gate: @Sendable () -> Bool
        private let cpuSample: () -> Double?
        private var timer: DispatchSourceTimer?
        private var pressureSource: DispatchSourceMemoryPressure?

        init(
            debug: Bool,
            gate: @escaping @Sendable () -> Bool = { SamplingGate.isOpen() },
            cpuSample: @escaping () -> Double? = ProcessCPUReader().sample
        ) {
            self.cpuSample = cpuSample
            self.queue = DispatchQueue(
                label: "com.edge.rum.memorysampler",
                qos: .utility
            )
            self.debug = debug
            self.gate = gate
        }

        func start() {
            let interval = DispatchTimeInterval.seconds(MemorySampler.tickSeconds)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + interval, repeating: interval)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer

            // Memory-pressure source — ungated.
            let source = DispatchSource.makeMemoryPressureSource(
                eventMask: .all,
                queue: queue
            )
            source.setEventHandler { [weak self] in
                self?.pressureChanged(MemorySampler.pressureLevel(for: source.data))
            }
            source.resume()
            self.pressureSource = source
        }

        /// Timer tick: one `memory.usage` and
        /// one `cpu_usage`, both skipped while the gate is closed.
        func tick() {
            // Read CPU even when gated so the next open sample covers
            // only its own 30 s, not the closed stretch.
            let percent = cpuSample()
            guard gate() else { return }
            emitSnapshot()
            guard let percent, Recorder.shared.isEnabled else { return }
            Recorder.shared.recordPerformance(name: "perf.cpu_usage", attributes: ["value": .double(percent)])
        }

        func pressureChanged(_ level: MemoryPressureLevel) {
            let stats = MemorySampler.readMachStats()
            var attrs = MemorySampler.makeAttributes(
                rssBytes: stats.rss, vszBytes: stats.vsz, footprintBytes: stats.footprint
            )
            // memory.pressure (#264): an iOS memory warning is critical.
            attrs["memory.pressure_level"] = .string(level == .normal ? "normal" : "critical")
            if Recorder.shared.isEnabled { Recorder.shared.recordEvent(name: "memory.pressure", attributes: attrs) }
            if debug {
                os_log(
                    "MemorySampler pressure transition: %{public}@",
                    log: MemorySampler.log,
                    type: .info,
                    level.rawValue
                )
            }
        }

        private func emitSnapshot() {
            let stats = MemorySampler.readMachStats()
            MemorySampler.emit(
                rssBytes: stats.rss,
                vszBytes: stats.vsz,
                footprintBytes: stats.footprint
            )
        }

        func cancel() {
            timer?.cancel()
            timer = nil
            pressureSource?.cancel()
            pressureSource = nil
        }
    }

    nonisolated(unsafe) private static var sharedDriver: Driver?

    // MARK: Test-only helpers

    #if DEBUG
    /// Tear down both data sources and clear the install flag so the
    /// next test starts from a clean state.
    public static func _resetInstallFlagForTesting() {
        os_unfair_lock_lock(installLock)
        sharedDriver?.cancel()
        sharedDriver = nil
        _installed = false
        os_unfair_lock_unlock(installLock)
    }
    #endif
}
