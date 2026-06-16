// Sources/EdgeRumCore/EventEnvelope.swift
//
// The wire envelope. Matches the JSON shape in PLAN-iOS.md §7.2 and
// docs/payload-example.jsonc verbatim:
//
//     {
//       "type": "telemetry_batch",
//       "timestamp": "<ISO 8601 + fractional seconds>",
//       "location": "City/Country",          // optional, omitted when nil
//       "batch_size": <events.count>,
//       "events": [ ... ]
//     }
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
// Refs: PLAN-iOS.md §7.2, §7.3, §7.4; CLAUDE.md "Wire contract
//       pinned facts".
//

import Foundation

/// Outer `telemetry_batch` envelope. `Encodable` only — the SDK never
/// deserialises envelopes it produced.
public struct EventEnvelope: Sendable, Encodable {

    /// Always the literal `"telemetry_batch"`.
    public let type: String
    public let timestamp: Date
    public let location: String?
    public let batchSize: Int
    public let events: [Event]

    public init(timestamp: Date, location: String?, events: [Event]) {
        self.type = "telemetry_batch"
        self.timestamp = timestamp
        self.location = location
        self.batchSize = events.count
        self.events = events
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case timestamp
        case location
        case batchSize = "batch_size"
        case events
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(WireDateFormatter.string(from: timestamp), forKey: .timestamp)
        try c.encodeIfPresent(location, forKey: .location)
        try c.encode(batchSize, forKey: .batchSize)
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
