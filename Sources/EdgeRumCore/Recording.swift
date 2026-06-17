// Sources/EdgeRumCore/Recording.swift
//
// Internal seam for the public `EdgeRum` namespace. F2's job was to
// stand up the public surface; F3 lands the real Recorder behind this
// protocol. Existing test probes (e.g. `ProbeRecorder`) keep working
// unchanged — the F3 `configure(_:)` addition carries a default no-op
// via protocol extension.
//
// Refs: PLAN-iOS.md §F2/T2.1, §F3/T3.1.
//

import Foundation

/// A minimal description of a value passed to `Recording.setUser`.
///
/// We deliberately mirror the shape of the public `UserContext` here
/// rather than depending on it — the public module imports
/// `EdgeRumCore`, never the other way around.
public struct RecorderUser: Sendable, Hashable {
    public var id: String?
    public var name: String?
    public var email: String?
    public var phone: String?

    public init(
        id: String? = nil,
        name: String? = nil,
        email: String? = nil,
        phone: String? = nil
    ) {
        self.id = id
        self.name = name
        self.email = email
        self.phone = phone
    }
}

/// The single entry point every public API call routes through.
///
/// F2 shipped a no-op Recorder satisfying this protocol so the public
/// surface was exercised by tests but no network I/O happened. F3
/// swaps in the real implementation behind the same interface; the
/// `configure(_:)` requirement has a default no-op so test probes
/// don't need to change.
public protocol Recording: AnyObject, Sendable {
    var isEnabled: Bool { get }
    var currentSessionId: String { get }
    var currentDeviceId: String { get }
    var clock: Clock { get }
    /// `true` when the host passed `EdgeRumConfig.debug = true`. F13's
    /// `AppErrorBuilder` reads this so dropped `NSError.userInfo` keys
    /// are logged in debug-only builds. Default no-op `false` so test
    /// probes that predate F13 don't have to track config state.
    var debug: Bool { get }

    func configure(_ config: RecorderConfig)
    func start(apiKey: String, endpoint: URL, debug: Bool)
    func stop()
    func setEnabled(_ enabled: Bool)

    func recordEvent(name: String, attributes: [String: AttributeValue])
    func recordPerformance(name: String, attributes: [String: AttributeValue])

    func setUser(_ user: RecorderUser)

    /// Update the in-memory `NetworkContext` so subsequent events
    /// carry the new `network.type` / `network.effectiveType`.
    /// F11's `NetworkPathCapture` calls this on every NWPath transition.
    func refreshNetworkContext(_ context: NetworkContext)

    /// Forward an offline-queue drain request to the installed
    /// transport. Called from `EdgeRum.enable()` and F11's
    /// `didBecomeActive` lifecycle hook.
    func drainOfflineQueue()
}

public extension Recording {
    /// Default — test probes that don't need to react to configuration
    /// inherit a no-op. The real `Recorder` overrides this.
    func configure(_ config: RecorderConfig) {
        _ = config
    }

    /// Default — test probes that don't track host config inherit
    /// `debug == false`. The real `Recorder` overrides this.
    var debug: Bool { false }

    /// Default no-op so existing test probes don't have to adopt the
    /// new requirement. The real `Recorder` overrides this.
    func refreshNetworkContext(_ context: NetworkContext) {
        _ = context
    }

    /// Default no-op so existing test probes don't have to adopt the
    /// new requirement. The real `Recorder` overrides this.
    func drainOfflineQueue() { }
}
