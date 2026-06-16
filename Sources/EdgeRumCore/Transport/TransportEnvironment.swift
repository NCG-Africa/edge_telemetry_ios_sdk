// Sources/EdgeRumCore/Transport/TransportEnvironment.swift
//
// Small helper that resolves the device/OS fragments of the
// `User-Agent` header (`EdgeRum-iOS/<sdk> (<device.model>; iOS <os>)`)
// without dragging UIKit into the EdgeRum umbrella module.
//
// On iOS we use `utsname.machine` and `UIDevice.current.systemVersion`;
// on the macOS host (where `swift test` runs in CI) we fall back to
// `"macOS-host"` / `ProcessInfo.operatingSystemVersionString`. The
// public umbrella module would otherwise have to know about UIKit to
// build the header — keeping the logic here so it lives once.
//
// Refs: PLAN-iOS.md §7.1, §F5/T5.1.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

public enum TransportEnvironment {

    /// Best-effort device model. iOS: `utsname.machine` (`iPhone15,3`);
    /// non-iOS hosts: `"macOS-host"` so unit tests get a stable value.
    public static func deviceModel() -> String {
        #if targetEnvironment(simulator) && canImport(UIKit)
        var system = utsname()
        uname(&system)
        let mirror = Mirror(reflecting: system.machine)
        var bytes: [CChar] = []
        for child in mirror.children {
            if let value = child.value as? Int8 { bytes.append(value) }
        }
        bytes.append(0)
        return String(cString: bytes)
        #elseif canImport(UIKit)
        var system = utsname()
        uname(&system)
        let mirror = Mirror(reflecting: system.machine)
        var bytes: [CChar] = []
        for child in mirror.children {
            if let value = child.value as? Int8 { bytes.append(value) }
        }
        bytes.append(0)
        return String(cString: bytes)
        #else
        return "macOS-host"
        #endif
    }

    /// Best-effort OS version string used in the `User-Agent` and in
    /// `device.platform_version`. iOS: `UIDevice.current.systemVersion`;
    /// macOS host: `ProcessInfo.processInfo.operatingSystemVersionString`.
    public static func osVersion() -> String {
        #if canImport(UIKit)
        return UIDevice.current.systemVersion
        #else
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        #endif
    }
}
