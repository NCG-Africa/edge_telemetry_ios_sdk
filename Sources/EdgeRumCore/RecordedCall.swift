// Sources/EdgeRumCore/RecordedCall.swift
//
// Public enum used by the F2 `ProbeRecorder` test double — left in
// place so existing tests under `Tests/EdgeRumTests/` continue to
// compile unchanged.
//
// The F3 production `Recorder` does NOT accumulate `RecordedCall`s;
// it accumulates `Event`s that the `PayloadBuilder` turns into wire
// envelopes. `RecordedCall` is a test-instrumentation type.
//
// Refs: PLAN-iOS.md §F2/T2.1, §F3/T3.1.
//

import Foundation

/// A single record of an API call routed through the recorder. The
/// probe recorder in `Tests/EdgeRumTests` pattern-matches on these
/// to assert routing behaviour.
public enum RecordedCall: Sendable, Equatable {
    case start(apiKey: String, endpoint: URL, debug: Bool)
    case stop
    case setEnabled(Bool)
    case event(name: String, attributes: [String: AttributeValue])
    case performance(name: String, attributes: [String: AttributeValue])
    case setUser(RecorderUser)
}
