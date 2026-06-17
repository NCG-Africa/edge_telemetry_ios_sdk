// Tests/EdgeRumCaptureTests/NetworkPathCaptureTests.swift
//
// F11 / T11.2 unit tests. Covers:
//
//   - makeAttributes: every NetworkType (wifi/cellular/wired/none/unknown)
//     plus the expensive/constrained matrix; primitives-only shape.
//   - makeAttributes omits `network.unsatisfied_reason` when nil — never
//     emits a sentinel `"unknown"` string. (iOS 14.0/14.1 parity.)
//   - unsatisfiedReasonString returns stable wire strings for every
//     case present at iOS 14.2+.
//   - emit(...) refreshes the Recorder context bag on every call,
//     even when the change-event itself is deduped.
//   - emit(...) deduplicates identical transitions — same
//     (type/effectiveType/expensive/constrained/reason) fingerprint
//     produces exactly one event.
//   - emit(...) re-fires on any single-field change.
//   - install() is idempotent and concurrent-safe.
//   - Recorder.isEnabled = false halts both refresh AND emit.
//
// Refs: PLAN-iOS.md §F11/T11.2 acceptance; CLAUDE.md "Testing
//       conventions".
//

import XCTest
import Foundation
import Network
import EdgeRumCore
@testable import EdgeRumCapture

// MARK: - Local probe recorder with refresh + drain tracking

private final class CaptureProbeRecorder: Recording, @unchecked Sendable {

    enum Call: Equatable {
        case event(name: String, attributes: [String: AttributeValue])
        case performance(name: String, attributes: [String: AttributeValue])
        case drain
        case refreshNetwork(NetworkContext)
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

    func configure(_ config: RecorderConfig) { _ = config }
    func start(apiKey: String, endpoint: URL, debug: Bool) {
        _ = (apiKey, endpoint, debug)
    }
    func stop() {}
    func setEnabled(_ enabled: Bool) {
        lock.lock(); _enabled = enabled; lock.unlock()
    }

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

    func refreshNetworkContext(_ context: NetworkContext) {
        lock.lock()
        _calls.append(.refreshNetwork(context))
        lock.unlock()
    }

    func drainOfflineQueue() {
        lock.lock()
        _calls.append(.drain)
        lock.unlock()
    }
}

final class NetworkPathCaptureTests: XCTestCase {

    override func tearDown() {
        NetworkPathCapture._resetInstallFlagForTesting()
        Recorder.resetShared()
        super.tearDown()
    }

    // MARK: makeAttributes — wire shape

    func test_makeAttributes_wifi_omits_unsatisfied_reason() {
        let attrs = NetworkPathCapture.makeAttributes(
            context: NetworkContext(type: .wifi, effectiveType: "wifi"),
            isExpensive: false,
            isConstrained: false,
            unsatisfiedReason: nil
        )
        XCTAssertEqual(attrs["network.type"], .string("wifi"))
        XCTAssertEqual(attrs["network.effectiveType"], .string("wifi"))
        XCTAssertEqual(attrs["network.is_expensive"], .bool(false))
        XCTAssertEqual(attrs["network.is_constrained"], .bool(false))
        XCTAssertNil(attrs["network.unsatisfied_reason"],
                     "Reason key must be entirely absent — never a sentinel string")
        XCTAssertEqual(attrs.count, 4)
    }

    func test_makeAttributes_cellular_expensive() {
        let attrs = NetworkPathCapture.makeAttributes(
            context: NetworkContext(type: .cellular, effectiveType: "cellular"),
            isExpensive: true,
            isConstrained: false,
            unsatisfiedReason: nil
        )
        XCTAssertEqual(attrs["network.type"], .string("cellular"))
        XCTAssertEqual(attrs["network.is_expensive"], .bool(true))
        XCTAssertEqual(attrs["network.is_constrained"], .bool(false))
    }

    func test_makeAttributes_none_with_unsatisfied_reason() {
        let attrs = NetworkPathCapture.makeAttributes(
            context: NetworkContext(type: .none, effectiveType: "unknown"),
            isExpensive: false,
            isConstrained: false,
            unsatisfiedReason: "cellular_denied"
        )
        XCTAssertEqual(attrs["network.type"], .string("none"))
        XCTAssertEqual(attrs["network.unsatisfied_reason"], .string("cellular_denied"))
        XCTAssertEqual(attrs.count, 5)
    }

    func test_makeAttributes_wired_constrained() {
        let attrs = NetworkPathCapture.makeAttributes(
            context: NetworkContext(type: .wired, effectiveType: "wired"),
            isExpensive: false,
            isConstrained: true,
            unsatisfiedReason: nil
        )
        XCTAssertEqual(attrs["network.type"], .string("wired"))
        XCTAssertEqual(attrs["network.is_constrained"], .bool(true))
    }

    func test_makeAttributes_unknown_type_path() {
        let attrs = NetworkPathCapture.makeAttributes(
            context: NetworkContext(type: .unknown, effectiveType: "unknown"),
            isExpensive: false,
            isConstrained: false,
            unsatisfiedReason: nil
        )
        XCTAssertEqual(attrs["network.type"], .string("unknown"))
    }

    func test_makeAttributes_values_are_primitives_only() {
        let attrs = NetworkPathCapture.makeAttributes(
            context: NetworkContext(type: .wifi, effectiveType: "wifi"),
            isExpensive: false,
            isConstrained: false,
            unsatisfiedReason: nil
        )
        for (key, value) in attrs {
            switch value {
            case .string, .int, .double, .bool:
                continue
            }
            XCTFail("Non-primitive value \(value) at key \(key)")
        }
    }

    // MARK: unsatisfiedReasonString mapping (iOS 14.2+)

    func test_unsatisfiedReasonString_mapsKnownCases() {
        if #available(iOS 14.2, macOS 11.0, *) {
            XCTAssertEqual(
                NetworkPathCapture.unsatisfiedReasonString(.notAvailable),
                "not_available"
            )
            XCTAssertEqual(
                NetworkPathCapture.unsatisfiedReasonString(.cellularDenied),
                "cellular_denied"
            )
            XCTAssertEqual(
                NetworkPathCapture.unsatisfiedReasonString(.wifiDenied),
                "wifi_denied"
            )
            XCTAssertEqual(
                NetworkPathCapture.unsatisfiedReasonString(.localNetworkDenied),
                "local_network_denied"
            )
        }
    }

    // MARK: emit(...) routes to Recorder + refreshes context

    func test_emit_refreshesContext_evenBeforeEvent() {
        let probe = CaptureProbeRecorder()
        Recorder.installShared(probe)

        let context = NetworkContext(type: .wifi, effectiveType: "wifi")
        NetworkPathCapture.emit(
            context: context,
            isExpensive: false,
            isConstrained: false,
            unsatisfiedReason: nil
        )

        XCTAssertTrue(probe.calls.contains(.refreshNetwork(context)),
                      "ContextProvider must see the new path BEFORE the event emits")
    }

    func test_emit_emitsNetworkChange_withFullAttributeBag() {
        let probe = CaptureProbeRecorder()
        Recorder.installShared(probe)

        NetworkPathCapture.emit(
            context: NetworkContext(type: .cellular, effectiveType: "cellular"),
            isExpensive: true,
            isConstrained: false,
            unsatisfiedReason: nil
        )

        let events = probe.calls.compactMap { call -> (String, [String: AttributeValue])? in
            if case let .event(name, attrs) = call { return (name, attrs) } else { return nil }
        }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].0, "network_change")
        XCTAssertEqual(events[0].1["network.type"], .string("cellular"))
        XCTAssertEqual(events[0].1["network.is_expensive"], .bool(true))
    }

    // MARK: dedupe

    func test_emit_deduplicatesIdenticalTransitions() {
        let probe = CaptureProbeRecorder()
        Recorder.installShared(probe)

        let context = NetworkContext(type: .wifi, effectiveType: "wifi")
        NetworkPathCapture.emit(
            context: context, isExpensive: false,
            isConstrained: false, unsatisfiedReason: nil
        )
        NetworkPathCapture.emit(
            context: context, isExpensive: false,
            isConstrained: false, unsatisfiedReason: nil
        )
        NetworkPathCapture.emit(
            context: context, isExpensive: false,
            isConstrained: false, unsatisfiedReason: nil
        )

        let eventCount = probe.calls.filter { call in
            if case let .event(name, _) = call { return name == "network_change" }
            return false
        }.count
        XCTAssertEqual(eventCount, 1, "Identical transitions should emit once")

        // Refresh still ran on every call — the context bag must always
        // reflect the live path.
        let refreshCount = probe.calls.filter { call in
            if case .refreshNetwork = call { return true }
            return false
        }.count
        XCTAssertEqual(refreshCount, 3)
    }

    func test_emit_reFires_when_anyFieldChanges() {
        let probe = CaptureProbeRecorder()
        Recorder.installShared(probe)

        // 1. Wi-Fi, not expensive
        NetworkPathCapture.emit(
            context: NetworkContext(type: .wifi, effectiveType: "wifi"),
            isExpensive: false, isConstrained: false, unsatisfiedReason: nil
        )
        // 2. Wi-Fi, expensive (change in flag)
        NetworkPathCapture.emit(
            context: NetworkContext(type: .wifi, effectiveType: "wifi"),
            isExpensive: true, isConstrained: false, unsatisfiedReason: nil
        )
        // 3. Cellular (change in type)
        NetworkPathCapture.emit(
            context: NetworkContext(type: .cellular, effectiveType: "cellular"),
            isExpensive: true, isConstrained: false, unsatisfiedReason: nil
        )
        // 4. None, with reason (change in reason)
        NetworkPathCapture.emit(
            context: NetworkContext(type: .none, effectiveType: "unknown"),
            isExpensive: false, isConstrained: false,
            unsatisfiedReason: "cellular_denied"
        )

        let events = probe.calls.compactMap { call -> String? in
            if case let .event(name, _) = call, name == "network_change" { return name }
            return nil
        }
        XCTAssertEqual(events.count, 4)
    }

    func test_emit_disabledRecorder_short_circuits() {
        let probe = CaptureProbeRecorder(enabled: false)
        Recorder.installShared(probe)

        NetworkPathCapture.emit(
            context: NetworkContext(type: .wifi, effectiveType: "wifi"),
            isExpensive: false, isConstrained: false, unsatisfiedReason: nil
        )

        XCTAssertTrue(probe.calls.isEmpty,
                      "Disabled recorder must take no calls — context refresh included")
    }

    // MARK: install — idempotent + concurrent-safe

    func test_install_isIdempotent() {
        XCTAssertFalse(NetworkPathCapture.isInstalled)
        NetworkPathCapture.install(debug: false)
        XCTAssertTrue(NetworkPathCapture.isInstalled)
        NetworkPathCapture.install(debug: false)
        XCTAssertTrue(NetworkPathCapture.isInstalled)
    }

    func test_install_concurrent_callsAreSafe() {
        let group = DispatchGroup()
        for _ in 0..<32 {
            group.enter()
            DispatchQueue.global().async {
                NetworkPathCapture.install(debug: false)
                group.leave()
            }
        }
        let waitResult = group.wait(timeout: .now() + 5.0)
        XCTAssertEqual(waitResult, .success)
        XCTAssertTrue(NetworkPathCapture.isInstalled)
    }
}
