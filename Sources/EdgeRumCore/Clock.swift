// Sources/EdgeRumCore/Clock.swift
//
// Internal time abstraction. `RumTimer` consumes a `Clock` so unit
// tests can pin "now" to a frozen value. The Recorder façade in F3
// uses the same protocol; injected `FixedClock` lets contract tests
// snapshot the envelope timestamp at a known instant.
//
// Refs: PLAN-iOS.md §F2/T2.5 ("Start moment from injectable Clock"),
//       §F3/T3.4 (Clock protocol; SystemClock for prod, FixedClock
//       for tests).
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

/// Test-only `Clock` that returns a frozen instant until `advance`
/// or `set` is called. Issue #39 acceptance: "FixedClock for tests".
public final class FixedClock: Clock, @unchecked Sendable {

    private let lock = NSLock()
    private var _now: Date

    public init(_ now: Date) {
        self._now = now
    }

    public var now: Date {
        lock.lock(); defer { lock.unlock() }
        return _now
    }

    public func advance(by interval: TimeInterval) {
        lock.lock(); _now = _now.addingTimeInterval(interval); lock.unlock()
    }

    public func set(_ date: Date) {
        lock.lock(); _now = date; lock.unlock()
    }
}
