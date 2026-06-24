// Tests/EdgeRumCaptureTests/UIViewControllerCaptureTests.swift
//
// F6 unit tests. Covers:
//
//   - install() idempotency, including under concurrent invocation
//   - base-class swizzle landing on UIViewController (the IMP for the
//     base differs from a subclass override's IMP)
//   - vanilla UIViewController emits `navigation` on viewDidAppear
//   - container VCs (UINavigationController etc.) are skipped
//   - screen name resolution prefers accessibilityIdentifier, then
//     falls back to the reflected type name
//   - UIHostingController<Content> is detected and emits with
//     `navigation.kind = "swiftui"` and the Content type as the name
//   - `navigation.previous_screen` chains across appears
//   - `screen.duration` emits the right `value` and `screen.duration_ms`
//     when paired (FixedClock-driven so timing is deterministic)
//   - viewWillDisappear without a paired appear is a silent no-op
//   - Recorder.isEnabled = false halts emission while leaving the
//     swizzle installed
//   - the `extractHostedContent` parser handles nested generics,
//     no-angle-brackets, and malformed inputs
//
// All UIKit-driven tests are wrapped in
// `#if canImport(UIKit) && os(iOS)` so the macOS unit-test runner
// still compiles this file.
//
// Refs: PLAN-iOS.md §F6 acceptance criteria; CLAUDE.md "Testing
//       conventions".
//

import XCTest
import Foundation
import EdgeRumCore
@testable import EdgeRumCapture

#if canImport(UIKit) && os(iOS)
import UIKit
import SwiftUI
#endif

// MARK: - Probe recorder used by the capture tests
//
// Capture tests live in the EdgeRumCaptureTests target, which does
// not depend on the EdgeRumTests target — so we cannot reuse the
// `ProbeRecorder` defined there. This local copy mirrors the same
// shape, scoped to what F6 exercises.

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

// MARK: - Tests

final class UIViewControllerCaptureTests: XCTestCase {

    // MARK: Pure-Swift helpers — run on all platforms

    func test_extractHostedContent_parsesSimpleGeneric() {
        let input = "SwiftUI.UIHostingController<MyApp.HomeView>"
        XCTAssertEqual(
            UIViewControllerCapture.extractHostedContent(from: input),
            "MyApp.HomeView"
        )
    }

    func test_extractHostedContent_parsesNestedGenerics() {
        let input = "SwiftUI.UIHostingController<NavigationStack<HomeView>>"
        XCTAssertEqual(
            UIViewControllerCapture.extractHostedContent(from: input),
            "NavigationStack<HomeView>"
        )
    }

    func test_extractHostedContent_returnsNilWithoutAngleBrackets() {
        let input = "MyApp.HomeViewController"
        XCTAssertNil(UIViewControllerCapture.extractHostedContent(from: input))
    }

    func test_extractHostedContent_handlesMalformed() {
        // Unbalanced — opens but never closes. Loop walks to the end
        // and returns nil rather than crashing.
        let input = "Bogus<Foo"
        XCTAssertNil(UIViewControllerCapture.extractHostedContent(from: input))
    }

    func test_extractHostedContent_handlesTripleNested() {
        let input = "SwiftUI.UIHostingController<A<B<C>>>"
        XCTAssertEqual(
            UIViewControllerCapture.extractHostedContent(from: input),
            "A<B<C>>"
        )
    }

    func test_isHostingControllerTypeName_matchesUIHostingControllerPrefix() {
        XCTAssertTrue(UIViewControllerCapture.isHostingControllerTypeName(
            "SwiftUI.UIHostingController<MyApp.HomeView>"
        ))
        XCTAssertTrue(UIViewControllerCapture.isHostingControllerTypeName(
            "MyApp.SubclassedUIHostingController<MyApp.HomeView>"
        ))
        XCTAssertFalse(UIViewControllerCapture.isHostingControllerTypeName(
            "MyApp.HomeViewController"
        ))
    }

    // MARK: previousScreen pointer

    func test_previousScreen_setAndClear() {
        UIViewControllerCapture._resetPreviousScreenForTesting()
        XCTAssertNil(UIViewControllerCapture.currentPreviousScreen())
        UIViewControllerCapture.setPreviousScreen("Cart")
        XCTAssertEqual(UIViewControllerCapture.currentPreviousScreen(), "Cart")
        UIViewControllerCapture._resetPreviousScreenForTesting()
        XCTAssertNil(UIViewControllerCapture.currentPreviousScreen())
    }

    // MARK: UIKit-driven tests — iOS only

    #if canImport(UIKit) && os(iOS)

    /// Install the swizzle exactly once for the entire test suite.
    /// `setUp` re-installs each test to be defensive against test
    /// re-ordering, but the install itself is idempotent.
    override func setUp() {
        super.setUp()
        UIViewControllerCapture.install(debug: true)
        UIViewControllerCapture._resetPreviousScreenForTesting()
    }

    override func tearDown() {
        Recorder.resetShared()
        UIViewControllerCapture._resetPreviousScreenForTesting()
        super.tearDown()
    }

    // 1. install() idempotency + concurrent invocation

    func test_install_isIdempotent() {
        XCTAssertTrue(UIViewControllerCapture.isInstalled)
        // Calling again must not crash and must remain installed.
        UIViewControllerCapture.install(debug: false)
        UIViewControllerCapture.install(debug: false)
        XCTAssertTrue(UIViewControllerCapture.isInstalled)
    }

    func test_install_concurrentCallsAreSafe() {
        // `install()` bounces to the main thread via
        // `DispatchQueue.main.sync` — if the test blocks main with
        // `DispatchGroup.wait`, the dispatched blocks can never run
        // and the group deadlocks. `XCTestExpectation` + `wait(for:)`
        // pumps the main run loop while waiting so the sync hops
        // resolve and 32 concurrent installs converge through the
        // shared lock.
        let exp = expectation(description: "32 concurrent installs converge")
        exp.expectedFulfillmentCount = 32
        for _ in 0..<32 {
            DispatchQueue.global().async {
                UIViewControllerCapture.install(debug: false)
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 120)
        XCTAssertTrue(UIViewControllerCapture.isInstalled)
    }

    // 2. Base-class swizzle lands on UIViewController

    func test_install_swizzledBaseUIViewControllerIMPDiffersFromSubclassOverride() {
        let baseSelector = #selector(UIViewController.viewDidAppear(_:))

        let baseMethod = class_getInstanceMethod(UIViewController.self, baseSelector)
        XCTAssertNotNil(baseMethod)

        // A subclass that overrides viewDidAppear must keep its own
        // implementation — we only swizzle the base class.
        final class OverridingVC: UIViewController {
            override func viewDidAppear(_ animated: Bool) {
                super.viewDidAppear(animated)
            }
        }
        let subclassMethod = class_getInstanceMethod(OverridingVC.self, baseSelector)
        XCTAssertNotNil(subclassMethod)

        let baseImp = method_getImplementation(baseMethod!)
        let subImp = method_getImplementation(subclassMethod!)
        XCTAssertNotEqual(
            baseImp, subImp,
            "Subclass override must retain its own IMP — the swizzle only replaces UIViewController's base IMP"
        )
    }

    // 3. Vanilla UIViewController emits navigation

    func test_vanillaUIViewController_emitsNavigation() {
        let probe = CaptureProbeRecorder()
        Recorder.installShared(probe)

        let vc = UIViewController()
        vc.viewDidAppear(false)

        let events = probe.calls.compactMap { call -> (String, [String: AttributeValue])? in
            if case let .event(name, attrs) = call { return (name, attrs) }
            return nil
        }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.0, "navigation")
        XCTAssertEqual(events.first?.1["navigation.kind"], .string("uikit"))
        XCTAssertEqual(events.first?.1["navigation.type"], .string("viewDidAppear"))
        XCTAssertNotNil(events.first?.1["navigation.screen"])
    }

    // 4. Container VCs are skipped

    func test_containerControllers_skipNavigation() {
        let probe = CaptureProbeRecorder()
        Recorder.installShared(probe)

        let nav = UINavigationController()
        let tab = UITabBarController()
        let page = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
        nav.viewDidAppear(false)
        tab.viewDidAppear(false)
        page.viewDidAppear(false)

        let navigationEvents = probe.calls.filter {
            if case let .event(name, _) = $0, name == "navigation" { return true }
            return false
        }
        XCTAssertEqual(navigationEvents.count, 0)
    }

    // 5. Name resolution — accessibilityIdentifier wins

    func test_screenName_prefersAccessibilityIdentifier() {
        let probe = CaptureProbeRecorder()
        Recorder.installShared(probe)

        let vc = UIViewController()
        vc.view.accessibilityIdentifier = "Cart"
        vc.viewDidAppear(false)

        guard case let .event(_, attrs) = probe.calls.first else {
            return XCTFail("Expected a navigation event")
        }
        XCTAssertEqual(attrs["navigation.screen"], .string("Cart"))
        XCTAssertEqual(attrs["navigation.kind"], .string("uikit"))
    }

    // 6. Fallback: reflected type name

    func test_screenName_fallsBackToReflectedTypeName() {
        final class TestCheckoutViewController: UIViewController {}

        let probe = CaptureProbeRecorder()
        Recorder.installShared(probe)

        let vc = TestCheckoutViewController()
        vc.viewDidAppear(false)

        guard case let .event(_, attrs) = probe.calls.first else {
            return XCTFail("Expected a navigation event")
        }
        if case let .string(name) = attrs["navigation.screen"] {
            XCTAssertTrue(
                name.contains("TestCheckoutViewController"),
                "expected reflected name to contain 'TestCheckoutViewController', got \(name)"
            )
        } else {
            XCTFail("navigation.screen must be a string")
        }
    }

    // 7. UIHostingController detection

    func test_hostingController_emitsKindSwiftui() {
        struct TestRootView: View {
            var body: some View { Text("hi") }
        }
        let probe = CaptureProbeRecorder()
        Recorder.installShared(probe)

        let vc = UIHostingController(rootView: TestRootView())
        vc.viewDidAppear(false)

        guard case let .event(_, attrs) = probe.calls.first else {
            return XCTFail("Expected a navigation event")
        }
        XCTAssertEqual(attrs["navigation.kind"], .string("swiftui"))
        if case let .string(name) = attrs["navigation.screen"] {
            XCTAssertTrue(
                name.contains("TestRootView"),
                "expected swiftui name to contain TestRootView, got \(name)"
            )
        } else {
            XCTFail("navigation.screen must be a string")
        }
    }

    // 8. previous_screen chains

    func test_previousScreen_chainsAcrossNavigations() {
        let probe = CaptureProbeRecorder()
        Recorder.installShared(probe)

        let a = UIViewController()
        a.view.accessibilityIdentifier = "ScreenA"
        let b = UIViewController()
        b.view.accessibilityIdentifier = "ScreenB"

        a.viewDidAppear(false)
        a.viewWillDisappear(false)
        b.viewDidAppear(false)

        // Find the navigation event for ScreenB.
        let screenBEvent = probe.calls.compactMap { call -> [String: AttributeValue]? in
            if case let .event(name, attrs) = call,
               name == "navigation",
               attrs["navigation.screen"] == .string("ScreenB") {
                return attrs
            }
            return nil
        }.first

        XCTAssertEqual(screenBEvent?["navigation.previous_screen"], .string("ScreenA"))
    }

    func test_firstNavigation_hasNoPreviousScreen() {
        let probe = CaptureProbeRecorder()
        Recorder.installShared(probe)
        UIViewControllerCapture._resetPreviousScreenForTesting()

        let vc = UIViewController()
        vc.view.accessibilityIdentifier = "Home"
        vc.viewDidAppear(false)

        guard case let .event(_, attrs) = probe.calls.first else {
            return XCTFail("Expected a navigation event")
        }
        XCTAssertNil(
            attrs["navigation.previous_screen"],
            "first navigation must omit previous_screen entirely (key absent, not empty string)"
        )
    }

    // 9. screen.duration math

    func test_screenDuration_emitsCorrectMsAndValue() {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_000_000))
        let probe = CaptureProbeRecorder(clock: clock)
        Recorder.installShared(probe)

        let vc = UIViewController()
        vc.view.accessibilityIdentifier = "DwellTest"

        vc.viewDidAppear(false)
        clock.advance(by: 4.3)
        vc.viewWillDisappear(false)

        let metrics = probe.calls.compactMap { call -> (String, [String: AttributeValue])? in
            if case let .performance(name, attrs) = call { return (name, attrs) }
            return nil
        }
        XCTAssertEqual(metrics.count, 1)
        XCTAssertEqual(metrics.first?.0, "screen.duration")
        XCTAssertEqual(metrics.first?.1["screen.name"], .string("DwellTest"))
        XCTAssertEqual(metrics.first?.1["screen.kind"], .string("uikit"))
        XCTAssertEqual(metrics.first?.1["screen.duration_ms"], .int(4300))
        if case let .double(seconds) = metrics.first?.1["value"] {
            XCTAssertEqual(seconds, 4.3, accuracy: 0.001)
        } else {
            XCTFail("value must be a double")
        }
    }

    // 10. viewWillDisappear without a paired appear → no-op

    func test_screenDuration_skippedWithoutPriorAppear() {
        let probe = CaptureProbeRecorder()
        Recorder.installShared(probe)

        let vc = UIViewController()
        vc.viewWillDisappear(false) // no appear first

        let metricCalls = probe.calls.filter {
            if case .performance = $0 { return true }
            return false
        }
        XCTAssertEqual(metricCalls.count, 0)
    }

    // 11. isEnabled gate halts emission

    func test_disable_haltsEmissions() {
        let probe = CaptureProbeRecorder(enabled: false)
        Recorder.installShared(probe)

        let vc = UIViewController()
        vc.view.accessibilityIdentifier = "Quiet"
        vc.viewDidAppear(false)
        vc.viewWillDisappear(false)

        XCTAssertTrue(probe.calls.isEmpty, "Disabled recorder must see zero calls")
    }

    func test_isEnabled_canFlipMidLifecycle() {
        let probe = CaptureProbeRecorder()
        Recorder.installShared(probe)

        let vc = UIViewController()
        vc.view.accessibilityIdentifier = "Toggle"
        vc.viewDidAppear(false) // recorded
        probe.setEnabled(false)
        vc.viewWillDisappear(false) // dropped because disabled

        let events = probe.calls.filter {
            if case .event = $0 { return true }
            return false
        }
        let metrics = probe.calls.filter {
            if case .performance = $0 { return true }
            return false
        }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(metrics.count, 0)
    }

    // 12. install() is the only path to a swap

    func test_install_isNotPerformedWithoutCall() {
        // After install ran (setUp), isInstalled must be true.
        XCTAssertTrue(UIViewControllerCapture.isInstalled)
        // Reset only the flag — the IMP table is untouched; this is
        // strictly a per-test bookkeeping reset.
        UIViewControllerCapture._resetInstallFlagForTesting()
        XCTAssertFalse(UIViewControllerCapture.isInstalled)
        // Re-installing flips it back without re-swapping IMPs in an
        // observable way (idempotency of the actual exchange isn't
        // safe to assert — we only assert the flag).
        UIViewControllerCapture.install(debug: false)
        XCTAssertTrue(UIViewControllerCapture.isInstalled)
    }

    #endif // canImport(UIKit) && os(iOS)
}
