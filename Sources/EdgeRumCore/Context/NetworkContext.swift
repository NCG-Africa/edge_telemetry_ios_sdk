// Sources/EdgeRumCore/Context/NetworkContext.swift
//
// Snapshot of the active network path. Wraps `NWPathMonitor` so the
// `ContextProvider` is updated whenever the path transitions; the
// stored snapshot is what `Recorder.recordEvent` merges in.
//
// Wire keys (CLAUDE.md):
//   network.type             — "wifi" / "cellular" / "wired" / "none" / "unknown"
//   network.effectiveType    — best-effort radio access tech on iOS
//                              ("2g" / "3g" / "4g" / "5g" / "wifi" / "unknown")
//
// `effectiveType` is "best-effort on iOS" per CLAUDE.md "Required
// identity attributes". For Wi-Fi paths we report `"wifi"`. For
// cellular we'd need `CTTelephonyNetworkInfo` (which is iOS-only and
// adds Core Telephony as a dependency surface); F3 returns "cellular"
// for cellular paths and leaves a TODO comment for the CT-based
// refinement to land in F8.
//
// Refs: PLAN-iOS.md §7.5, §F3/T3.3.
//

import Foundation
import Network

public struct NetworkContext: Sendable, Hashable {

    public enum NetworkType: String, Sendable, Hashable {
        case wifi
        case cellular
        case wired
        case none
        case unknown
    }

    public var type: NetworkType
    public var effectiveType: String

    public init(type: NetworkType = .unknown, effectiveType: String = "unknown") {
        self.type = type
        self.effectiveType = effectiveType
    }

    public func write(into bag: inout AttributeBag) {
        bag.set("network.type", .string(type.rawValue))
        bag.set("network.effectiveType", .string(effectiveType))
    }

    /// Map a `Network.framework` `NWPath` to our wire representation.
    public static func from(_ path: NWPath) -> NetworkContext {
        guard path.status == .satisfied else {
            return NetworkContext(type: .none, effectiveType: "unknown")
        }
        if path.usesInterfaceType(.wifi) {
            return NetworkContext(type: .wifi, effectiveType: "wifi")
        }
        if path.usesInterfaceType(.cellular) {
            // F8 refines effectiveType from `CTTelephonyNetworkInfo`.
            return NetworkContext(type: .cellular, effectiveType: "cellular")
        }
        if path.usesInterfaceType(.wiredEthernet) {
            return NetworkContext(type: .wired, effectiveType: "wired")
        }
        return NetworkContext(type: .unknown, effectiveType: "unknown")
    }
}

/// Long-lived `NWPathMonitor` wrapper. Owned by the `ContextProvider`;
/// invokes its callback on every path transition so the merged
/// context bag stays current.
///
/// The callback receives both the wire-shape `NetworkContext` and the
/// raw `NWPath` so call-sites that only need the wire snapshot can
/// ignore the path arg, while F11's `NetworkPathCapture` can read
/// `isExpensive` / `isConstrained` / `unsatisfiedReason` (iOS 14.2+)
/// off the same transition without instantiating a second monitor.
public final class NetworkPathObserver: @unchecked Sendable {

    private let monitor: NWPathMonitor
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var _onChange: ((NetworkContext, NWPath) -> Void)?

    public init(queue: DispatchQueue = DispatchQueue(label: "edge.rum.network", qos: .utility)) {
        self.monitor = NWPathMonitor()
        self.queue = queue
    }

    public func start(onChange: @escaping (NetworkContext, NWPath) -> Void) {
        lock.lock(); _onChange = onChange; lock.unlock()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            let callback = self._onChange
            self.lock.unlock()
            callback?(NetworkContext.from(path), path)
        }
        monitor.start(queue: queue)
    }

    public func stop() {
        monitor.pathUpdateHandler = nil
        monitor.cancel()
        lock.lock(); _onChange = nil; lock.unlock()
    }

    /// Synchronously snapshot the current path. Returns `.unknown`
    /// until the monitor has produced its first update.
    public var currentSnapshot: NetworkContext {
        NetworkContext.from(monitor.currentPath)
    }
}
