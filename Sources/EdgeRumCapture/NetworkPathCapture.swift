// Sources/EdgeRumCapture/NetworkPathCapture.swift
//
// F11 / T11.2 — NWPathMonitor-driven connectivity capture.
//
// Owns one `NetworkPathObserver` (the shared wrapper in
// `EdgeRumCore/Context/NetworkContext.swift`) and on every transition:
//
//   1. Refreshes `Recorder.refreshNetworkContext(_:)` so subsequent
//      events carry the new `network.type` / `network.effectiveType`.
//   2. Emits one `network_change` event with the wire keys from
//      PLAN-iOS.md §6.19:
//        - network.type
//        - network.effectiveType
//        - network.is_expensive
//        - network.is_constrained
//        - network.unsatisfied_reason (iOS 14.2+, omitted on 14.0/14.1
//          and omitted when path is satisfied)
//
// Duplicate transitions (same NetworkType + effectiveType + flags +
// unsatisfied reason as the last emission) are dropped so a chatty
// monitor doesn't flood the wire.
//
// Recorder access: live `Recorder.shared` is fetched per emission;
// tests swap a probe in via `Recorder.installShared(_:)`.
//
// The `Network.framework` types compile on macOS too, so this file is
// NOT gated behind `#if os(iOS)` — only the actual NWPathMonitor
// activation runs on iOS via `install(...)`.
//
// Refs: PLAN-iOS.md §F11/T11.2, §6.19; CLAUDE.md "eventName values" +
//       "When in doubt checklist" items 1, 2, 4, 10.
//

import Foundation
import Network
import os.log
#if canImport(EdgeRumCore)
import EdgeRumCore
#endif

/// F11 installer — connectivity-change capture.
///
/// `public` here only means "visible to other internal SDK targets and
/// the test target". `EdgeRumCapture` is not a SwiftPM `product`, so
/// consumers who write `import EdgeRum` never see this type.
public enum NetworkPathCapture {

    // MARK: Diagnostics

    private static let log = OSLog(subsystem: "com.edge.rum", category: "NetworkPathCapture")

    // MARK: Once token

    private static let installLock: UnsafeMutablePointer<os_unfair_lock> = {
        let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        p.initialize(to: os_unfair_lock())
        return p
    }()

    nonisolated(unsafe) private static var _installed: Bool = false

    /// `true` once `install(...)` has armed the path observer.
    public static var isInstalled: Bool {
        os_unfair_lock_lock(installLock)
        defer { os_unfair_lock_unlock(installLock) }
        return _installed
    }

    nonisolated(unsafe) private static var sharedObserver: NetworkPathObserver?

    // MARK: Dedupe state

    /// Fingerprint of the last emitted transition. Compared against the
    /// next transition's fingerprint; identical => skip the emit. Kept
    /// as a hashable struct so the comparison is one `==`.
    fileprivate struct Fingerprint: Hashable {
        let type: NetworkContext.NetworkType
        let effectiveType: String
        let isExpensive: Bool
        let isConstrained: Bool
        let unsatisfiedReason: String?
    }

    private static let fingerprintLock: UnsafeMutablePointer<os_unfair_lock> = {
        let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        p.initialize(to: os_unfair_lock())
        return p
    }()
    nonisolated(unsafe) private static var lastFingerprint: Fingerprint?

    // MARK: Public install

    /// Install network-path capture. Idempotent + thread-safe; on
    /// platforms without `Network.framework` runtime support this is a
    /// no-op (compile-time guard not needed — Network is part of the
    /// base SDK on iOS / macOS test hosts).
    public static func install(debug: Bool = false) {
        os_unfair_lock_lock(installLock)
        if _installed {
            os_unfair_lock_unlock(installLock)
            return
        }
        let observer = NetworkPathObserver()
        sharedObserver = observer
        _installed = true
        os_unfair_lock_unlock(installLock)

        observer.start { context, path in
            NetworkPathCapture.handle(context: context, path: path)
        }

        if debug {
            os_log(
                "NetworkPathCapture installed",
                log: log,
                type: .info
            )
        }
    }

    // MARK: Pure attribute builder (test seam)

    /// Build the `network_change` attribute bag. Pure; tests drive it
    /// directly to cover every NetworkType + flag combination.
    ///
    /// `unsatisfiedReason` is omitted from the bag entirely when `nil`
    /// — never set to `"unknown"` — so the iOS 14.0/14.1 absence is
    /// faithfully reflected on the wire.
    static func makeAttributes(
        context: NetworkContext,
        isExpensive: Bool,
        isConstrained: Bool,
        unsatisfiedReason: String?
    ) -> [String: AttributeValue] {
        var attrs: [String: AttributeValue] = [
            "network.type": .string(context.type.rawValue),
            "network.effectiveType": .string(context.effectiveType),
            "network.is_expensive": .bool(isExpensive),
            "network.is_constrained": .bool(isConstrained)
        ]
        if let reason = unsatisfiedReason {
            attrs["network.unsatisfied_reason"] = .string(reason)
        }
        return attrs
    }

    /// Map `NWPath.UnsatisfiedReason` (iOS 14.2+) to a wire string.
    /// `nil` when the path is satisfied. The host-OS gate (`@available`)
    /// is at the call site; this helper just stringifies a value.
    @available(iOS 14.2, macOS 11.0, *)
    static func unsatisfiedReasonString(_ reason: NWPath.UnsatisfiedReason) -> String {
        // Cases by introduction:
        //   iOS 14.2 / macOS 11.0 : notAvailable, cellularDenied,
        //                            wifiDenied, localNetworkDenied
        //   iOS 16.0 / macOS 14.0 : vpnInactive
        // The vpnInactive availability check is split out so the
        // exhaustive `switch` below can compile against the iOS-14.2
        // SDK base.
        if #available(iOS 16.0, macOS 14.0, *), reason == .vpnInactive {
            return "vpn_inactive"
        }
        switch reason {
        case .notAvailable: return "not_available"
        case .cellularDenied: return "cellular_denied"
        case .wifiDenied: return "wifi_denied"
        case .localNetworkDenied: return "local_network_denied"
        @unknown default: return "unknown"
        }
    }

    // MARK: Transition handler

    /// Internal entry point — pull the extras off the raw path, refresh
    /// the Recorder context, and emit `network_change` if this is a
    /// genuine transition. Exposed `internal` so tests can drive it
    /// without a live `NWPathMonitor`.
    static func handle(context: NetworkContext, path: NWPath) {
        let isExpensive = path.isExpensive
        let isConstrained: Bool
        if #available(iOS 13.0, macOS 10.15, *) {
            isConstrained = path.isConstrained
        } else {
            isConstrained = false
        }
        let reason: String?
        if path.status != .satisfied {
            if #available(iOS 14.2, macOS 11.0, *) {
                reason = unsatisfiedReasonString(path.unsatisfiedReason)
            } else {
                reason = nil
            }
        } else {
            reason = nil
        }
        emit(
            context: context,
            isExpensive: isExpensive,
            isConstrained: isConstrained,
            unsatisfiedReason: reason
        )
    }

    /// Internal test seam — emit a transition built from precomputed
    /// extras. Refreshes the Recorder's `NetworkContext`, then emits
    /// `network_change` unless the fingerprint matches the last
    /// emission.
    static func emit(
        context: NetworkContext,
        isExpensive: Bool,
        isConstrained: Bool,
        unsatisfiedReason: String?
    ) {
        let recorder = Recorder.shared
        guard recorder.isEnabled else { return }

        // Always refresh the snapshot so subsequent events ride under
        // the live network attributes — even when we dedup the change
        // event itself. (Cheap; the lock inside ContextProvider is the
        // only cost.)
        recorder.refreshNetworkContext(context)

        let fp = Fingerprint(
            type: context.type,
            effectiveType: context.effectiveType,
            isExpensive: isExpensive,
            isConstrained: isConstrained,
            unsatisfiedReason: unsatisfiedReason
        )

        os_unfair_lock_lock(fingerprintLock)
        let prior = lastFingerprint
        if prior == fp {
            os_unfair_lock_unlock(fingerprintLock)
            return
        }
        lastFingerprint = fp
        os_unfair_lock_unlock(fingerprintLock)

        recorder.recordEvent(
            name: "network_change",
            attributes: makeAttributes(
                context: context,
                isExpensive: isExpensive,
                isConstrained: isConstrained,
                unsatisfiedReason: unsatisfiedReason
            )
        )
    }

    // MARK: Test-only helpers

    #if DEBUG
    /// Tear down the running observer and clear the install flag so
    /// subsequent tests can drive `install()` from a clean state.
    public static func _resetInstallFlagForTesting() {
        os_unfair_lock_lock(installLock)
        sharedObserver?.stop()
        sharedObserver = nil
        _installed = false
        os_unfair_lock_unlock(installLock)

        os_unfair_lock_lock(fingerprintLock)
        lastFingerprint = nil
        os_unfair_lock_unlock(fingerprintLock)
    }

    /// Test seam — clear just the dedupe fingerprint so a second
    /// `emit(...)` with the same shape re-emits.
    public static func _resetDedupeFingerprintForTesting() {
        os_unfair_lock_lock(fingerprintLock)
        lastFingerprint = nil
        os_unfair_lock_unlock(fingerprintLock)
    }
    #endif
}
