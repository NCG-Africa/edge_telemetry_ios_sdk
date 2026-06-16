// Sources/EdgeRumCapture/MemorySampler.swift
//
// F10 / T10.2 — memory usage sampler.
//
// Two complementary sources feed the same `memory_usage` metric
// (PLAN-iOS.md §6.11):
//
//   1. Periodic poll — every 10 s. Reads `mach_task_basic_info`
//      (`resident_size`, `virtual_size`) and `task_vm_info`
//      (`phys_footprint`) so we can report what's wired in memory,
//      what the address space looks like, and what the kernel actually
//      bills the app for.
//   2. Memory-pressure source — `DispatchSource.makeMemoryPressureSource`
//      with `.all` mask. Each transition emits a fresh sample tagged
//      with `memory.pressure ∈ {"normal","warning","critical"}` so a
//      dashboard can correlate the spike with the system pressure
//      event that triggered it.
//
// All values are in kB (Int) per PLAN-iOS §6.11. The pure
// `makeAttributes(rss:vsz:footprint:pressure:)` builder is the
// shared seam — both feeds route through it so the on-the-wire
// attribute shape is identical.
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
/// source. Both feeds emit through `Recorder.shared.recordPerformance`
/// as `memory_usage` metrics.
public enum MemorySampler {

    // MARK: Diagnostics

    private static let log = OSLog(subsystem: "com.edge.rum", category: "MemorySampler")

    // MARK: Once token

    private static let installLock: UnsafeMutablePointer<os_unfair_lock> = {
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

    /// Translate a raw mach snapshot + pressure level into the
    /// wire-canonical attribute bag. Inputs are in bytes; the bag
    /// emits kB (PLAN-iOS §6.11). All values are primitives — the
    /// type system enforces "no nested attributes" already.
    public static func makeAttributes(
        rssBytes: UInt64,
        vszBytes: UInt64,
        footprintBytes: UInt64,
        pressure: MemoryPressureLevel
    ) -> [String: AttributeValue] {
        let rssKb = Int(rssBytes / 1024)
        let vszKb = Int(vszBytes / 1024)
        let footKb = Int(footprintBytes / 1024)
        return [
            "memory.resident_kb": .int(rssKb),
            "memory.virtual_kb": .int(vszKb),
            "memory.footprint_kb": .int(footKb),
            "memory.pressure": .string(pressure.rawValue),
            // Recorder.recordPerformance pulls `value` off the bag as
            // the headline scalar — we expose `resident_kb` as the most
            // actionable number so a dashboard can sort by RSS without
            // unrolling the attribute bag.
            "value": .double(Double(rssKb))
        ]
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

    /// Public seam — emit one `memory_usage` metric with the supplied
    /// snapshot + pressure level. Both the periodic timer and the
    /// memory-pressure handler funnel through here so the wire shape
    /// is identical.
    static func emit(
        rssBytes: UInt64,
        vszBytes: UInt64,
        footprintBytes: UInt64,
        pressure: MemoryPressureLevel
    ) {
        let recorder = Recorder.shared
        guard recorder.isEnabled else { return }
        recorder.recordPerformance(
            name: "memory_usage",
            attributes: makeAttributes(
                rssBytes: rssBytes,
                vszBytes: vszBytes,
                footprintBytes: footprintBytes,
                pressure: pressure
            )
        )
    }

    // MARK: Mach reader

    /// Best-effort read of the current task's memory counters. Returns
    /// zeros when the kernel call fails — the SDK never crashes the
    /// host app on a memory-stat read failure.
    static func readMachStats() -> (rss: UInt64, vsz: UInt64, footprint: UInt64) {
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
        let rss: UInt64
        let vsz: UInt64
        if basicResult == KERN_SUCCESS {
            rss = UInt64(info.resident_size)
            vsz = UInt64(info.virtual_size)
        } else {
            rss = 0
            vsz = 0
        }

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
        let footprint: UInt64
        if vmResult == KERN_SUCCESS {
            footprint = UInt64(vmInfo.phys_footprint)
        } else {
            footprint = rss
        }
        return (rss, vsz, footprint)
        #else
        return (0, 0, 0)
        #endif
    }

    // MARK: Driver

    /// Owns the dispatch queue, periodic timer, and memory-pressure
    /// source. Both sources feed `emitSnapshot(pressure:)`.
    private final class Driver: @unchecked Sendable {

        private let queue: DispatchQueue
        private let debug: Bool
        private var timer: DispatchSourceTimer?
        private var pressureSource: DispatchSourceMemoryPressure?

        init(debug: Bool) {
            self.queue = DispatchQueue(
                label: "com.edge.rum.memorysampler",
                qos: .utility
            )
            self.debug = debug
        }

        func start() {
            // Periodic timer — 10 s cadence.
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 10, repeating: 10)
            timer.setEventHandler { [weak self] in
                self?.emitSnapshot(pressure: .normal)
            }
            timer.resume()
            self.timer = timer

            // Memory-pressure source.
            let source = DispatchSource.makeMemoryPressureSource(
                eventMask: .all,
                queue: queue
            )
            source.setEventHandler { [weak self] in
                guard let self = self else { return }
                let mask = source.data
                let level = MemorySampler.pressureLevel(for: mask)
                self.emitSnapshot(pressure: level)
                if self.debug {
                    os_log(
                        "MemorySampler pressure transition: %{public}@",
                        log: MemorySampler.log,
                        type: .info,
                        level.rawValue
                    )
                }
            }
            source.resume()
            self.pressureSource = source
        }

        func emitSnapshot(pressure: MemoryPressureLevel) {
            let stats = MemorySampler.readMachStats()
            MemorySampler.emit(
                rssBytes: stats.rss,
                vszBytes: stats.vsz,
                footprintBytes: stats.footprint,
                pressure: pressure
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
