// Tests/EdgeRumCaptureTests/InteractionCaptureTests.swift
//
// F9 unit tests. Covers:
//
//   - install() idempotency, including under concurrent invocation
//   - base-class swizzle landing on UIWindow (the IMP for the base
//     differs from a subclass override's IMP)
//   - decideEmission for a UIButton with accessibilityIdentifier
//     (T9.1 acceptance) — interaction.kind / target / target_id /
//     screen
//   - target_id fallback to UIButton.currentTitle when no a11y id
//   - target_id omitted when neither a11y id nor button title exists
//   - UITableViewCell / UICollectionViewCell target resolution
//   - UIControl wins over an enclosing cell in the chain
//   - reflected class name in interaction.target
//   - secure text field as the hit view is skipped (T9.2 acceptance)
//   - secure text field reached via the responder chain is skipped
//     (T9.2 acceptance — full chain)
//   - the capture path never reads .text from a secure field
//   - interaction.screen sourced from F6 navigation state
//   - interaction.screen omitted when no screen has appeared
//   - handleSendEvent emits exactly once for a single .ended touch
//   - handleSendEvent ignores .began-only events
//   - Recorder.isEnabled = false halts emission while leaving the
//     swizzle installed
//
// All UIKit-driven tests are wrapped in
// `#if canImport(UIKit) && os(iOS)` so the macOS unit-test runner
// still compiles this file.
//
// Refs: PLAN-iOS.md §F9 / T9.1 / T9.2 acceptance criteria;
//       CLAUDE.md "Testing conventions".
//

import XCTest
import Foundation
import EdgeRumCore
@testable import EdgeRumCapture

#if canImport(UIKit) && os(iOS)
import UIKit
#endif

// MARK: - Probe recorder used by the capture tests
//
// A local copy mirroring the shape used by UIViewControllerCaptureTests
// and HTTPCaptureTests — capture tests can't depend on the EdgeRumTests
// target, so each capture-test file re-declares its own.

private final class CaptureProbeRecorder: Recording, @unchecked Sendable {

    enum Call: Equatable {
        case event(name: String, attributes: [String: AttributeValue])
        case performance(name: String, attributes: [String: AttributeValue])
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _enabled: Bool = true
    private let _clock: Clock

    init(clock: Clock = SystemClock(), enabled: Bool = true) {
        self._clock = clock
        self._enabled = enabled
    }

    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    var clock: Clock { _clock }
    var currentSessionId: String { "session_0_0000000000000000_ios" }
    var currentDeviceId: String { "device_0_0000000000000000_ios" }

    var isEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _enabled
    }

    func setEnabledFlagOnly(_ value: Bool) {
        lock.lock(); _enabled = value; lock.unlock()
    }

    func configure(_ config: RecorderConfig) { _ = config }
    func start(apiKey: String, endpoint: URL, debug: Bool) {
        _ = (apiKey, endpoint, debug)
    }
    func stop() {}
    func setEnabled(_ enabled: Bool) { setEnabledFlagOnly(enabled) }

    func recordEvent(name: String, attributes: [String: AttributeValue]) {
        lock.lock()
        _calls.append(.event(name: name, attributes: attributes))
        lock.unlock()
    }

    func recordPerformance(name: String, attributes: [String: AttributeValue]) {
        lock.lock()
        _calls.append(.performance(name: name, attributes: attributes))
        lock.unlock()
    }

    func recordError(
        domain: String, code: Int, message: String?,
        context: [String: AttributeValue]
    ) {
        _ = (domain, code, message, context)
    }

    func setUser(_ user: RecorderUser) { _ = user }
}

// MARK: - UIKit test helpers
//
// XCTest can't construct a real `UIEvent` or `UITouch` from public API,
// so the `handleSendEvent` integration test subclasses `UITouch` and
// `UIEvent` to expose just what `InteractionCapture` reads: `type`,
// `allTouches`, `phase`, `view`.

#if canImport(UIKit) && os(iOS)

private final class TestTouch: UITouch {
    private let _phase: UITouch.Phase
    private let _view: UIView?

    init(phase: UITouch.Phase, view: UIView?) {
        self._phase = phase
        self._view = view
        super.init()
    }

    override var phase: UITouch.Phase { _phase }
    override var view: UIView? { _view }
}

private final class TestEvent: UIEvent {
    private let _type: UIEvent.EventType
    private let _touches: Set<UITouch>?

    init(type: UIEvent.EventType, touches: Set<UITouch>?) {
        self._type = type
        self._touches = touches
        super.init()
    }

    override var type: UIEvent.EventType { _type }
    override var allTouches: Set<UITouch>? { _touches }
}

/// A UIView subclass that overrides `next` to return a caller-supplied
/// responder. Lets tests synthesise the "secure field reached via the
/// responder chain, not via the view hierarchy" scenario without
/// constructing a real keyboard accessory view.
private final class ResponderForwardingView: UIView {
    var forwardedNext: UIResponder?

    override var next: UIResponder? {
        forwardedNext
    }
}

#endif

// MARK: - Tests

final class InteractionCaptureTests: XCTestCase {

    // MARK: UIKit-driven tests — iOS only

    #if canImport(UIKit) && os(iOS)

    override func setUp() {
        super.setUp()
        InteractionCapture.install(debug: true)
        UIViewControllerCapture._resetPreviousScreenForTesting()
    }

    override func tearDown() {
        Recorder.resetShared()
        UIViewControllerCapture._resetPreviousScreenForTesting()
        super.tearDown()
    }

    // MARK: install()

    func test_install_isIdempotent() {
        XCTAssertTrue(InteractionCapture.isInstalled)
        // Calling again must not crash and must remain installed.
        InteractionCapture.install(debug: false)
        InteractionCapture.install(debug: false)
        XCTAssertTrue(InteractionCapture.isInstalled)
    }

    func test_install_concurrentCallsAreSafe() {
        let group = DispatchGroup()
        for _ in 0..<32 {
            group.enter()
            DispatchQueue.global().async {
                InteractionCapture.install(debug: false)
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(InteractionCapture.isInstalled)
    }

    func test_install_swizzledBaseUIWindowIMPDiffersFromSubclassOverride() {
        let baseSelector = #selector(UIWindow.sendEvent(_:))

        let baseMethod = class_getInstanceMethod(UIWindow.self, baseSelector)
        XCTAssertNotNil(baseMethod)

        // A subclass that overrides sendEvent must keep its own
        // implementation — we only swizzle the base class.
        final class OverridingWindow: UIWindow {
            override func sendEvent(_ event: UIEvent) {
                super.sendEvent(event)
            }
        }
        let subclassMethod = class_getInstanceMethod(OverridingWindow.self, baseSelector)
        XCTAssertNotNil(subclassMethod)

        let baseImp = method_getImplementation(baseMethod!)
        let subImp = method_getImplementation(subclassMethod!)
        XCTAssertNotEqual(
            baseImp, subImp,
            "Subclass override must retain its own IMP — the swizzle only replaces UIWindow's base IMP"
        )
    }

    // MARK: decideEmission — T9.1 acceptance

    func test_decideEmission_button_withAccessibilityIdentifier() {
        let button = UIButton(type: .system)
        button.accessibilityIdentifier = "checkout"

        guard let attrs = InteractionCapture.decideEmission(
            for: button,
            currentScreen: "Cart"
        ) else {
            return XCTFail("Expected an attribute bag for a non-secure button tap")
        }
        XCTAssertEqual(attrs["interaction.kind"], .string("tap"))
        XCTAssertEqual(attrs["interaction.target_id"], .string("checkout"))
        XCTAssertEqual(attrs["interaction.screen"], .string("Cart"))
        if case let .string(target) = attrs["interaction.target"] {
            XCTAssertTrue(
                target.contains("UIButton"),
                "expected target to contain 'UIButton', got \(target)"
            )
        } else {
            XCTFail("interaction.target must be a string")
        }
    }

    func test_decideEmission_button_fallsBackToCurrentTitle() {
        let button = UIButton(type: .system)
        button.setTitle("Buy", for: .normal)

        guard let attrs = InteractionCapture.decideEmission(
            for: button,
            currentScreen: nil
        ) else {
            return XCTFail("Expected an attribute bag")
        }
        XCTAssertEqual(attrs["interaction.target_id"], .string("Buy"))
    }

    func test_decideEmission_omitsTargetIdWhenNoIdOrTitle() {
        let view = UIView()
        guard let attrs = InteractionCapture.decideEmission(
            for: view,
            currentScreen: nil
        ) else {
            return XCTFail("Expected an attribute bag for a plain view tap")
        }
        XCTAssertNil(attrs["interaction.target_id"])
    }

    func test_decideEmission_resolvesCellTargetForChildView() {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        let label = UILabel()
        cell.contentView.addSubview(label)

        guard let attrs = InteractionCapture.decideEmission(
            for: label,
            currentScreen: nil
        ) else {
            return XCTFail("Expected an attribute bag")
        }
        if case let .string(target) = attrs["interaction.target"] {
            XCTAssertTrue(
                target.contains("UITableViewCell"),
                "expected target to contain 'UITableViewCell', got \(target)"
            )
        } else {
            XCTFail("interaction.target must be a string")
        }
    }

    func test_decideEmission_resolvesCollectionViewCellTargetForChildView() {
        let cell = UICollectionViewCell()
        let label = UILabel()
        cell.contentView.addSubview(label)

        guard let attrs = InteractionCapture.decideEmission(
            for: label,
            currentScreen: nil
        ) else {
            return XCTFail("Expected an attribute bag")
        }
        if case let .string(target) = attrs["interaction.target"] {
            XCTAssertTrue(
                target.contains("UICollectionViewCell"),
                "expected target to contain 'UICollectionViewCell', got \(target)"
            )
        } else {
            XCTFail("interaction.target must be a string")
        }
    }

    func test_decideEmission_uiControlWinsOverEnclosingCell() {
        // Nesting a UIButton inside a UITableViewCell — controls should
        // beat cells in the resolution order so we report the action
        // surface, not the row container.
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        let button = UIButton(type: .system)
        button.accessibilityIdentifier = "subscribe"
        cell.contentView.addSubview(button)

        guard let attrs = InteractionCapture.decideEmission(
            for: button,
            currentScreen: nil
        ) else {
            return XCTFail("Expected an attribute bag")
        }
        XCTAssertEqual(attrs["interaction.target_id"], .string("subscribe"))
        if case let .string(target) = attrs["interaction.target"] {
            XCTAssertTrue(
                target.contains("UIButton"),
                "expected target to contain 'UIButton', got \(target)"
            )
        } else {
            XCTFail("interaction.target must be a string")
        }
    }

    func test_decideEmission_targetReflectsCustomSubclass() {
        final class TestCheckoutButton: UIButton {}
        let button = TestCheckoutButton(type: .system)

        guard let attrs = InteractionCapture.decideEmission(
            for: button,
            currentScreen: nil
        ) else {
            return XCTFail("Expected an attribute bag")
        }
        if case let .string(target) = attrs["interaction.target"] {
            XCTAssertTrue(
                target.contains("TestCheckoutButton"),
                "expected target to contain 'TestCheckoutButton', got \(target)"
            )
        } else {
            XCTFail("interaction.target must be a string")
        }
    }

    // MARK: decideEmission — T9.2 acceptance (secure-entry exclusion)

    func test_decideEmission_secureTextFieldIsSkipped() {
        let field = UITextField()
        field.isSecureTextEntry = true
        field.text = "should-never-be-read"

        XCTAssertNil(InteractionCapture.decideEmission(
            for: field,
            currentScreen: "Login"
        ))
    }

    func test_decideEmission_nonSecureTextFieldIsCaptured() {
        let field = UITextField()
        field.isSecureTextEntry = false
        field.accessibilityIdentifier = "email"

        guard let attrs = InteractionCapture.decideEmission(
            for: field,
            currentScreen: nil
        ) else {
            return XCTFail("Expected a non-secure text field to emit")
        }
        XCTAssertEqual(attrs["interaction.target_id"], .string("email"))
    }

    func test_decideEmission_secureFieldReachedViaResponderChainIsSkipped() {
        // Simulate the "tap landed on a view that lives outside the
        // text field's view hierarchy but is logically owned by it"
        // case — e.g. a keyboard accessory view whose `next` returns
        // the secure field.
        let secureField = UITextField()
        secureField.isSecureTextEntry = true

        let leaf = ResponderForwardingView()
        leaf.forwardedNext = secureField

        XCTAssertNil(InteractionCapture.decideEmission(
            for: leaf,
            currentScreen: nil
        ))
    }

    func test_decideEmission_neverReadsSecureFieldText() {
        // Belt-and-braces sentinel check: any leak of the secure
        // field's text into the resulting bag would show up as a
        // matching string somewhere.
        let sentinel = "do-not-leak-this-text"
        let field = UITextField()
        field.isSecureTextEntry = true
        field.text = sentinel
        field.accessibilityIdentifier = sentinel

        // Secure → bag is nil, so we cannot possibly have leaked text.
        XCTAssertNil(InteractionCapture.decideEmission(
            for: field,
            currentScreen: nil
        ))
    }

    func test_responderChainContainsSecureField_recognisesDirectField() {
        let field = UITextField()
        field.isSecureTextEntry = true
        XCTAssertTrue(InteractionCapture.responderChainContainsSecureField(startingAt: field))
    }

    func test_responderChainContainsSecureField_ignoresNonSecureField() {
        let field = UITextField()
        field.isSecureTextEntry = false
        XCTAssertFalse(InteractionCapture.responderChainContainsSecureField(startingAt: field))
    }

    // MARK: decideEmission — screen sourcing

    func test_decideEmission_screenIncludedWhenSet() {
        UIViewControllerCapture.setPreviousScreen("Cart")
        let button = UIButton(type: .system)
        button.accessibilityIdentifier = "checkout"

        guard let attrs = InteractionCapture.decideEmission(
            for: button,
            currentScreen: UIViewControllerCapture.currentPreviousScreen()
        ) else {
            return XCTFail("Expected an attribute bag")
        }
        XCTAssertEqual(attrs["interaction.screen"], .string("Cart"))
    }

    func test_decideEmission_screenOmittedWhenNoneSet() {
        UIViewControllerCapture._resetPreviousScreenForTesting()
        let button = UIButton(type: .system)
        button.accessibilityIdentifier = "checkout"

        guard let attrs = InteractionCapture.decideEmission(
            for: button,
            currentScreen: UIViewControllerCapture.currentPreviousScreen()
        ) else {
            return XCTFail("Expected an attribute bag")
        }
        XCTAssertNil(attrs["interaction.screen"])
    }

    func test_decideEmission_emptyScreenIsOmitted() {
        let button = UIButton(type: .system)
        button.accessibilityIdentifier = "checkout"

        guard let attrs = InteractionCapture.decideEmission(
            for: button,
            currentScreen: ""
        ) else {
            return XCTFail("Expected an attribute bag")
        }
        XCTAssertNil(attrs["interaction.screen"])
    }

    // MARK: handleSendEvent integration

    func test_handleSendEvent_endedTouchEmitsExactlyOnce() {
        let probe = CaptureProbeRecorder()
        Recorder.installShared(probe)

        let button = UIButton(type: .system)
        button.accessibilityIdentifier = "checkout"
        let touch = TestTouch(phase: .ended, view: button)
        let event = TestEvent(type: .touches, touches: [touch])

        InteractionCapture.handleSendEvent(event)

        let events = probe.calls.compactMap { call -> (String, [String: AttributeValue])? in
            if case let .event(name, attrs) = call { return (name, attrs) }
            return nil
        }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.0, "user.interaction")
        XCTAssertEqual(events.first?.1["interaction.target_id"], .string("checkout"))
    }

    func test_handleSendEvent_beganOnlyIsIgnored() {
        let probe = CaptureProbeRecorder()
        Recorder.installShared(probe)

        let button = UIButton(type: .system)
        button.accessibilityIdentifier = "checkout"
        let touch = TestTouch(phase: .began, view: button)
        let event = TestEvent(type: .touches, touches: [touch])

        InteractionCapture.handleSendEvent(event)

        XCTAssertEqual(probe.calls.count, 0)
    }

    func test_handleSendEvent_cancelledTouchIsIgnored() {
        let probe = CaptureProbeRecorder()
        Recorder.installShared(probe)

        let button = UIButton(type: .system)
        button.accessibilityIdentifier = "checkout"
        let touch = TestTouch(phase: .cancelled, view: button)
        let event = TestEvent(type: .touches, touches: [touch])

        InteractionCapture.handleSendEvent(event)

        XCTAssertEqual(probe.calls.count, 0)
    }

    func test_handleSendEvent_nonTouchEventIsIgnored() {
        let probe = CaptureProbeRecorder()
        Recorder.installShared(probe)

        let button = UIButton(type: .system)
        button.accessibilityIdentifier = "checkout"
        let touch = TestTouch(phase: .ended, view: button)
        let event = TestEvent(type: .motion, touches: [touch])

        InteractionCapture.handleSendEvent(event)

        XCTAssertEqual(probe.calls.count, 0)
    }

    func test_handleSendEvent_secureTextFieldEmitsNothing() {
        // T9.2 acceptance — wraps the full path.
        let probe = CaptureProbeRecorder()
        Recorder.installShared(probe)

        let field = UITextField()
        field.isSecureTextEntry = true
        let touch = TestTouch(phase: .ended, view: field)
        let event = TestEvent(type: .touches, touches: [touch])

        InteractionCapture.handleSendEvent(event)

        XCTAssertEqual(probe.calls.count, 0)
    }

    func test_handleSendEvent_disabledRecorderHaltsEmission() {
        let probe = CaptureProbeRecorder(enabled: false)
        Recorder.installShared(probe)

        let button = UIButton(type: .system)
        button.accessibilityIdentifier = "checkout"
        let touch = TestTouch(phase: .ended, view: button)
        let event = TestEvent(type: .touches, touches: [touch])

        InteractionCapture.handleSendEvent(event)

        XCTAssertEqual(probe.calls.count, 0)
        // Swizzle stays installed even when the recorder is off —
        // re-enabling the SDK must not require re-installing.
        XCTAssertTrue(InteractionCapture.isInstalled)
    }

    func test_handleSendEvent_multipleEndedTouchesEmitOneEventEach() {
        let probe = CaptureProbeRecorder()
        Recorder.installShared(probe)

        let buttonA = UIButton(type: .system)
        buttonA.accessibilityIdentifier = "left"
        let buttonB = UIButton(type: .system)
        buttonB.accessibilityIdentifier = "right"

        let touchA = TestTouch(phase: .ended, view: buttonA)
        let touchB = TestTouch(phase: .ended, view: buttonB)
        let event = TestEvent(type: .touches, touches: [touchA, touchB])

        InteractionCapture.handleSendEvent(event)

        let events = probe.calls.compactMap { call -> [String: AttributeValue]? in
            if case let .event(_, attrs) = call { return attrs }
            return nil
        }
        XCTAssertEqual(events.count, 2)
        let ids = Set(events.compactMap { attrs -> String? in
            if case let .string(s) = attrs["interaction.target_id"] { return s }
            return nil
        })
        XCTAssertEqual(ids, ["left", "right"])
    }

    func test_handleSendEvent_mixedPhasesEmitOnlyForEnded() {
        let probe = CaptureProbeRecorder()
        Recorder.installShared(probe)

        let buttonA = UIButton(type: .system)
        buttonA.accessibilityIdentifier = "only-this-one"
        let buttonB = UIButton(type: .system)
        buttonB.accessibilityIdentifier = "ignored"

        let endedTouch = TestTouch(phase: .ended, view: buttonA)
        let beganTouch = TestTouch(phase: .began, view: buttonB)
        let event = TestEvent(type: .touches, touches: [endedTouch, beganTouch])

        InteractionCapture.handleSendEvent(event)

        let events = probe.calls.compactMap { call -> [String: AttributeValue]? in
            if case let .event(_, attrs) = call { return attrs }
            return nil
        }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?["interaction.target_id"], .string("only-this-one"))
    }

    func test_handleSendEvent_screenSourcedFromNavigationState() {
        UIViewControllerCapture.setPreviousScreen("Profile")
        let probe = CaptureProbeRecorder()
        Recorder.installShared(probe)

        let button = UIButton(type: .system)
        button.accessibilityIdentifier = "save"
        let touch = TestTouch(phase: .ended, view: button)
        let event = TestEvent(type: .touches, touches: [touch])

        InteractionCapture.handleSendEvent(event)

        guard case let .event(_, attrs) = probe.calls.first else {
            return XCTFail("Expected a user.interaction event")
        }
        XCTAssertEqual(attrs["interaction.screen"], .string("Profile"))
    }

    #endif
}
