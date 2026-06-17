// Tests/EdgeRumTests/Helpers/ProbeRecorder.swift
//
// Shared `Recording` test double used by `EdgeRumAPITests` and
// `RumTimerTests`. Captures every call so tests can assert routing
// without booting the full F3 Recorder pipeline (which would touch
// `Bundle.main`, `UIDevice`, `NWPathMonitor`, etc.).
//
// Lives in the test target so the production Recorder doesn't carry
// any test-only code.
//

import Foundation
import EdgeRumCore

internal final class ProbeRecorder: Recording, @unchecked Sendable {

    private let lock = NSLock()
    private var _calls: [RecordedCall] = []
    private var _enabled: Bool = false
    private var _config: RecorderConfig?

    private let _clock: Clock
    private let _sessionId: String
    private let _deviceId: String

    internal init(
        clock: Clock = SystemClock(),
        sessionId: String = "session_0_0000000000000000_ios",
        deviceId: String = "device_0_0000000000000000_ios"
    ) {
        self._clock = clock
        self._sessionId = sessionId
        self._deviceId = deviceId
    }

    internal var calls: [RecordedCall] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    internal var configuredWith: RecorderConfig? {
        lock.lock(); defer { lock.unlock() }
        return _config
    }

    internal var clock: Clock { _clock }
    internal var currentSessionId: String { _sessionId }
    internal var currentDeviceId: String { _deviceId }

    internal var isEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _enabled
    }

    internal func configure(_ config: RecorderConfig) {
        lock.lock(); _config = config; lock.unlock()
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

    internal func setUser(_ user: RecorderUser) {
        lock.lock()
        _calls.append(.setUser(user))
        lock.unlock()
    }
}
