// Sources/EdgeRumCore/Context/PowerContext.swift
//
// F16/T16.1 — `device.thermal_state` + `device.low_power_mode`.
//
// Reads `ProcessInfo.processInfo.thermalState` and
// `ProcessInfo.processInfo.isLowPowerModeEnabled`. The two underlying
// values change via `thermalStateDidChangeNotification` and
// `NSProcessInfoPowerStateDidChange`; observers in `ContextObservers`
// call `ContextProvider.refreshPower(.snapshot())` on each change so
// the next emitted event carries the fresh values.
//
// Wire keys (docs/data-flow.md §3.2):
//   device.thermal_state    — "nominal" / "fair" / "serious" / "critical"
//   device.low_power_mode   — Bool
//
// Refs: PLAN-iOS.md §16.4 / F16 / T16.1.
//

import Foundation

public struct PowerContext: Sendable, Hashable {

    public var thermalState: String?
    public var lowPowerMode: Bool?

    public init(thermalState: String? = nil, lowPowerMode: Bool? = nil) {
        self.thermalState = thermalState
        self.lowPowerMode = lowPowerMode
    }

    /// Snapshot the live `ProcessInfo` values. Cheap and thread-safe;
    /// `ProcessInfo.processInfo` is the shared singleton.
    ///
    /// `isLowPowerModeEnabled` is iOS 9.0+ but macOS 12.0+ — the
    /// package targets macOS 11 (test host only), so the macOS branch
    /// is gated and reports `nil` when unavailable.
    public static func snapshot() -> PowerContext {
        let info = ProcessInfo.processInfo
        let lowPower: Bool?
        #if os(iOS)
        lowPower = info.isLowPowerModeEnabled
        #else
        if #available(macOS 12.0, *) {
            lowPower = info.isLowPowerModeEnabled
        } else {
            lowPower = nil
        }
        #endif
        return PowerContext(
            thermalState: Self.thermalStateString(info.thermalState),
            lowPowerMode: lowPower
        )
    }

    public func write(into bag: inout AttributeBag) {
        bag.setIfPresent("device.thermal_state", thermalState.map { .string($0) })
        bag.setIfPresent("device.low_power_mode", lowPowerMode.map { .bool($0) })
    }

    /// Map `ProcessInfo.ThermalState` to the wire string. Exposed
    /// internal so `PowerContextTests` can drive every case without a
    /// real device or simulator under heat stress.
    internal static func thermalStateString(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "nominal"
        }
    }
}
