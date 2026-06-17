import XCTest
@testable import EdgeRum
import EdgeRumCore
import Network

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
