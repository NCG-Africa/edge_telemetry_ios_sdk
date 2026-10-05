import XCTest
@testable import EdgeRum
import EdgeRumCore

/// End-to-end exercise of the `EdgeRum` namespace.
///
/// Strategy: swap the shared `Recorder` for a `ProbeRecorder` in
/// `setUp`, invoke each public method, and read the probe's recorded
/// call log. Restore the original recorder in `tearDown` so other
/// test files start from a clean state.
///
/// Refs: PLAN-iOS.md §3.2, §F2/T2.1; CLAUDE.md "Public API surface",
///       "Error handling conventions".
final class EdgeRumAPITests: XCTestCase {

    private var probe: ProbeRecorder!
    private var previousRecorder: Recording!

    override func setUp() {
        super.setUp()
        probe = ProbeRecorder()
        previousRecorder = Recorder.installShared(probe)
        EdgeRum._resetStartedConfigForTesting()
    }

    override func tearDown() {
        Recorder.installShared(previousRecorder)
        EdgeRum._resetStartedConfigForTesting()
        probe = nil
        previousRecorder = nil
        super.tearDown()
    }

    // MARK: - start()

    func testStartRoutesThroughToRecorder() {
        let config = Self.validConfig()
        EdgeRum.start(config)

        let startCalls = probe.calls.compactMap { call -> (String, URL, Bool)? in
            if case let .start(apiKey, endpoint, debug) = call {
                return (apiKey, endpoint, debug)
            }
            return nil
        }
        XCTAssertEqual(startCalls.count, 1)
        XCTAssertEqual(startCalls.first?.0, "edge_dev_abc")
        XCTAssertTrue(EdgeRum.isEnabled)
    }

    func testSecondStartWithSameIdentityIsNoOp() {
        EdgeRum.start(Self.validConfig())
        EdgeRum.start(Self.validConfig())

        let startCount = probe.calls.filter { if case .start = $0 { return true } else { return false } }.count
        XCTAssertEqual(startCount, 1, "Two start() calls with identical config should reach the recorder once")
    }

    func testSecondStartWithDifferentIdentityIsAlsoNoOp() {
        EdgeRum.start(Self.validConfig())
        var other = Self.validConfig()
        other.apiKey = "edge_other_xyz"
        EdgeRum.start(other)

        let startCount = probe.calls.filter { if case .start = $0 { return true } else { return false } }.count
        XCTAssertEqual(startCount, 1, "A different apiKey or endpoint must be warned-and-ignored, never crash")
    }

    // MARK: - Misuse before start()

    func testTrackBeforeStartIsNoOp() {
        EdgeRum.track("orphan_event")
        XCTAssertTrue(probe.calls.isEmpty)
    }

    func testTrackScreenBeforeStartIsNoOp() {
        EdgeRum.trackScreen("Home")
        XCTAssertTrue(probe.calls.isEmpty)
    }

    func testIdentifyBeforeStartIsNoOp() {
        EdgeRum.identify(UserContext(id: "1"))
        XCTAssertTrue(probe.calls.isEmpty)
    }

    func testCaptureErrorBeforeStartIsNoOp() {
        EdgeRum.captureError(NSError(domain: "test", code: 1))
        XCTAssertTrue(probe.calls.isEmpty)
    }

    func testClearUserAndResetIdentityBeforeStartAreNoOps() {
        EdgeRum.clearUser()
        EdgeRum.resetIdentity()
        XCTAssertTrue(probe.calls.isEmpty)
    }

    func testClearUserAndResetIdentityRoute() {
        EdgeRum.start(Self.validConfig())
        EdgeRum.clearUser()
        EdgeRum.resetIdentity()
        XCTAssertEqual(probe.calls.suffix(2), [.clearUser, .resetIdentity])
    }

    // MARK: - track / trackScreen

    func testTrackRoutesNameAndAttributes() {
        EdgeRum.start(Self.validConfig())
        EdgeRum.track("checkout_started", attributes: ["cart.size": 3])

        let events = probe.calls.compactMap { call -> (String, [String: AttributeValue])? in
            if case let .event(name, attributes) = call { return (name, attributes) }
            return nil
        }
        XCTAssertEqual(events.count, 1)
        // The wire `eventName` for custom track() calls is always
        // `"custom_event"`; the user-supplied name carries as the
        // `event.name` attribute. F3 enforces this strict allowlist
        // mapping at the EdgeRum.track call site so the Recorder's
        // `allowedEventNames` set never has to accept arbitrary
        // strings.
        XCTAssertEqual(events.first?.0, "custom_event")
        XCTAssertEqual(events.first?.1["event.name"], .string("checkout_started"))
        XCTAssertEqual(events.first?.1["cart.size"], .int(3))
    }

    func testTrackScreenEmitsNavigationWithName() {
        EdgeRum.start(Self.validConfig())
        EdgeRum.trackScreen("Home", attributes: ["funnel.step": 1])

        let events = probe.calls.compactMap { call -> (String, [String: AttributeValue])? in
            if case let .event(name, attributes) = call { return (name, attributes) }
            return nil
        }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.0, "navigation")
        XCTAssertEqual(events.first?.1["navigation.screen"], .string("Home"))
        XCTAssertEqual(events.first?.1["navigation.kind"], .string("manual"))
        XCTAssertNil(events.first?.1["navigation.name"], "F29: renamed")
        XCTAssertEqual(events.first?.1["funnel.step"], .int(1))
    }

    // F29 acceptance: a host `track` with a `device.` key is dropped.
    func testTrackDropsHostKeysUnderReservedPrefixes() {
        EdgeRum.start(Self.validConfig())
        EdgeRum.track("buy", attributes: [
            "device.model": "Forged",
            "user.email": "a@b.c",
            "cart.total": 3
        ])

        let attrs = probe.calls.compactMap { call -> [String: AttributeValue]? in
            if case let .event("custom_event", attributes) = call { return attributes }
            return nil
        }.first
        XCTAssertNil(attrs?["device.model"])
        XCTAssertNil(attrs?["user.email"])
        XCTAssertEqual(attrs?["cart.total"], .int(3))
        XCTAssertEqual(attrs?["event.name"], .string("buy"))
        XCTAssertEqual(attrs?["host_attributes.dropped"], .int(2))
    }

    func testTrackScreenDropsHostKeysUnderReservedPrefixes() {
        EdgeRum.start(Self.validConfig())
        EdgeRum.trackScreen("Home", attributes: ["navigation.kind": "Forged", "app.name": "x"])
        let attrs = probe.calls.compactMap { call -> [String: AttributeValue]? in
            if case let .event("navigation", attributes) = call { return attributes }
            return nil
        }.first
        XCTAssertEqual(attrs?["navigation.kind"], .string("manual"))
        XCTAssertNil(attrs?["app.name"])
        XCTAssertEqual(attrs?["host_attributes.dropped"], .int(2))
    }

    func testTimerDropsHostKeysUnderReservedPrefixes() {
        EdgeRum.start(Self.validConfig())
        EdgeRum.time("t").end(attributes: ["timer.name": "Forged", "session.id": "x"])
        let attrs = probe.calls.compactMap { call -> [String: AttributeValue]? in
            if case let .performance(_, attributes) = call { return attributes }
            return nil
        }.first
        XCTAssertEqual(attrs?["timer.name"], .string("t"))
        XCTAssertNil(attrs?["session.id"])
        XCTAssertEqual(attrs?["host_attributes.dropped"], .int(2))
    }

    func testTrackScreenWritesTheCurrentScreenBox() {
        Riders.shared._resetForTesting()
        defer { Riders.shared._resetForTesting() }
        EdgeRum.start(Self.validConfig())
        EdgeRum.trackScreen("Home")
        XCTAssertEqual(Riders.shared.currentScreen, "Home")
    }

    // MARK: - identify

    func testIdentifyRoutesUser() {
        EdgeRum.start(Self.validConfig())
        EdgeRum.identify(UserContext(id: "u-1", name: "Asha", email: "a@b.c", phone: nil))

        let users = probe.calls.compactMap { call -> RecorderUser? in
            if case let .setUser(user) = call { return user }
            return nil
        }
        XCTAssertEqual(users.count, 1)
        XCTAssertEqual(users.first?.id, "u-1")
        XCTAssertEqual(users.first?.name, "Asha")
        XCTAssertEqual(users.first?.email, "a@b.c")
        XCTAssertNil(users.first?.phone)
    }

    // MARK: - time()

    func testTimeReturnsUsableRumTimer() {
        EdgeRum.start(Self.validConfig())
        let timer = EdgeRum.time("checkout.submit")
        timer.end(attributes: ["payment.method": "card"])

        let perfs = probe.calls.compactMap { call -> (String, [String: AttributeValue])? in
            if case let .performance(name, attributes) = call { return (name, attributes) }
            return nil
        }
        XCTAssertEqual(perfs.count, 1)
        XCTAssertEqual(perfs.first?.0, "custom_timer", "F29: bounded metric name")
        XCTAssertEqual(perfs.first?.1["timer.name"], .string("checkout.submit"))
        XCTAssertEqual(perfs.first?.1["payment.method"], .string("card"))
        XCTAssertNotNil(perfs.first?.1["duration_ms"])
    }

    func testTimeBeforeStartReturnsPreCancelledTimer() {
        let timer = EdgeRum.time("orphan.timer")
        timer.end()
        let perfs = probe.calls.compactMap { call -> Void? in
            if case .performance = call { return () }
            return nil
        }
        XCTAssertEqual(perfs.count, 0,
                       "Calling time() before start() must return a timer whose end() is a no-op")
    }

    // MARK: - captureError

    func testCaptureErrorRoutesAppCrashEventToRecorder() {
        // F13: the public `captureError` builds an `app.crash` event
        // (cause = AppError) and hands the full attribute bag to the
        // Recorder via `recordEvent`. We assert the routing here; the
        // attribute-shape contract is exercised by
        // `AppErrorBuilderTests` and the wire conformance test.
        EdgeRum.start(Self.validConfig())
        let err = NSError(
            domain: "PaymentDomain",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "Card declined"]
        )
        EdgeRum.captureError(err, context: ["payment.method": "card"])

        let crashEvents = probe.calls.compactMap { call -> [String: AttributeValue]? in
            if case let .event(name, attributes) = call, name == "app.error" {
                return attributes
            }
            return nil
        }
        XCTAssertEqual(crashEvents.count, 1)
        guard let attrs = crashEvents.first else {
            return XCTFail("Expected an app.error routing call")
        }
        XCTAssertNil(attrs["cause"])
        XCTAssertEqual(attrs["runtime"], .string("swift"))
        XCTAssertEqual(attrs["error.kind"], .string("nserror"))
        XCTAssertEqual(attrs["error.domain"], .string("PaymentDomain"))
        XCTAssertEqual(attrs["error.code"], .int(42))
        XCTAssertEqual(attrs["error.message"], .string("Card declined"))
        XCTAssertEqual(attrs["crash.context.payment.method"], .string("card"))
        XCTAssertNil(attrs["payment.method"],
                     "Caller context must be prefixed `crash.context.`, never bare")
        // `error.stack` should be captured at the call site.
        if case let .string(stack) = attrs["error.stack"] {
            XCTAssertFalse(stack.isEmpty, "error.stack must be captured at the call site")
            XCTAssertTrue(stack.contains("testCaptureErrorRoutesAppCrashEventToRecorder")
                          || stack.contains("EdgeRumTests"),
                          "stack should include a frame from the calling test target")
            // F29 offset frame format: `image +0x<offset> <hint>`.
            XCTAssertTrue(stack.components(separatedBy: "\n").contains { $0.contains(" +0x") },
                          "frames must use the image-relative offset format")
            XCTAssertNotNil(attrs["error.binary_images"], "referenced images must be listed")
        } else {
            XCTFail("error.stack missing or wrong type")
        }
    }

    func testCaptureErrorWithSwiftErrorReportsKindSwift() {
        struct DemoError: Error { let detail: String }
        EdgeRum.start(Self.validConfig())
        EdgeRum.captureError(DemoError(detail: "nope"))
        let kinds = probe.calls.compactMap { call -> AttributeValue? in
            if case let .event(name, attributes) = call, name == "app.error" {
                return attributes["error.kind"]
            }
            return nil
        }
        XCTAssertEqual(kinds, [.string("swift")])
    }

    // MARK: - enable / disable

    func testDisableThenEnableTogglesSharedRecorder() {
        EdgeRum.start(Self.validConfig())
        EdgeRum.disable()
        XCTAssertFalse(EdgeRum.isEnabled)
        EdgeRum.enable()
        XCTAssertTrue(EdgeRum.isEnabled)
    }

    // MARK: - sessionId / deviceId

    func testSessionAndDeviceIdHaveTheDocumentedPrefix() {
        XCTAssertTrue(EdgeRum.sessionId.hasPrefix("session_"))
        XCTAssertTrue(EdgeRum.sessionId.hasSuffix("_ios"))
        XCTAssertTrue(EdgeRum.deviceId.hasPrefix("device_"))
        XCTAssertTrue(EdgeRum.deviceId.hasSuffix("_ios"))
    }

    // MARK: - handleBackgroundEvents

    func testHandleBackgroundEventsInvokesCompletionOnMain() {
        let expectation = expectation(description: "completion called on main")
        EdgeRum.handleBackgroundEvents(identifier: "com.edge.rum.upload") {
            XCTAssertTrue(Thread.isMainThread,
                          "AppDelegate contract: completion must fire on the main thread")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Helpers

    private static func validConfig() -> EdgeRumConfig {
        EdgeRumConfig(
            apiKey: "edge_dev_abc",
            endpoint: URL(string: "https://collect.example.com")!
        )
    }
}

// ProbeRecorder lives at Tests/EdgeRumTests/Helpers/ProbeRecorder.swift
// (extracted in F3 so RumTimerTests can use the same test double).
