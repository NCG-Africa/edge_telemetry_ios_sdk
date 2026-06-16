// Sources/EdgeRum/UserContext.swift
//
// Refs: PLAN-iOS.md §3.2, §F2/T2.4; CLAUDE.md "Required identity
//       attributes" (`user.id`, `user.name`, `user.email`, `user.phone`).
//

import Foundation

/// A host-app identifier attached to subsequent events via
/// `EdgeRum.identify(_:)`.
///
/// All fields are optional. The SDK never sends a host-app user
/// identifier as the `user.id` wire attribute on its own — the SDK
/// already owns an anonymous `user.id` (see `EdgeRum.deviceId` /
/// `EdgeRum.sessionId` documentation). The values supplied here are
/// emitted as separate `user.*` attributes alongside the SDK-owned
/// anonymous id.
///
/// `UserContext` is `Sendable` + `Hashable` so it can be stored,
/// compared, and passed across actor boundaries.
public struct UserContext: Sendable, Hashable {
    /// The host app's user identifier, if known.
    public var id: String?

    /// Optional display name.
    public var name: String?

    /// Optional email address.
    public var email: String?

    /// Optional phone number.
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
