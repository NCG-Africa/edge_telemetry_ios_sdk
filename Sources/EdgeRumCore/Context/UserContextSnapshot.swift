// Sources/EdgeRumCore/Context/UserContextSnapshot.swift
//
// SDK-owned anonymous user identity + optional host-supplied fields
// from `EdgeRum.identify(_:)`. The SDK-owned `user.id` survives
// `identify()` calls — `identify()` only attaches the optional
// `user.name`/`user.email`/`user.phone` keys.
//
// Wire keys:
//   user.id     — "user_<epochMs>_<16 hex>"  (NO `_ios` suffix)
//   user.name   — optional, host-supplied
//   user.email  — optional, host-supplied
//   user.phone  — optional, host-supplied
//
// Refs: CLAUDE.md "Session and ID rules", PLAN-iOS.md §7.5, §F3/T3.3.
//

import Foundation

public struct UserContextSnapshot: Sendable, Hashable {

    public let id: String
    public var name: String?
    public var email: String?
    public var phone: String?

    public init(
        id: String,
        name: String? = nil,
        email: String? = nil,
        phone: String? = nil
    ) {
        self.id = id
        self.name = name
        self.email = email
        self.phone = phone
    }

    public func write(into bag: inout AttributeBag) {
        bag.set("user.id", .string(id))
        bag.setIfPresent("user.name", name.map { .string($0) })
        bag.setIfPresent("user.email", email.map { .string($0) })
        bag.setIfPresent("user.phone", phone.map { .string($0) })
    }

    /// `user_<epochMs>_<16 hex>` — no `_ios` suffix.
    public static func newAnonymousId(
        at now: Date = Date(),
        randomBytes: () -> Data = SessionManager.secureRandomBytes
    ) -> String {
        let epochMs = Int64(now.timeIntervalSince1970 * 1000)
        let hex = randomBytes().prefix(8).map { String(format: "%02x", $0) }.joined()
        let padded = hex.padding(toLength: 16, withPad: "0", startingAt: 0)
        return "user_\(epochMs)_\(padded)"
    }

    /// Merge optional host-supplied fields from `RecorderUser` while
    /// keeping the existing SDK-owned `id`.
    public func merging(_ user: RecorderUser) -> UserContextSnapshot {
        UserContextSnapshot(
            id: id,
            name: user.name ?? name,
            email: user.email ?? email,
            phone: user.phone ?? phone
        )
    }
}
