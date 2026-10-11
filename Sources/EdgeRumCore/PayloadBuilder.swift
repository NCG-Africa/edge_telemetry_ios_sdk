// Sources/EdgeRumCore/PayloadBuilder.swift
//
// Assembles a `telemetry_batch` envelope from buffered events + the
// current context bag. Stamps the outer batch `timestamp` at *build
// time*, not enqueue time (issue #40 acceptance).
//
// Contract 4.0 (#250, R1): the identity (`app.*` identity keys,
// `sdk.*`, `device.id`) is lifted from the context bag into the
// envelope and stripped from every event — context-supplied and
// event-supplied alike, so the envelope always wins. Every other
// context attribute is merged into each event, event attrs winning.
//
// Refs: #250; PLAN-iOS.md §7.2 (envelope), §F3/T3.5.
//

import Foundation

public struct PayloadBuilder: Sendable {

    /// `app.*` keys that are identity (envelope-only). Other `app.*`
    /// keys (`app.state`, `app.background_refresh`) are event data.
    public static let appIdentityKeys: Set<String> = [
        "app.name", "app.package_name", "app.version", "app.build_number",
        "app.platform", "app.environment"
    ]

    /// `true` for a key that must never ride an event (R1).
    public static func isIdentityKey(_ key: String) -> Bool {
        key == "device.id" || key.hasPrefix("sdk.") || appIdentityKeys.contains(key)
    }

    /// The SDK's own health event: built here, never through
    /// `recordEvent`, so it bypasses the allowlist and the sampler.
    public static let healthEventName = "sdk.health"

    public init() {}

    /// Build a `telemetry_batch` envelope.
    ///
    /// - Parameters:
    ///   - events: events buffered by the `Recorder`.
    ///   - context: attribute bag from `ContextProvider.snapshot()`
    ///     captured at flush time. Its identity keys fill the envelope;
    ///     the rest is merged into every event (event attrs win).
    ///   - flushTime: stamped as the envelope `timestamp` and the
    ///     `sdk.health` event's.
    ///   - health: SDK health counters (no `sdk.` prefix). Non-nil
    ///     appends one `sdk.health` event, last (R4); it carries the
    ///     same non-identity context as every other event.
    ///   - app: overrides the context's `app.*` identity — the saved
    ///     build of a replayed crash or hang (R14).
    public func build(
        events: [Event],
        context: AttributeBag,
        flushTime: Date,
        health: [String: AttributeValue]? = nil,
        app: AppContext? = nil
    ) -> EventEnvelope {
        var events = events
        if let health {
            events.append(.event(name: Self.healthEventName, timestamp: flushTime, attributes: AttributeBag(health)))
        }
        let enriched = events.map { event -> Event in
            let merged = context.values.merging(event.attributes.values) { _, own in own }
            return event.withAttributes(AttributeBag(merged.filter { !Self.isIdentityKey($0.key) }))
        }
        return EventEnvelope(
            timestamp: flushTime,
            deviceId: Self.string(context["device.id"]) ?? "",
            sdkVersion: Self.string(context["sdk.version"]) ?? "",
            app: app ?? AppContext(
                name: Self.string(context["app.name"]),
                packageName: Self.string(context["app.package_name"]),
                version: Self.string(context["app.version"]),
                buildNumber: Self.string(context["app.build_number"])
            ),
            events: enriched
        )
    }

    private static func string(_ value: AttributeValue?) -> String? {
        guard case let .string(s)? = value else { return nil }
        return s
    }
}
