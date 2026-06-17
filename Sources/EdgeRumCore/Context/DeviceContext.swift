// Sources/EdgeRumCore/Context/DeviceContext.swift
//
// Snapshot of device-identity attributes. Reads:
//   - `UIDevice` for systemVersion, model name, battery level/state,
//     simulator detection via TARGET_OS_SIMULATOR.
//   - `UIScreen.main` for screen dimensions + pixelRatio.
//   - `utsname()` for the hardware model identifier (`iPhone15,3`),
//     because `UIDevice.model` returns the human-readable family.
//
// Hardware model identifier on simulator: when running under the
// simulator, `utsname.machine` returns the host architecture
// (`arm64`/`x86_64`) — we substitute `"Simulator"` so the wire
// attribute still carries something meaningful.
//
// Wire keys (CLAUDE.md):
//   device.platform             = "ios"
//   device.manufacturer         = "Apple"
//   device.os                   = "ios"
//   device.platform_version     — UIDevice.current.systemVersion
//   device.model                — utsname identifier
//   device.isVirtual            — simulator detect
//   device.screenWidth/Height   — UIScreen.main.nativeBounds (points × scale)
//   device.pixelRatio           — UIScreen.main.scale
//   device.batteryLevel         — UIDevice.batteryLevel (when monitoring)
//   device.batteryCharging      — UIDevice.batteryState ∈ {.charging,.full}
//   device.locale               — Locale.current.identifier            (F16/T16.5)
//   device.timezone             — TimeZone.current.identifier          (F16/T16.5)
//   device.timezone_offset_min  — TimeZone.current.secondsFromGMT()/60 (F16/T16.5)
//
// Note: `device.id` is owned by `IdentityProvider` (F4) and merged
// in alongside; this struct holds only the immutable / cheap reads.
//
// Refs: PLAN-iOS.md §7.5, §F3/T3.3, §16.4 / F16; docs/data-flow.md §3.2.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

public struct DeviceContext: Sendable, Hashable {

    public var platform: String
    public var manufacturer: String
    public var os: String
    public var platformVersion: String?
    public var model: String?
    public var isVirtual: Bool
    public var screenWidth: Int?
    public var screenHeight: Int?
    public var pixelRatio: Double?
    public var batteryLevel: Double?
    public var batteryCharging: Bool?
    public var locale: String?
    public var timezone: String?
    public var timezoneOffsetMin: Int?

    public init(
        platform: String = "ios",
        manufacturer: String = "Apple",
        os: String = "ios",
        platformVersion: String? = nil,
        model: String? = nil,
        isVirtual: Bool = false,
        screenWidth: Int? = nil,
        screenHeight: Int? = nil,
        pixelRatio: Double? = nil,
        batteryLevel: Double? = nil,
        batteryCharging: Bool? = nil,
        locale: String? = nil,
        timezone: String? = nil,
        timezoneOffsetMin: Int? = nil
    ) {
        self.platform = platform
        self.manufacturer = manufacturer
        self.os = os
        self.platformVersion = platformVersion
        self.model = model
        self.isVirtual = isVirtual
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.pixelRatio = pixelRatio
        self.batteryLevel = batteryLevel
        self.batteryCharging = batteryCharging
        self.locale = locale
        self.timezone = timezone
        self.timezoneOffsetMin = timezoneOffsetMin
    }

    public static func snapshot() -> DeviceContext {
        #if canImport(UIKit)
        let device = UIDevice.current
        let platformVersion = device.systemVersion

        let model = hardwareModelIdentifier()

        #if targetEnvironment(simulator)
        let isVirtual = true
        #else
        let isVirtual = false
        #endif

        // UIScreen access requires the main actor on Swift 6. We're
        // already initialised on `start()` which the host calls on
        // the main thread, but be defensive: read on main if needed.
        let (w, h, scale): (Int?, Int?, Double?) = readScreenMetrics()

        // Battery monitoring requires explicit opt-in; do not flip the
        // global state here — F3 ContextProvider toggles it once at
        // start when the host opted in. We read whatever state is
        // already enabled.
        let batteryLevel: Double?
        let batteryCharging: Bool?
        if device.isBatteryMonitoringEnabled {
            let level = Double(device.batteryLevel)
            batteryLevel = level >= 0 ? level : nil
            switch device.batteryState {
            case .charging, .full:
                batteryCharging = true
            case .unplugged:
                batteryCharging = false
            case .unknown:
                batteryCharging = nil
            @unknown default:
                batteryCharging = nil
            }
        } else {
            batteryLevel = nil
            batteryCharging = nil
        }

        let (localeId, tzId, tzOffset) = readLocaleAndTimezone()

        return DeviceContext(
            platformVersion: platformVersion,
            model: model,
            isVirtual: isVirtual,
            screenWidth: w,
            screenHeight: h,
            pixelRatio: scale,
            batteryLevel: batteryLevel,
            batteryCharging: batteryCharging,
            locale: localeId,
            timezone: tzId,
            timezoneOffsetMin: tzOffset
        )
        #else
        let (localeId, tzId, tzOffset) = readLocaleAndTimezone()
        return DeviceContext(
            locale: localeId,
            timezone: tzId,
            timezoneOffsetMin: tzOffset
        )
        #endif
    }

    public func write(into bag: inout AttributeBag) {
        bag.set("device.platform", .string(platform))
        bag.set("device.manufacturer", .string(manufacturer))
        bag.set("device.os", .string(os))
        bag.setIfPresent("device.platform_version", platformVersion.map { .string($0) })
        bag.setIfPresent("device.model", model.map { .string($0) })
        bag.set("device.isVirtual", .bool(isVirtual))
        bag.setIfPresent("device.screenWidth", screenWidth.map { .int($0) })
        bag.setIfPresent("device.screenHeight", screenHeight.map { .int($0) })
        bag.setIfPresent("device.pixelRatio", pixelRatio.map { .double($0) })
        bag.setIfPresent("device.batteryLevel", batteryLevel.map { .double($0) })
        bag.setIfPresent("device.batteryCharging", batteryCharging.map { .bool($0) })
        bag.setIfPresent("device.locale", locale.map { .string($0) })
        bag.setIfPresent("device.timezone", timezone.map { .string($0) })
        bag.setIfPresent("device.timezone_offset_min", timezoneOffsetMin.map { .int($0) })
    }
}

/// Read `Locale.current.identifier`, `TimeZone.current.identifier`, and
/// the GMT offset (minutes) for the F16/T16.5 wire keys. Returns
/// `(nil, nil, nil)` only when the underlying values are empty, which
/// is essentially impossible on a real device but defends the tests.
internal func readLocaleAndTimezone() -> (String?, String?, Int?) {
    let localeId = Locale.current.identifier
    let tzId = TimeZone.current.identifier
    let offsetMinutes = TimeZone.current.secondsFromGMT() / 60
    return (
        localeId.isEmpty ? nil : localeId,
        tzId.isEmpty ? nil : tzId,
        offsetMinutes
    )
}

#if canImport(UIKit)

/// Read `utsname.machine` so we get the hardware identifier
/// (`iPhone15,3`) rather than the family name (`iPhone`).
private func hardwareModelIdentifier() -> String? {
    var sysinfo = utsname()
    guard uname(&sysinfo) == 0 else { return nil }
    let mirror = Mirror(reflecting: sysinfo.machine)
    let identifier = mirror.children
        .compactMap { $0.value as? Int8 }
        .filter { $0 != 0 }
        .map { String(UnicodeScalar(UInt8($0))) }
        .joined()
    if identifier.isEmpty { return nil }
    #if targetEnvironment(simulator)
    // On the simulator utsname returns the host architecture
    // (`arm64`, `x86_64`). The SIMULATOR_MODEL_IDENTIFIER environment
    // variable carries the user-selected device model.
    if let simModel = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
        return simModel
    }
    return "Simulator"
    #else
    return identifier
    #endif
}

private func readScreenMetrics() -> (Int?, Int?, Double?) {
    // UIScreen access is non-Sendable / main-actor on Swift 6 but
    // safe to read from any thread on iOS 14+ since we touch only
    // value-type bridged properties. Use `MainActor.assumeIsolated`
    // when we're already on main; otherwise sync-dispatch.
    if Thread.isMainThread {
        return readScreenMetricsOnMain()
    }
    var result: (Int?, Int?, Double?) = (nil, nil, nil)
    DispatchQueue.main.sync { result = readScreenMetricsOnMain() }
    return result
}

private func readScreenMetricsOnMain() -> (Int?, Int?, Double?) {
    let bounds = UIScreen.main.nativeBounds
    let scale = Double(UIScreen.main.scale)
    return (Int(bounds.width), Int(bounds.height), scale)
}
#endif
