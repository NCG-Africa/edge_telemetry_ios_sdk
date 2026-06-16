// Sources/EdgeRum/AttributeValue.swift
//
// Public re-export of the sealed-enum attribute type. The actual enum
// is declared in `EdgeRumCore` so the internal Recorder protocol can
// take it without a back-edge on the public umbrella module.
//
// Refs: PLAN-iOS.md §3.2, §F2/T2.3.
//

import EdgeRumCore

/// A single value that may travel as an event attribute on the wire.
///
/// One of four primitive cases — `.string`, `.int`, `.double`, `.bool`
/// — matching the JSON wire contract exactly. The four
/// `ExpressibleBy…Literal` conformances let callers write attributes
/// as plain literals:
///
/// ```swift
/// EdgeRum.track("checkout_started", attributes: [
///     "cart.size": 3,        // .int(3)
///     "cart.total": 49.95,   // .double(49.95)
///     "user.is_member": true // .bool(true)
/// ])
/// ```
public typealias AttributeValue = EdgeRumCore.AttributeValue
