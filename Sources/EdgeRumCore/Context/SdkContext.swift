// Sources/EdgeRumCore/Context/SdkContext.swift
//
// The SDK version, sourced from the build-plugin-generated string in
// the public umbrella module and handed down via
// `RecorderConfig.sdkVersion` so EdgeRumCore stays free of an upward
// dependency on EdgeRum.
//
// Contract 4.0 (#250): `sdk.version` and `device.id` ride the envelope
// (`sdk.version`, `device_id`), never an event; `sdk.name = "ios"` is
// a literal in `EventEnvelope`.
//
// Refs: PLAN-iOS.md §7.5; CLAUDE.md "Required identity attributes".
//

import Foundation

public struct SdkContext: Sendable, Hashable {

    public let version: String

    public init(version: String) {
        self.version = version
    }

    public func write(into bag: inout AttributeBag) {
        bag.set("sdk.version", .string(version))
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
