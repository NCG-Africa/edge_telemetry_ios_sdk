#if canImport(SwiftUI)
import XCTest
@testable import EdgeRum
import EdgeRumCore

/// Confirms the two SwiftUI view modifiers emit the right events with
/// the right `kind` discriminator. The modifier's behaviour is encoded
/// in the `SwiftUIEmitter` static functions, which we invoke directly
/// with a fake recorder — no SwiftUI rendering hierarchy is required.
/// F29: disappear emits nothing (no `screen.duration`), and host keys
/// under a reserved SDK prefix are dropped.
///
/// Refs: PLAN-iOS.md §3.2, §6.2, §F2/T2.6, §F7.
@available(macOS 10.15, *)
final class SwiftUIModifierTests: XCTestCase {

    private var recorder: ProbeRecorder!

    override func setUp() {
        super.setUp()
        recorder = ProbeRecorder()
    }

    override func tearDown() {
        recorder = nil
        super.tearDown()
    }

    // MARK: - emitScreenAppear

    func testEmitScreenAppearRecordsNavigationWithSwiftUIKind() {
        SwiftUIEmitter.emitScreenAppear(
            name: "Checkout",
            attributes: ["funnel.step": 3],
            recorder: recorder,
            riders: Riders()
        )

        let calls = recorder.calls
        XCTAssertEqual(calls.count, 1)
        guard case let .event(name, attributes) = calls[0] else {
            return XCTFail("Expected .event for navigation, got \(calls[0])")
        }
        XCTAssertEqual(name, "navigation")
        XCTAssertEqual(attributes["navigation.kind"], .string("swiftui"))
        XCTAssertEqual(attributes["navigation.screen"], .string("Checkout"))
        XCTAssertNil(attributes["navigation.type"], "F29: deleted")
        XCTAssertEqual(attributes["funnel.step"], .int(3))
    }

    // MARK: - emitScreenDisappear

    func testEmitScreenDisappearEmitsNothing() {
        let riders = Riders()
        SwiftUIEmitter.emitScreenAppear(name: "Checkout", attributes: nil, recorder: recorder, riders: riders)
        SwiftUIEmitter.emitScreenDisappear(name: "Checkout", riders: riders)
        XCTAssertEqual(recorder.calls.count, 1, "F29: no screen.duration on disappear")
    }

    func testHostAttributeCannotOverrideKindDiscriminator() {
        SwiftUIEmitter.emitScreenAppear(
            name: "Checkout",
            attributes: [
                "navigation.kind": .string("host-supplied"),
                "navigation.screen": .string("HostScreenName")
            ],
            recorder: recorder,
            riders: Riders()
        )

        guard case let .event(_, attributes) = recorder.calls[0] else {
            return XCTFail("Expected .event for navigation")
        }
        XCTAssertEqual(attributes["navigation.kind"], .string("swiftui"))
        XCTAssertEqual(attributes["navigation.screen"], .string("Checkout"))
        XCTAssertEqual(attributes[HostAttributes.droppedKey], .int(2))
    }

    func testTapHostAttributeCannotOverrideKindDiscriminator() {
        SwiftUIEmitter.emitTap(
            name: "buy_button",
            attributes: [
                "interaction.kind": .string("host-supplied"),
                "interaction.name": .string("HostName")
            ],
            recorder: recorder
        )

        guard case let .event(_, attributes) = recorder.calls[0] else {
            return XCTFail("Expected .event for user.interaction")
        }
        XCTAssertEqual(attributes["interaction.kind"], .string("tap"))
        XCTAssertEqual(attributes["interaction.name"], .string("buy_button"))
        XCTAssertEqual(attributes[HostAttributes.droppedKey], .int(2))
    }

    // MARK: - emitTap

    func testEmitTapRecordsUserInteractionWithTapKind() {
        SwiftUIEmitter.emitTap(
            name: "buy_button",
            attributes: ["product.id": "SKU-123"],
            recorder: recorder
        )

        let calls = recorder.calls
        XCTAssertEqual(calls.count, 1)
        guard case let .event(name, attributes) = calls[0] else {
            return XCTFail("Expected .event for user.interaction, got \(calls[0])")
        }
        XCTAssertEqual(name, "user.interaction")
        XCTAssertEqual(attributes["interaction.kind"], .string("tap"))
        XCTAssertEqual(attributes["interaction.name"], .string("buy_button"))
        XCTAssertEqual(attributes["interaction.name_source"], .string("host"), "F29: host-supplied label")
        XCTAssertEqual(attributes["product.id"], .string("SKU-123"))
        XCTAssertNil(attributes[HostAttributes.droppedKey], "omitted when zero")
    }

    // MARK: - Default-recorder routing

    func testDefaultsRouteThroughRecorderShared() {
        // Exercise the no-args modifier path (`recorder: Recorder.shared`)
        // by swapping the shared instance with a probe.
        let probe = ProbeRecorder()
        let previous = Recorder.installShared(probe)
        defer { Recorder.installShared(previous) }

        SwiftUIEmitter.emitTap(name: "card", attributes: nil)

        let calls = probe.calls
        XCTAssertEqual(calls.count, 1)
        guard case let .event(name, _) = calls[0] else {
            return XCTFail("Expected .event for user.interaction via shared recorder")
        }
        XCTAssertEqual(name, "user.interaction")
    }
}
#endif
