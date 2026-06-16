// Sources/EdgeRumCore/AttributeValue.swift
//
// Defined inside EdgeRumCore (not EdgeRum) so the internal `Recording`
// protocol can take `[String: AttributeValue]` without introducing a
// dependency edge back onto the public umbrella module. The public
// `EdgeRum` module re-exports the same enum through a thin typealias
// so consumers continue to write `AttributeValue.string(...)`.
//
// Refs: PLAN-iOS.md §3.2 (sealed enum), §F2/T2.3, CLAUDE.md
//       "Attributes passed to the Recorder are always
//       `[String: AttributeValue]` — never `[String: Any]`."
//

import Foundation

/// A single value that may travel as an event attribute on the wire.
///
/// The four cases are the only primitive types the JSON wire contract
/// accepts (`String`, `Int`, `Double`, `Bool`). Because the enum is
/// sealed and the public API everywhere demands
/// `[String: AttributeValue]`, the compiler — not a runtime check —
/// guarantees that no other type can ever reach the encoder.
///
/// Literal conformances let callers write attributes naturally:
///
/// ```swift
/// EdgeRum.track("checkout_started", attributes: [
///     "cart.size": 3,
///     "cart.total": 49.95,
///     "user.is_member": true,
///     "ab.bucket": "treatment"
/// ])
/// ```
public enum AttributeValue: Sendable, Hashable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
}

extension AttributeValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension AttributeValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self = .int(value)
    }
}

extension AttributeValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self = .double(value)
    }
}

extension AttributeValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}
