// Sources/EdgeRumCore/Recording.swift
//
// Internal seam for the public `EdgeRum` namespace. F2's job is to
// stand up the public surface; F3 lands the real Recorder. By routing
// every public method through this protocol now, F3 swaps in the real
// implementation without touching `Sources/EdgeRum/`.
//
// Refs: PLAN-iOS.md §F2/T2.1 ("Route every call to internal Recorder
// via a stored singleton"), §F3.
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
/// F2 ships a no-op `Recorder` that satisfies this protocol so the
/// public surface is exercised by tests but no network I/O happens.
/// F3 swaps in the real implementation behind the same interface.
public protocol Recording: AnyObject, Sendable {
    var isEnabled: Bool { get }
    var currentSessionId: String { get }
    var currentDeviceId: String { get }
    var clock: Clock { get }

    func start(apiKey: String, endpoint: URL, debug: Bool)
    func stop()
    func setEnabled(_ enabled: Bool)

    func recordEvent(name: String, attributes: [String: AttributeValue])
    func recordPerformance(name: String, attributes: [String: AttributeValue])
    func recordError(domain: String, code: Int, message: String?, context: [String: AttributeValue])

    func setUser(_ user: RecorderUser)
}
