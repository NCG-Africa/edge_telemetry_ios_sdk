// Sources/EdgeRumCore/Context/SdkContext.swift
//
// The two SDK-identity attributes every event carries.
//
// `sdk.version` is sourced from the build-plugin-generated string in
// the public umbrella module. F3 mirrors it via an init-time argument
// so EdgeRumCore stays free of an upward dependency on EdgeRum.
//
// `sdk.platform = "ios-native"` is a NEW value not previously seen by
// the backend. Confirmation that the dispatcher accepts it is the
// first item in PLAN-iOS.md § "Backend asks".
//
// Refs: PLAN-iOS.md §7.5; CLAUDE.md "Required identity attributes".
//

import Foundation

public struct SdkContext: Sendable, Hashable {

    public let version: String
    public let platform: String

    public init(version: String, platform: String = "ios-native") {
        self.version = version
        self.platform = platform
    }

    public func write(into bag: inout AttributeBag) {
        bag.set("sdk.version", .string(version))
        bag.set("sdk.platform", .string(platform))
    }
}

public struct DeviceIdentitySnapshot: Sendable, Hashable {
    public let id: String

    public init(id: String) {
        self.id = id
    }

    public func write(into bag: inout AttributeBag) {
        bag.set("device.id", .string(id))
    }

    /// `device_<epochMs>_<16 hex>_ios` — see CLAUDE.md.
    public static func newId(
        at now: Date = Date(),
        randomBytes: () -> Data = SessionManager.secureRandomBytes
    ) -> String {
        let epochMs = Int64(now.timeIntervalSince1970 * 1000)
        let hex = randomBytes().prefix(8).map { String(format: "%02x", $0) }.joined()
        let padded = hex.padding(toLength: 16, withPad: "0", startingAt: 0)
        return "device_\(epochMs)_\(padded)_ios"
    }
}
