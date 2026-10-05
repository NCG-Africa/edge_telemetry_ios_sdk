// Sources/EdgeRumCore/Context/NetworkContext.swift
//
// Snapshot of the active network path. Wraps `NWPathMonitor` so the
// `ContextProvider` is updated whenever the path transitions; the
// stored snapshot is what `Recorder.recordEvent` merges in.
//
// Wire keys (CLAUDE.md / docs/data-flow.md §3.3):
//   network.type             — "wifi" / "cellular" / "wired" / "none" / "unknown"
//   network.effectiveType    — best-effort radio access tech on iOS
//                              ("2g" / "3g" / "4g" / "5g" / "wifi" / "wired" / "unknown")
//   network.expensive        — NWPath.isExpensive                    (F16/T16.3)
//   network.constrained      — NWPath.isConstrained                  (F16/T16.3)
//   network.interface        — Active NWInterface name (e.g. "en0")  (F16/T16.3)
//
// `effectiveType` is "best-effort on iOS" per CLAUDE.md "Required
// identity attributes". For Wi-Fi paths we report `"wifi"`. For
// cellular paths we report the radio generation read from
// `CTTelephonyNetworkInfo` (F35, roadmap tranche 10) — never
// `"cellular"`. `4g` means "LTE radio", not web's throughput estimate.
//
// Refs: PLAN-iOS.md §7.5, §F3/T3.3, §16.4 / F16; docs/data-flow.md §3.3.
//

import Foundation
import Network
#if canImport(CoreTelephony) && os(iOS)
import CoreTelephony

// ponytail: one shared instance; CTTelephonyNetworkInfo is costly to create
// and its read-only properties are safe to read off the main thread.
nonisolated(unsafe) private let telephony = CTTelephonyNetworkInfo()
#endif

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
            return NetworkContext(
                type: .cellular,
                effectiveType: generation(radio: currentRadio()),
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

    /// Map a `CTRadioAccessTechnology*` value to `2g`…`5g`. `nil` or
    /// unrecognised → `"unknown"`, never `"cellular"`. Matches the raw
    /// constant strings so the table is testable where CoreTelephony
    /// is absent (macOS `swift test`). F35.
    public static func generation(radio: String?) -> String {
        switch radio?.replacingOccurrences(of: "CTRadioAccessTechnology", with: "") {
        case "GPRS", "Edge", "CDMA1x":
            return "2g"
        case "WCDMA", "HSDPA", "HSUPA", "CDMAEVDORev0", "CDMAEVDORevA", "CDMAEVDORevB", "eHRPD":
            return "3g"
        case "LTE":
            return "4g"
        case "NRNSA", "NR":
            return "5g"
        default:
            return "unknown"
        }
    }

    /// Radio access technology of the data-service SIM, `nil` when
    /// unavailable (simulator, no SIM, non-iOS).
    private static func currentRadio() -> String? {
        #if canImport(CoreTelephony) && os(iOS)
        guard let id = telephony.dataServiceIdentifier else { return nil }
        return telephony.serviceCurrentRadioAccessTechnology?[id]
        #else
        return nil
        #endif
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

    /// The monitor's latest path, for re-reads not driven by a path
    /// transition (F35 radio handover).
    public var currentPath: NWPath { monitor.currentPath }

    /// Synchronously snapshot the current path. Returns `.unknown`
    /// until the monitor has produced its first update.
    public var currentSnapshot: NetworkContext {
        NetworkContext.from(monitor.currentPath)
    }
}
