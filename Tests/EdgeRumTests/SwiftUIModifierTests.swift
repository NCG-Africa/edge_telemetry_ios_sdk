#if canImport(SwiftUI)
import XCTest
@testable import EdgeRum
import EdgeRumCore

/// Confirms the two SwiftUI view modifiers emit the right events with
/// the right `kind` discriminator and that the F7 disappear path
/// routes through `recordPerformance` with the F6-aligned attribute
/// schema (`screen.name`, `screen.kind`, `screen.duration_ms`,
/// `value`). The modifier's behaviour is encoded in the
/// `SwiftUIEmitter` static functions, which we invoke directly with
/// a fake recorder — no SwiftUI rendering hierarchy is required.
///
/// Refs: PLAN-iOS.md §3.2, §6.2, §F2/T2.6, §F7.
@available(macOS 10.15, *)
final class SwiftUIModifierTests: XCTestCase {

    private var recorder: ProbeRecorder!
    private var startStore: SwiftUIScreenStartStore!

    override func setUp() {
        super.setUp()
        // A four-entry queue covers the longest test (interleave +
        // nested) without per-test reconstruction. Tests that need
        // fewer reads simply consume a prefix.
        let clock = AdvancingClock(times: [
            Date(timeIntervalSince1970: 1_000_000.0),
            Date(timeIntervalSince1970: 1_000_001.5), // +1500ms
            Date(timeIntervalSince1970: 1_000_002.5), // +2500ms
            Date(timeIntervalSince1970: 1_000_003.5)  // +3500ms
        ])
        recorder = ProbeRecorder(clock: clock)
        startStore = SwiftUIScreenStartStore()
    }

    override func tearDown() {
        recorder = nil
        startStore = nil
        super.tearDown()
    }

    // MARK: - emitScreenAppear

    func testEmitScreenAppearRecordsNavigationWithSwiftUIKind() {
        SwiftUIEmitter.emitScreenAppear(
            name: "Checkout",
            attributes: ["funnel.step": 3],
            recorder: recorder,
            clock: recorder.clock,
            startStore: startStore
        )

        let calls = recorder.calls
        XCTAssertEqual(calls.count, 1)
        guard case let .event(name, attributes) = calls[0] else {
            return XCTFail("Expected .event for navigation, got \(calls[0])")
        }
        XCTAssertEqual(name, "navigation")
        XCTAssertEqual(attributes["navigation.kind"], .string("swiftui"))
        XCTAssertEqual(attributes["navigation.screen"], .string("Checkout"))
        XCTAssertEqual(attributes["navigation.type"], .string("viewDidAppear"))
        XCTAssertEqual(attributes["funnel.step"], .int(3))
    }

    // MARK: - emitScreenDisappear

    func testEmitScreenDisappearRoutesAsPerformanceMetric() {
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

        let calls = recorder.calls
        XCTAssertEqual(calls.count, 2)
        // F7 parity fix — screen.duration is a metric, not an event.
        guard case let .performance(name, _) = calls[1] else {
            return XCTFail("Expected .performance for screen.duration, got \(calls[1])")
        }
        XCTAssertEqual(name, "screen.duration")
    }

    func testScreenAttributesUseF6AlignedKeys() {
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

        let calls = recorder.calls
        XCTAssertEqual(calls.count, 2)
        guard case let .performance(_, attributes) = calls[1] else {
            return XCTFail("Expected .performance for screen.duration")
        }
        XCTAssertEqual(attributes["screen.name"], .string("Checkout"))
        XCTAssertEqual(attributes["screen.kind"], .string("swiftui"))
        XCTAssertEqual(attributes["screen.duration_ms"], .int(1500))
        XCTAssertEqual(attributes["value"], .double(1.5))
    }

    func testMultipleScreensInterleave() {
        // A appear (t=0), B appear (t=+1.5s), B disappear (t=+2.5s →
        // dwell 1000ms), A disappear (t=+3.5s → dwell 3500ms). Pinned
        // to the four-timestamp setUp queue.
        SwiftUIEmitter.emitScreenAppear(
            name: "A", attributes: nil,
            recorder: recorder, clock: recorder.clock, startStore: startStore
        )
        SwiftUIEmitter.emitScreenAppear(
            name: "B", attributes: nil,
            recorder: recorder, clock: recorder.clock, startStore: startStore
        )
        SwiftUIEmitter.emitScreenDisappear(
            name: "B", attributes: nil,
            recorder: recorder, clock: recorder.clock, startStore: startStore
        )
        SwiftUIEmitter.emitScreenDisappear(
            name: "A", attributes: nil,
            recorder: recorder, clock: recorder.clock, startStore: startStore
        )

        let calls = recorder.calls
        XCTAssertEqual(calls.count, 4)
        guard case let .performance(_, bAttrs) = calls[2] else {
            return XCTFail("Expected B disappear at calls[2]")
        }
        guard case let .performance(_, aAttrs) = calls[3] else {
            return XCTFail("Expected A disappear at calls[3]")
        }
        XCTAssertEqual(bAttrs["screen.name"], .string("B"))
        XCTAssertEqual(bAttrs["screen.duration_ms"], .int(1000))
        XCTAssertEqual(aAttrs["screen.name"], .string("A"))
        XCTAssertEqual(aAttrs["screen.duration_ms"], .int(3500))
    }

    func testNestedSameNameScreensDocumentedLimitation() {
        // Two appears overwrite each other in the store; the first
        // disappear consumes the latest start; the second disappear
        // finds no paired start and is a silent no-op.
        SwiftUIEmitter.emitScreenAppear(
            name: "A", attributes: nil,
            recorder: recorder, clock: recorder.clock, startStore: startStore
        )
        SwiftUIEmitter.emitScreenAppear(
            name: "A", attributes: nil,
            recorder: recorder, clock: recorder.clock, startStore: startStore
        )
        SwiftUIEmitter.emitScreenDisappear(
            name: "A", attributes: nil,
            recorder: recorder, clock: recorder.clock, startStore: startStore
        )
        SwiftUIEmitter.emitScreenDisappear(
            name: "A", attributes: nil,
            recorder: recorder, clock: recorder.clock, startStore: startStore
        )

        // 2 appears + 1 disappear (the second disappear is dropped).
        XCTAssertEqual(recorder.calls.count, 3)
        guard case .performance = recorder.calls[2] else {
            return XCTFail("Expected the third call to be the only disappear emit")
        }
    }

    func testHostAttributeCannotOverrideKindDiscriminator() {
        // Caller maliciously / accidentally sets the discriminator —
        // the emitter must overwrite it back to "swiftui".
        SwiftUIEmitter.emitScreenAppear(
            name: "Checkout",
            attributes: [
                "navigation.kind": .string("host-supplied"),
                "navigation.screen": .string("HostScreenName"),
                "navigation.type": .string("hostEvent")
            ],
            recorder: recorder,
            clock: recorder.clock,
            startStore: startStore
        )

        guard case let .event(_, attributes) = recorder.calls[0] else {
            return XCTFail("Expected .event for navigation")
        }
        XCTAssertEqual(attributes["navigation.kind"], .string("swiftui"))
        XCTAssertEqual(attributes["navigation.screen"], .string("Checkout"))
        XCTAssertEqual(attributes["navigation.type"], .string("viewDidAppear"))
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
        XCTAssertEqual(attributes["product.id"], .string("SKU-123"))
    }

    // MARK: - Default-recorder routing

    func testDefaultsRouteThroughRecorderShared() {
        // Exercise the no-args modifier path (`recorder: Recorder.shared`)
        // by swapping the shared instance with a probe. `tearDown`
        // restores so sibling tests are unaffected.
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

    // MARK: - Missing-start handling

    func testMissingStartOnDisappearIsSilent() {
        SwiftUIEmitter.emitScreenDisappear(
            name: "Phantom",
            attributes: nil,
            recorder: recorder,
            clock: recorder.clock,
            startStore: startStore
        )
        XCTAssertEqual(recorder.calls.count, 0,
                       "Disappear without paired appear must be a silent no-op")
    }

    // MARK: - SwiftUIScreenStartStore

    func testScreenStartStoreConsumeIsOneShot() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        startStore.recordStart(name: "A", at: now)
        XCTAssertEqual(startStore.consumeDwellMs(name: "A", now: now.addingTimeInterval(0.250)), 250)
        XCTAssertNil(startStore.consumeDwellMs(name: "A", now: now.addingTimeInterval(0.500)),
                     "Second consume for the same screen should return nil")
    }

    func testScreenStartStoreDwellExposesSecondsAndMs() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        startStore.recordStart(name: "A", at: now)
        let dwell = startStore.consumeDwell(name: "A", now: now.addingTimeInterval(0.4567))
        XCTAssertNotNil(dwell)
        XCTAssertEqual(dwell?.ms, 457)
        XCTAssertEqual(dwell?.seconds ?? 0, 0.4567, accuracy: 0.0001)
    }

    func testScreenStartStoreThreadSafety() {
        let store = SwiftUIScreenStartStore()
        let iterations = 50
        let group = DispatchGroup()
        let now = Date()
        for i in 0..<iterations {
            group.enter()
            DispatchQueue.global().async {
                let name = "screen_\(i)"
                store.recordStart(name: name, at: now)
                _ = store.consumeDwell(name: name, now: now.addingTimeInterval(0.01))
                group.leave()
            }
        }
        let result = group.wait(timeout: .now() + 5.0)
        XCTAssertEqual(result, .success, "Thread-safety burst should complete within 5s")
        // After every recorded start was consumed, the internal map
        // must be empty — verified by another consume returning nil.
        XCTAssertNil(store.consumeDwell(name: "screen_0", now: now))
    }
}
#endif
