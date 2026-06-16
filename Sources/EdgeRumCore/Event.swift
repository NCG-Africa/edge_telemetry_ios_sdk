// Sources/EdgeRumCore/Event.swift
//
// Internal in-memory representation of a single item inside an
// outbound batch. Two flavours:
//
//   .event(name:timestamp:attributes:)
//       — wire `type = "event"`, `eventName = name`.
//
//   .metric(name:value:timestamp:attributes:)
//       — wire `type = "metric"`, `metricName = name`.
//       `value` is encoded as `value` when non-nil and omitted when
//       nil (some metrics expose multiple values via attributes
//       instead of a single scalar).
//
// Encoding happens in `EventEnvelope.swift` so all wire-shape
// decisions live in one file.
//
// Refs: PLAN-iOS.md §7.3 (event), §7.4 (metric); CLAUDE.md "Wire
//       contract pinned facts".
//

import Foundation

public enum Event: Sendable, Hashable {

    case event(name: String, timestamp: Date, attributes: AttributeBag)
    case metric(name: String, value: Double?, timestamp: Date, attributes: AttributeBag)

    public var timestamp: Date {
        switch self {
        case .event(_, let t, _), .metric(_, _, let t, _):
            return t
        }
    }

    public var name: String {
        switch self {
        case .event(let n, _, _), .metric(let n, _, _, _):
            return n
        }
    }

    public var attributes: AttributeBag {
        switch self {
        case .event(_, _, let a), .metric(_, _, _, let a):
            return a
        }
    }

    /// Returns a new `Event` of the same kind with `attributes`
    /// replaced. The Recorder uses this after merging context into the
    /// event-supplied attribute bag.
    public func withAttributes(_ attributes: AttributeBag) -> Event {
        switch self {
        case .event(let name, let timestamp, _):
            return .event(name: name, timestamp: timestamp, attributes: attributes)
        case .metric(let name, let value, let timestamp, _):
            return .metric(name: name, value: value, timestamp: timestamp, attributes: attributes)
        }
    }
}
