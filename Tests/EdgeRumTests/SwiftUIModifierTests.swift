#if canImport(SwiftUI)
import XCTest
@testable import EdgeRum
import EdgeRumCore

/// Confirms the two SwiftUI view modifiers emit the right events with
/// the right `kind` discriminator. We do not render any SwiftUI
/// hierarchy — the modifier's behaviour is encoded in the
/// `SwiftUIEmitter` static functions, which we invoke directly with
/// a fake recorder.
///
/// Refs: PLAN-iOS.md §3.2, §6.2, §F2/T2.6.
@available(macOS 10.15, *)
final class SwiftUIModifierTests: XCTestCase {

    private var recorder: Recorder!
    private var startStore: SwiftUIScreenStartStore!

    override func setUp() {
        super.setUp()
        let clock = AdvancingClock(times: [
            Date(timeIntervalSince1970: 1_000_000.0),
            Date(timeIntervalSince1970: 1_000_001.5) // dwell = 1500ms
        ])
        recorder = Recorder(clock: clock)
        startStore = SwiftUIScreenStartStore()
    }

    override func tearDown() {
        recorder = nil
        startStore = nil
        super.tearDown()
    }

    func testEmitScreenAppearRecordsNavigationWithSwiftUIKind() {
        SwiftUIEmitter.emitScreenAppear(
            name: "Checkout",
            attributes: ["funnel.step": 3],
            recorder: recorder,
            clock: recorder.clock,
            startStore: startStore
        )

        let calls = recorder.recordedCalls
        XCTAssertEqual(calls.count, 1)
        guard case let .event(name, attributes) = calls[0] else {
            return XCTFail("Expected .event for navigation, got \(calls[0])")
        }
        XCTAssertEqual(name, "navigation")
        XCTAssertEqual(attributes["navigation.kind"], .string("swiftui"))
        XCTAssertEqual(attributes["navigation.name"], .string("Checkout"))
        XCTAssertEqual(attributes["funnel.step"], .int(3))
    }

    func testEmitScreenDisappearEmitsScreenDurationWithDwell() {
        SwiftUIEmitter.emitScreenAppear(
            name: "Checkout",
            attributes: nil,
            recorder: recorder,
            clock: recorder.clock,
            startStore: startStore
        )
        SwiftUIEmitter.emitScreenDisappear(
            name: "Checkout",
            attributes: nil,
            recorder: recorder,
            clock: recorder.clock,
            startStore: startStore
        )

        let calls = recorder.recordedCalls
        XCTAssertEqual(calls.count, 2)
        guard case let .event(name, attributes) = calls[1] else {
            return XCTFail("Expected .event for screen.duration, got \(calls[1])")
        }
        XCTAssertEqual(name, "screen.duration")
        XCTAssertEqual(attributes["navigation.kind"], .string("swiftui"))
        XCTAssertEqual(attributes["navigation.name"], .string("Checkout"))
        XCTAssertEqual(attributes["duration_ms"], .int(1500))
    }

    func testEmitTapRecordsUserInteractionWithTapKind() {
        SwiftUIEmitter.emitTap(
            name: "buy_button",
            attributes: ["product.id": "SKU-123"],
            recorder: recorder
        )

        let calls = recorder.recordedCalls
        XCTAssertEqual(calls.count, 1)
        guard case let .event(name, attributes) = calls[0] else {
            return XCTFail("Expected .event for user.interaction, got \(calls[0])")
        }
        XCTAssertEqual(name, "user.interaction")
        XCTAssertEqual(attributes["interaction.kind"], .string("tap"))
        XCTAssertEqual(attributes["interaction.name"], .string("buy_button"))
        XCTAssertEqual(attributes["product.id"], .string("SKU-123"))
    }

    func testScreenStartStoreConsumeIsOneShot() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        startStore.recordStart(name: "A", at: now)
        XCTAssertEqual(startStore.consumeDwellMs(name: "A", now: now.addingTimeInterval(0.250)), 250)
        XCTAssertNil(startStore.consumeDwellMs(name: "A", now: now.addingTimeInterval(0.500)),
                     "Second consume for the same screen should return nil")
    }
}
#endif
