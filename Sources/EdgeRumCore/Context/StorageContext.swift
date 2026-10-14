// Sources/EdgeRumCore/Context/StorageContext.swift
//
// F16/T16.4 — background-refresh status carried on every event so
// the backend can correlate "refresh denied" with crash & hang patterns.
//
// Wire key (docs/data-flow.md §3.2):
//   app.background_refresh  — `UIApplication.backgroundRefreshStatus`
//                              ("available" / "denied" / "restricted"
//                               / "unknown")
//
// `device.disk_free_mb` / `device.disk_total_mb` were removed (#254,
// SDK-008): every disk-space required reason (E174.1, 85F4.1, 7D9E.1)
// forbids sending the value off-device.
//
// Refresh: seeded at install, then on
// `UIApplication.backgroundRefreshStatusDidChangeNotification`
// (`ContextObservers`).
//
// Refs: PLAN-iOS.md §16.4 / F16 / T16.4.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

public struct StorageContext: Sendable, Hashable {

    public var backgroundRefresh: String?

    public init(backgroundRefresh: String? = nil) {
        self.backgroundRefresh = backgroundRefresh
    }

    public static func snapshot() -> StorageContext {
        StorageContext(backgroundRefresh: readBackgroundRefresh())
    }

    public func write(into bag: inout AttributeBag) {
        bag.setIfPresent("app.background_refresh", backgroundRefresh.map { .string($0) })
    }

    /// Map `UIBackgroundRefreshStatus` to the wire string. Returns
    /// `nil` on non-UIKit hosts (tests / macOS CI).
    internal static func readBackgroundRefresh() -> String? {
        #if canImport(UIKit)
        if Thread.isMainThread {
            return backgroundRefreshStringOnMain()
        }
        var result: String?
        DispatchQueue.main.sync { result = backgroundRefreshStringOnMain() }
        return result
        #else
        return nil
        #endif
    }

    #if canImport(UIKit)
    /// Pure mapping `UIBackgroundRefreshStatus → wire string`.
    /// Exposed internal so `StorageContextTests` can drive every case.
    internal static func backgroundRefreshString(_ status: UIBackgroundRefreshStatus) -> String {
        switch status {
        case .available: return "available"
        case .denied: return "denied"
        case .restricted: return "restricted"
        @unknown default: return "unknown"
        }
    }
    #endif
}

#if canImport(UIKit)
private func backgroundRefreshStringOnMain() -> String {
    return StorageContext.backgroundRefreshString(UIApplication.shared.backgroundRefreshStatus)
}
#endif
