// Sources/EdgeRumCore/Clock.swift
//
// Internal time abstraction. `RumTimer` consumes a `Clock` so unit
// tests can pin "now" to a frozen value. The real Recorder façade in
// F3 will reuse the same protocol.
//
// Refs: PLAN-iOS.md §F2/T2.5 ("Start moment from injectable Clock").
//

import Foundation

// EdgeRumCore is not a SwiftPM product (see Package.swift) so making
// these types `public` exposes them only to the other internal
// targets that depend on EdgeRumCore — never to outside consumers.
public protocol Clock: Sendable {
    var now: Date { get }
}

public struct SystemClock: Clock {
    public init() {}
    public var now: Date { Date() }
}
