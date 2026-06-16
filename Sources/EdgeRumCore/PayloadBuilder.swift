// Sources/EdgeRumCore/PayloadBuilder.swift
//
// Assembles a `telemetry_batch` envelope from buffered events + the
// current context bag. Stamps the outer batch `timestamp` at *build
// time*, not enqueue time (issue #40 acceptance).
//
// Per CLAUDE.md "Recorder + transport implementation notes" step 2,
// context attributes are merged into every event with event-supplied
// attributes winning on key conflict.
//
// Refs: PLAN-iOS.md §7.2 (envelope), §F3/T3.5.
//

import Foundation

public struct PayloadBuilder: Sendable {

    public init() {}

    /// Build a `telemetry_batch` envelope.
    ///
    /// - Parameters:
    ///   - events: events buffered by the `Recorder`.
    ///   - context: attribute bag from `ContextProvider.snapshot()`
    ///     captured at flush time. Merged into every event;
    ///     event-supplied attrs win on conflict.
    ///   - location: optional `City/Country` string from
    ///     `EdgeRumConfig.location`. Omitted from the envelope when
    ///     `nil`.
    ///   - flushTime: stamped as the envelope `timestamp`.
    public func build(
        events: [Event],
        context: AttributeBag,
        location: String?,
        flushTime: Date
    ) -> EventEnvelope {
        let enriched = events.map { event -> Event in
            // Context first, event attrs overlaid second → event wins.
            let merged = context.merging(event.attributes)
            return event.withAttributes(merged)
        }
        return EventEnvelope(
            timestamp: flushTime,
            location: location,
            events: enriched
        )
    }
}
