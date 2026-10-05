import XCTest
@testable import EdgeRum
import EdgeRumCore
import Network
#if canImport(CoreTelephony) && os(iOS)
import CoreTelephony
#endif

/// Unit tests for `NetworkContext` extras — F16/T16.3's `expensive`,
/// `constrained`, and `interface` wire keys.
///
/// Refs: PLAN-iOS.md §16.4 / F16 / T16.3; docs/data-flow.md §3.3.
final class NetworkContextExtrasTests: XCTestCase {

    // MARK: write(into:)

    func testWriteEmitsAllFiveKeysWhenExtrasPresent() {
        let ctx = NetworkContext(
            type: .wifi,
            effectiveType: "wifi",
            isExpensive: true,
            isConstrained: false,
            interface: "en0"
        )
        var bag = AttributeBag()
        ctx.write(into: &bag)
        XCTAssertEqual(bag["network.type"], .string("wifi"))
        XCTAssertEqual(bag["network.effectiveType"], .string("wifi"))
        XCTAssertEqual(bag["network.expensive"], .bool(true))
        XCTAssertEqual(bag["network.constrained"], .bool(false))
        XCTAssertEqual(bag["network.interface"], .string("en0"))
        XCTAssertEqual(bag.count, 5)
    }

    func testWriteOmitsInterfaceWhenNil() {
        let ctx = NetworkContext(
            type: .none,
            effectiveType: "unknown",
            isExpensive: false,
            isConstrained: false,
            interface: nil
        )
        var bag = AttributeBag()
        ctx.write(into: &bag)
        XCTAssertEqual(bag["network.type"], .string("none"))
        XCTAssertEqual(bag["network.expensive"], .bool(false))
        XCTAssertEqual(bag["network.constrained"], .bool(false))
        XCTAssertNil(bag["network.interface"])
    }

    func testWriteAlwaysEmitsExpensiveAndConstrainedAsBool() {
        // Default-init NetworkContext should still emit booleans for
        // `expensive` and `constrained` (defaulting to false) so the
        // wire shape stays stable.
        let ctx = NetworkContext()
        var bag = AttributeBag()
        ctx.write(into: &bag)
        XCTAssertEqual(bag["network.expensive"], .bool(false))
        XCTAssertEqual(bag["network.constrained"], .bool(false))
    }

    // MARK: generation(radio:) — F35 radio mapping

    func testGenerationMapsEveryRadioAccessTechnology() {
        let table: [(String?, String)] = [
            ("CTRadioAccessTechnologyGPRS", "2g"),
            ("CTRadioAccessTechnologyEdge", "2g"),
            ("CTRadioAccessTechnologyCDMA1x", "2g"),
            ("CTRadioAccessTechnologyWCDMA", "3g"),
            ("CTRadioAccessTechnologyHSDPA", "3g"),
            ("CTRadioAccessTechnologyHSUPA", "3g"),
            ("CTRadioAccessTechnologyCDMAEVDORev0", "3g"),
            ("CTRadioAccessTechnologyCDMAEVDORevA", "3g"),
            ("CTRadioAccessTechnologyCDMAEVDORevB", "3g"),
            ("CTRadioAccessTechnologyeHRPD", "3g"),
            ("CTRadioAccessTechnologyLTE", "4g"),
            ("CTRadioAccessTechnologyNRNSA", "5g"),
            ("CTRadioAccessTechnologyNR", "5g"),
            (nil, "unknown"),
            ("", "unknown"),
            ("CTRadioAccessTechnologySomethingNew", "unknown"),
        ]
        for (radio, expected) in table {
            XCTAssertEqual(NetworkContext.generation(radio: radio), expected, "\(radio ?? "nil")")
            XCTAssertNotEqual(NetworkContext.generation(radio: radio), "cellular")
        }
    }

    #if canImport(CoreTelephony) && os(iOS)
    /// The mapping matches on raw strings so it runs on macOS; pin them
    /// to the SDK constants where CoreTelephony exists.
    func testGenerationMatchesCoreTelephonyConstants() {
        XCTAssertEqual(NetworkContext.generation(radio: CTRadioAccessTechnologyGPRS), "2g")
        XCTAssertEqual(NetworkContext.generation(radio: CTRadioAccessTechnologyEdge), "2g")
        XCTAssertEqual(NetworkContext.generation(radio: CTRadioAccessTechnologyCDMA1x), "2g")
        XCTAssertEqual(NetworkContext.generation(radio: CTRadioAccessTechnologyWCDMA), "3g")
        XCTAssertEqual(NetworkContext.generation(radio: CTRadioAccessTechnologyHSDPA), "3g")
        XCTAssertEqual(NetworkContext.generation(radio: CTRadioAccessTechnologyHSUPA), "3g")
        XCTAssertEqual(NetworkContext.generation(radio: CTRadioAccessTechnologyCDMAEVDORev0), "3g")
        XCTAssertEqual(NetworkContext.generation(radio: CTRadioAccessTechnologyCDMAEVDORevA), "3g")
        XCTAssertEqual(NetworkContext.generation(radio: CTRadioAccessTechnologyCDMAEVDORevB), "3g")
        XCTAssertEqual(NetworkContext.generation(radio: CTRadioAccessTechnologyeHRPD), "3g")
        XCTAssertEqual(NetworkContext.generation(radio: CTRadioAccessTechnologyLTE), "4g")
        if #available(iOS 14.1, *) {
            XCTAssertEqual(NetworkContext.generation(radio: CTRadioAccessTechnologyNRNSA), "5g")
            XCTAssertEqual(NetworkContext.generation(radio: CTRadioAccessTechnologyNR), "5g")
        }
    }
    #endif

    // MARK: from(_:) — exercise the live NWPathMonitor's currentPath

    /// `NWPathMonitor.currentPath` always returns a valid path even
    /// before `.start(queue:)` is called, so we can drive
    /// `NetworkContext.from(_:)` against a real path without
    /// activating the monitor. We can't assert specific flag values
    /// (CI hosts vary) but we can assert types + shape, which is what
    /// the wire contract cares about.
    func testFromCurrentPathProducesWellTypedExtras() {
        let monitor = NWPathMonitor()
        defer { monitor.cancel() }
        let ctx = NetworkContext.from(monitor.currentPath)
        // type is always one of the enum cases — covered by NetworkType
        XCTAssertNotNil(NetworkContext.NetworkType(rawValue: ctx.type.rawValue))
        // expensive + constrained must be plain Bool — no nil here
        // because the struct stores `Bool`, not `Bool?`.
        XCTAssertTrue(ctx.isExpensive == true || ctx.isExpensive == false)
        XCTAssertTrue(ctx.isConstrained == true || ctx.isConstrained == false)
        // interface is optional but, when present, must be a
        // non-empty string (NWInterface.name is a non-optional String).
        if let iface = ctx.interface {
            XCTAssertFalse(iface.isEmpty)
        }
    }
}
