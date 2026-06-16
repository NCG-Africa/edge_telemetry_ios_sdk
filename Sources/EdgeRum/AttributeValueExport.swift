// Sources/EdgeRum/AttributeValueExport.swift
//
// Public re-export of the sealed-enum attribute type. The actual enum
// is declared in `EdgeRumCore` so the internal Recorder protocol can
// take it without a back-edge on the public umbrella module.
//
// File is named `AttributeValueExport.swift` (not `AttributeValue.swift`)
// because CocoaPods rolls every subspec into one Pods target and two
// Swift files sharing a basename inside a single target fail
// `pod lib lint` with "Filename used twice". The exported Swift
// symbol is still `AttributeValue` via the typealias below.
//
// Under SwiftPM: `EdgeRumCore` is a real module so we import it and
// publish a typealias. Under CocoaPods every subspec rolls into a
// single `EdgeRum` module — the enum from
// `Sources/EdgeRumCore/AttributeValue.swift` is already public in
// that module, so the typealias would be a self-referential cycle.
// The `#if canImport(EdgeRumCore)` guard makes the file a no-op
// under CocoaPods and active under SwiftPM. Consumers write
// `AttributeValue` in both worlds.
//
// Refs: PLAN-iOS.md §3.2, §F2/T2.3.
//

#if canImport(EdgeRumCore)
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
#endif
