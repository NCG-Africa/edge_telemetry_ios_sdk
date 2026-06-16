// Internal — invisible from `import EdgeRum`.
//
// `OTelToRecorderAdapter` (the SpanProcessor/LogRecordProcessor that
// funnels OTel data into our Recorder) lands with F3. This stub exercises
// the `opentelemetry-swift-core` source dependency at F1 build time so
// resolver / link / SDK-version mismatches fail here, not later.
//
// `@_implementationOnly` keeps every OTel symbol invisible from the
// public `EdgeRum` module (terminology firewall — CLAUDE.md Rule 1).

import Foundation
@_implementationOnly import OpenTelemetryApi
@_implementationOnly import OpenTelemetrySdk

internal enum EdgeRumOTelBridgeModuleStub {
    internal static let marker: String = "EdgeRumOTelBridge"
}
