// Sources/EdgeRumCore/EventEnvelope.swift
//
// The wire envelope, contract 4.0.0 (#250). Closed at exactly eight
// root keys (R3):
//
//     {
//       "type": "telemetry_batch",
//       "contract_version": "4.0.0",
//       "timestamp": "<ISO 8601 UTC + fractional seconds, Z>",
//       "batch_size": <events.count>,
//       "device_id": "device_<epochMs>_<16 hex>_ios",
//       "sdk": { "name": "ios", "version": "<sdk version>" },
//       "app": { "name"?, "package_name", "platform": "ios",
//                "version"?, "build_number"? },
//       "events": [ ... ]
//     }
//
// Identity lives here only (R1); `PayloadBuilder` strips it from
// events. A nil `app` value is omitted, never `""` (R15).
//
// Per-item shapes (event vs metric) are encoded inline below so all
// wire decisions live in one file.
//
// Timestamps are encoded manually via `ISO8601DateFormatter` with
// `[.withInternetDateTime, .withFractionalSeconds]`. We deliberately
// do NOT use `JSONEncoder.dateEncodingStrategy = .iso8601` because
// the strategy omits fractional seconds on older runtimes and we
// must always send `.SSS`.
//
// Refs: #250; CLAUDE.md "Wire contract pinned facts".
//

import Foundation

/// Outer `telemetry_batch` envelope. `Encodable` only — the SDK never
/// deserialises envelopes it produced.
public struct EventEnvelope: Sendable, Encodable {

    /// The batch contract this envelope speaks (R11, S1).
    public static let contractVersion = "4.0.0"
    /// `sdk.name` (R2).
    public static let sdkName = "ios"
    /// `app.platform` (R2).
    public static let appPlatform = "ios"

    /// Always the literal `"telemetry_batch"`.
    public let type: String
    public let timestamp: Date
    public let batchSize: Int
    public let deviceId: String
    public let sdkVersion: String
    public let app: AppContext
    public let events: [Event]

    public init(
        timestamp: Date,
        deviceId: String,
        sdkVersion: String,
        app: AppContext,
        events: [Event]
    ) {
        self.type = "telemetry_batch"
        self.timestamp = timestamp
        self.batchSize = events.count
        self.deviceId = deviceId
        self.sdkVersion = sdkVersion
        self.app = app
        self.events = events
    }

    /// The events the host recorded: `events` minus the `sdk.health`
    /// event.
    public var recordedEvents: [Event] {
        events.filter { $0.name != PayloadBuilder.healthEventName }
    }

    /// `batch_size` minus the `sdk.health` event, so `events_uploaded`
    /// keeps its meaning.
    public var recordedEventCount: Int { recordedEvents.count }

    private enum CodingKeys: String, CodingKey {
        case type
        case contractVersion = "contract_version"
        case timestamp
        case batchSize = "batch_size"
        case deviceId = "device_id"
        case sdk
        case app
        case events
    }

    /// R13: replace the root `timestamp` of an encoded 4.x payload with
    /// `date`, leaving every other byte alone (a JSON round-trip would
    /// rewrite doubles). Relies on `.sortedKeys` encoding: the root
    /// `timestamp` sorts after `events` and `sdk`, so it is the last
    /// `"timestamp":"` in the payload — inside a string value the
    /// quotes would be escaped. A legacy (pre-4.0) payload, with no
    /// guaranteed key order, is returned unchanged.
    public static func restamp(_ payload: Data, at date: Date) -> Data {
        guard payload.range(of: Data(#""contract_version":"4."#.utf8)) != nil,
              let key = payload.range(of: Data(#""timestamp":""#.utf8), options: .backwards),
              let end = payload[key.upperBound...].firstIndex(of: UInt8(ascii: "\"")) else {
            return payload
        }
        var out = payload
        out.replaceSubrange(key.upperBound..<end, with: Data(WireDateFormatter.string(from: date).utf8))
        return out
    }

    private enum SdkKeys: String, CodingKey { case name, version }

    private enum AppKeys: String, CodingKey {
        case name
        case packageName = "package_name"
        case platform
        case version
        case buildNumber = "build_number"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(Self.contractVersion, forKey: .contractVersion)
        try c.encode(WireDateFormatter.string(from: timestamp), forKey: .timestamp)
        try c.encode(batchSize, forKey: .batchSize)
        try c.encode(deviceId, forKey: .deviceId)
        var sdk = c.nestedContainer(keyedBy: SdkKeys.self, forKey: .sdk)
        try sdk.encode(Self.sdkName, forKey: .name)
        try sdk.encode(sdkVersion, forKey: .version)
        var a = c.nestedContainer(keyedBy: AppKeys.self, forKey: .app)
        try a.encodeIfPresent(app.name, forKey: .name)
        try a.encodeIfPresent(app.packageName, forKey: .packageName)
        try a.encode(Self.appPlatform, forKey: .platform)
        try a.encodeIfPresent(app.version, forKey: .version)
        try a.encodeIfPresent(app.buildNumber, forKey: .buildNumber)
        try c.encode(events, forKey: .events)
    }
}

extension Event: Encodable {

    private enum CodingKeys: String, CodingKey {
        case type
        case eventName
        case metricName
        case value
        case timestamp
        case attributes
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .event(let name, let timestamp, let attributes):
            try c.encode("event", forKey: .type)
            try c.encode(name, forKey: .eventName)
            try c.encode(WireDateFormatter.string(from: timestamp), forKey: .timestamp)
            try c.encode(attributes.values, forKey: .attributes)
        case .metric(let name, let value, let timestamp, let attributes):
            try c.encode("metric", forKey: .type)
            try c.encode(name, forKey: .metricName)
            try c.encodeIfPresent(value, forKey: .value)
            try c.encode(WireDateFormatter.string(from: timestamp), forKey: .timestamp)
            try c.encode(attributes.values, forKey: .attributes)
        }
    }
}

/// Thread-safe ISO 8601 formatter shared across the package.
///
/// `ISO8601DateFormatter` is documented thread-safe (the bridged
/// formatter is) so one shared instance is fine. Exposed at module
/// scope so the contract test suite can call it directly.
public enum WireDateFormatter {

    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    public static func date(from string: String) -> Date? {
        formatter.date(from: string)
    }
}
