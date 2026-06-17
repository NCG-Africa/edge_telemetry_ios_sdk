// Sources/EdgeRumCore/Context/StorageContext.swift
//
// F16/T16.4 — disk capacity + background-refresh status carried on
// every event so the backend can correlate "out of disk" / "refresh
// denied" with crash & hang patterns.
//
// Wire keys (docs/data-flow.md §3.1 / §3.2):
//   device.disk_free_mb     — `FileManager.attributesOfFileSystem(forPath:)`
//                              `.systemFreeSize` ÷ 1 048 576
//   device.disk_total_mb    — same dict's `.systemSize` ÷ 1 048 576
//   app.background_refresh  — `UIApplication.backgroundRefreshStatus`
//                              ("available" / "denied" / "restricted"
//                               / "unknown")
//
// Refresh strategy: `ContextObservers` arms a 5-minute
// `DispatchSource.makeTimerSource` (mirrors `MemorySampler`'s
// utility-queue timer) that calls `provider.refreshStorage(.snapshot())`.
// The timer is suspended on `willResignActive` and resumed on
// `didBecomeActive` so we don't run statfs in the background.
//
// Refs: PLAN-iOS.md §16.4 / F16 / T16.4.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

public struct StorageContext: Sendable, Hashable {

    public var diskFreeMb: Int?
    public var diskTotalMb: Int?
    public var backgroundRefresh: String?

    public init(
        diskFreeMb: Int? = nil,
        diskTotalMb: Int? = nil,
        backgroundRefresh: String? = nil
    ) {
        self.diskFreeMb = diskFreeMb
        self.diskTotalMb = diskTotalMb
        self.backgroundRefresh = backgroundRefresh
    }

    public static func snapshot() -> StorageContext {
        let (free, total) = readDiskMB()
        let refresh = readBackgroundRefresh()
        return StorageContext(
            diskFreeMb: free,
            diskTotalMb: total,
            backgroundRefresh: refresh
        )
    }

    public func write(into bag: inout AttributeBag) {
        bag.setIfPresent("device.disk_free_mb", diskFreeMb.map { .int($0) })
        bag.setIfPresent("device.disk_total_mb", diskTotalMb.map { .int($0) })
        bag.setIfPresent("app.background_refresh", backgroundRefresh.map { .string($0) })
    }

    /// Read free + total bytes from the home-directory volume and
    /// convert to whole megabytes. Returns `(nil, nil)` if the
    /// `FileManager` query throws — we never surface a partial value.
    internal static func readDiskMB() -> (Int?, Int?) {
        let path = NSHomeDirectory()
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path) else {
            return (nil, nil)
        }
        let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value
        let total = (attrs[.systemSize] as? NSNumber)?.int64Value
        let mb: (Int64) -> Int = { bytes in
            Int(bytes / 1_048_576)
        }
        return (free.map(mb), total.map(mb))
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
