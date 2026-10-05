// Sources/EdgeRumCore/HostAttributes.swift
//
// F29 — reserved namespaces. Host-supplied attribute keys under an SDK
// prefix (`device.`, `user.`, `session.` …) are dropped at the public
// entry so a host key can never shadow or forge an SDK key. The drop is
// counted on the event as `host_attributes.dropped` (catalogue §0
// clause 8: integer, omitted when zero) and logged under `debug`.
//
// Refs: docs/specs/rum-coverage-roadmap.md tranche 4 "Namespaces";
//       docs/catalogue/ios-data-catalogue.md §5.15.

import Foundation
import os.log

public enum HostAttributes {

    /// Prefixes the SDK owns. A host key starting with any of these is
    /// dropped.
    public static let reservedPrefixes: [String] = [
        "app.", "device.", "network.", "session.", "user.", "sdk.",
        "navigation.", "interaction.", "http.", "resource.", "crash.",
        "error.", "hang.", "action.", "trace.", "span.", "rum.", "screen.",
        "lifecycle.", "page_load.", "launch.", "long_task.", "frame.",
        "memory.", "cpu.", "timer.", "event.", "breadcrumb.",
        "previous_session.", "traceparent.", "host_attributes."
    ]

    /// The event-level count of host keys dropped by the rule.
    public static let droppedKey = "host_attributes.dropped"

    private static let log = OSLog(subsystem: "com.edge.rum", category: "HostAttributes")

    /// `attributes` minus every key under a reserved prefix, plus
    /// `host_attributes.dropped` when anything was dropped.
    public static func sanitize(_ attributes: [String: AttributeValue]?, debug: Bool) -> [String: AttributeValue] {
        guard let attributes else { return [:] }
        var kept: [String: AttributeValue] = [:]
        var dropped = 0
        for (key, value) in attributes {
            if reservedPrefixes.contains(where: key.hasPrefix) {
                dropped += 1
                if debug {
                    os_log("dropped host attribute %{public}@: reserved prefix", log: log, type: .info, key)
                }
            } else {
                kept[key] = value
            }
        }
        if dropped > 0 { kept[droppedKey] = .int(dropped) }
        return kept
    }
}
