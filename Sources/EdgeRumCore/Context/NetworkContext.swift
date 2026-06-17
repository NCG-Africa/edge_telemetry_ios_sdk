// Sources/EdgeRumCore/Context/NetworkContext.swift
//
// Snapshot of the active network path. Wraps `NWPathMonitor` so the
// `ContextProvider` is updated whenever the path transitions; the
// stored snapshot is what `Recorder.recordEvent` merges in.
//
// Wire keys (CLAUDE.md / docs/data-flow.md §3.3):
//   network.type             — "wifi" / "cellular" / "wired" / "none" / "unknown"
//   network.effectiveType    — best-effort radio access tech on iOS
//                              ("2g" / "3g" / "4g" / "5g" / "wifi" / "unknown")
//   network.expensive        — NWPath.isExpensive                    (F16/T16.3)
//   network.constrained      — NWPath.isConstrained                  (F16/T16.3)
//   network.interface        — Active NWInterface name (e.g. "en0")  (F16/T16.3)
//
// `effectiveType` is "best-effort on iOS" per CLAUDE.md "Required
// identity attributes". For Wi-Fi paths we report `"wifi"`. For
// cellular we'd need `CTTelephonyNetworkInfo` (which is iOS-only and
// adds Core Telephony as a dependency surface); F3 returns "cellular"
// for cellular paths and leaves a TODO comment for the CT-based
// refinement to land in F8.
//
// Refs: PLAN-iOS.md §7.5, §F3/T3.3, §16.4 / F16; docs/data-flow.md §3.3.
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
    public var isExpensive: Bool
    public var isConstrained: Bool
    public var interface: String?

    public init(
        type: NetworkType = .unknown,
        effectiveType: String = "unknown",
        isExpensive: Bool = false,
        isConstrained: Bool = false,
        interface: String? = nil
    ) {
        self.type = type
        self.effectiveType = effectiveType
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.interface = interface
    }

    public func write(into bag: inout AttributeBag) {
        bag.set("network.type", .string(type.rawValue))
        bag.set("network.effectiveType", .string(effectiveType))
        bag.set("network.expensive", .bool(isExpensive))
        bag.set("network.constrained", .bool(isConstrained))
        bag.setIfPresent("network.interface", interface.map { .string($0) })
    }

    /// Map a `Network.framework` `NWPath` to our wire representation.
    public static func from(_ path: NWPath) -> NetworkContext {
        let isExpensive = path.isExpensive
        let isConstrained: Bool
        if #available(iOS 13.0, macOS 10.15, *) {
            isConstrained = path.isConstrained
        } else {
            isConstrained = false
        }
        let interface = primaryInterfaceName(path)

        guard path.status == .satisfied else {
            return NetworkContext(
                type: .none,
                effectiveType: "unknown",
                isExpensive: isExpensive,
                isConstrained: isConstrained,
                interface: interface
            )
        }
        if path.usesInterfaceType(.wifi) {
            return NetworkContext(
                type: .wifi,
                effectiveType: "wifi",
                isExpensive: isExpensive,
                isConstrained: isConstrained,
                interface: interface
            )
        }
        if path.usesInterfaceType(.cellular) {
            // F8 refines effectiveType from `CTTelephonyNetworkInfo`.
            return NetworkContext(
                type: .cellular,
                effectiveType: "cellular",
                isExpensive: isExpensive,
                isConstrained: isConstrained,
                interface: interface
            )
        }
        if path.usesInterfaceType(.wiredEthernet) {
            return NetworkContext(
                type: .wired,
                effectiveType: "wired",
                isExpensive: isExpensive,
                isConstrained: isConstrained,
                interface: interface
            )
        }
        return NetworkContext(
            type: .unknown,
            effectiveType: "unknown",
            isExpensive: isExpensive,
            isConstrained: isConstrained,
            interface: interface
        )
    }

    /// First available interface name (e.g. `"en0"`, `"pdp_ip0"`),
    /// `nil` when the path reports no available interfaces. F16/T16.3.
    private static func primaryInterfaceName(_ path: NWPath) -> String? {
        // `availableInterfaces` is an `[NWInterface]` ordered by the
        // system's preferred priority. We surface the first one so
        // event consumers know which physical interface served the
        // traffic at emission time.
        guard let first = path.availableInterfaces.first else { return nil }
        return first.name
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
