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

    // MARK: - track / trackScreen

    func testTrackRoutesNameAndAttributes() {
        EdgeRum.start(Self.validConfig())
        EdgeRum.track("checkout_started", attributes: ["cart.size": 3])

        let events = probe.calls.compactMap { call -> (String, [String: AttributeValue])? in
            if case let .event(name, attributes) = call { return (name, attributes) }
            return nil
        }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.0, "checkout_started")
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
        XCTAssertEqual(events.first?.1["navigation.name"], .string("Home"))
        XCTAssertEqual(events.first?.1["funnel.step"], .int(1))
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
        XCTAssertEqual(perfs.first?.0, "checkout.submit")
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

    func testCaptureErrorFlattensNSError() {
        EdgeRum.start(Self.validConfig())
        let err = NSError(
            domain: "PaymentDomain",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "Card declined"]
        )
        EdgeRum.captureError(err, context: ["payment.method": "card"])

        let errors = probe.calls.compactMap { call -> (String, Int, String?, [String: AttributeValue])? in
            if case let .error(domain, code, message, context) = call {
                return (domain, code, message, context)
            }
            return nil
        }
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.first?.0, "PaymentDomain")
        XCTAssertEqual(errors.first?.1, 42)
        XCTAssertEqual(errors.first?.2, "Card declined")
        XCTAssertEqual(errors.first?.3["payment.method"], .string("card"))
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

// MARK: - Probe Recorder

/// In-memory `Recording` that captures every call so tests can
/// assert exact routing behaviour.
internal final class ProbeRecorder: Recording, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [RecordedCall] = []
    private var _enabled: Bool = false

    private let _clock: Clock = SystemClock()
    private let _sessionId: String = "session_0_0000000000000000_ios"
    private let _deviceId: String = "device_0_0000000000000000_ios"

    internal init() {}

    internal var calls: [RecordedCall] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    internal var clock: Clock { _clock }
    internal var currentSessionId: String { _sessionId }
    internal var currentDeviceId: String { _deviceId }

    internal var isEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _enabled
    }

    internal func start(apiKey: String, endpoint: URL, debug: Bool) {
        lock.lock()
        _enabled = true
        _calls.append(.start(apiKey: apiKey, endpoint: endpoint, debug: debug))
        lock.unlock()
    }

    internal func stop() {
        lock.lock()
        _enabled = false
        _calls.append(.stop)
        lock.unlock()
    }

    internal func setEnabled(_ enabled: Bool) {
        lock.lock()
        _enabled = enabled
        _calls.append(.setEnabled(enabled))
        lock.unlock()
    }

    internal func recordEvent(name: String, attributes: [String: AttributeValue]) {
        lock.lock()
        _calls.append(.event(name: name, attributes: attributes))
        lock.unlock()
    }

    internal func recordPerformance(name: String, attributes: [String: AttributeValue]) {
        lock.lock()
        _calls.append(.performance(name: name, attributes: attributes))
        lock.unlock()
    }

    internal func recordError(domain: String, code: Int, message: String?, context: [String: AttributeValue]) {
        lock.lock()
        _calls.append(.error(domain: domain, code: code, message: message, context: context))
        lock.unlock()
    }

    internal func setUser(_ user: RecorderUser) {
        lock.lock()
        _calls.append(.setUser(user))
        lock.unlock()
    }
}
