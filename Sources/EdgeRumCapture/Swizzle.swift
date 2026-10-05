// Sources/EdgeRumCapture/Swizzle.swift
//
// One IMP exchange for the capture swizzles that report a capability
// failure (F32): an unresolved selector leaves the subsystem blind for
// the process, surfaced as `sdk.capabilities_failed` on the envelope.

import Foundation
import EdgeRumCore

enum Swizzle {

    /// Exchange two instance-method IMPs on `base`. Returns `false`
    /// and records `capability` as failed when either selector does
    /// not resolve; nothing is swapped then.
    @discardableResult
    static func exchange(
        _ base: AnyClass,
        _ original: Selector,
        _ swizzled: Selector,
        capability: SdkHealth.Capability,
        health: SdkHealth = .shared
    ) -> Bool {
        guard
            let originalMethod = class_getInstanceMethod(base, original),
            let swizzledMethod = class_getInstanceMethod(base, swizzled)
        else {
            health.fail(capability)
            return false
        }
        method_exchangeImplementations(originalMethod, swizzledMethod)
        return true
    }
}
