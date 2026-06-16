// Sources/EdgeRumCore/Recorder.swift
//
// F2 stub of the internal Recorder.
//
// The real fan-in Recorder lands with F3 — context merging, batching,
// transport, offline queue, etc. This stub exists so the public
// surface (F2) routes through a stable seam: every public method on
// `EdgeRum` calls into `Recorder.shared`, and F3 swaps the
// implementation behind `installShared(_:)` without touching the
// public umbrella module.
//
// What this stub *does* provide:
//
// 1. Thread-safe in-memory buffer of recorded calls. Tests inspect
//    the buffer to assert routing — "did `EdgeRum.track(...)` reach
//    the recorder with the expected name and attributes?".
// 2. Synthetic but format-correct `sessionId` / `deviceId` strings
//    matching the prefix contract from CLAUDE.md §"Session and ID
//    rules". The real values land in F4.
// 3. A swap point (`installShared(_:)`) so tests can install a
//    `ProbeRecorder` for the duration of a test and restore the real
//    one in `tearDown`.
//
// Refs: PLAN-iOS.md §F2/T2.1, §F3, §F4; CLAUDE.md
//       "Session and ID rules".
//

import Foundation

/// A single record of an API call routed through the recorder.
///
/// Tests pattern-match on these — see `Tests/EdgeRumTests`.
public enum RecordedCall: Sendable, Equatable {
    case start(apiKey: String, endpoint: URL, debug: Bool)
    case stop
    case setEnabled(Bool)
    case event(name: String, attributes: [String: AttributeValue])
    case performance(name: String, attributes: [String: AttributeValue])
    case error(domain: String, code: Int, message: String?, context: [String: AttributeValue])
    case setUser(RecorderUser)
}

public final class Recorder: Recording, @unchecked Sendable {

    // MARK: Shared instance (mutable so tests can swap a probe in)

    private static let _sharedLock = NSLock()
    nonisolated(unsafe) private static var _shared: Recording = Recorder()

    public static var shared: Recording {
        _sharedLock.lock(); defer { _sharedLock.unlock() }
        return _shared
    }

    /// Swap the shared recorder for the duration of a test. Returns
    /// the previously installed instance so the caller can restore
    /// it in `tearDown`. Intended for tests only.
    @discardableResult
    public static func installShared(_ new: Recording) -> Recording {
        _sharedLock.lock(); defer { _sharedLock.unlock() }
        let previous = _shared
        _shared = new
        return previous
    }

    /// Restore the default Recorder. Companion to `installShared`.
    public static func resetShared() {
        installShared(Recorder())
    }

    // MARK: Stored state

    private let stateLock = NSLock()
    private var _enabled: Bool = false
    private var _calls: [RecordedCall] = []
    private let _sessionId: String
    private let _deviceId: String
    private let _clock: Clock

    public init(clock: Clock = SystemClock()) {
        self._clock = clock
        // Synthetic IDs in the documented prefix shape — see
        // CLAUDE.md "Session and ID rules". F4 replaces these with
        // SecRandomCopyBytes-backed values persisted in Keychain
        // / UserDefaults.
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        self._sessionId = "session_\(stamp)_0000000000000000_ios"
        self._deviceId = "device_\(stamp)_0000000000000000_ios"
    }

    // MARK: Recording

    public var clock: Clock { _clock }

    public var isEnabled: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _enabled
    }

    public var currentSessionId: String {
        stateLock.lock(); defer { stateLock.unlock() }
        return _sessionId
    }

    public var currentDeviceId: String {
        stateLock.lock(); defer { stateLock.unlock() }
        return _deviceId
    }

    public func start(apiKey: String, endpoint: URL, debug: Bool) {
        stateLock.lock()
        _enabled = true
        _calls.append(.start(apiKey: apiKey, endpoint: endpoint, debug: debug))
        stateLock.unlock()
    }

    public func stop() {
        stateLock.lock()
        _enabled = false
        _calls.append(.stop)
        stateLock.unlock()
    }

    public func setEnabled(_ enabled: Bool) {
        stateLock.lock()
        _enabled = enabled
        _calls.append(.setEnabled(enabled))
        stateLock.unlock()
    }

    public func recordEvent(name: String, attributes: [String: AttributeValue]) {
        stateLock.lock()
        _calls.append(.event(name: name, attributes: attributes))
        stateLock.unlock()
    }

    public func recordPerformance(name: String, attributes: [String: AttributeValue]) {
        stateLock.lock()
        _calls.append(.performance(name: name, attributes: attributes))
        stateLock.unlock()
    }

    public func recordError(domain: String, code: Int, message: String?, context: [String: AttributeValue]) {
        stateLock.lock()
        _calls.append(.error(domain: domain, code: code, message: message, context: context))
        stateLock.unlock()
    }

    public func setUser(_ user: RecorderUser) {
        stateLock.lock()
        _calls.append(.setUser(user))
        stateLock.unlock()
    }

    // MARK: Test inspection

    public var recordedCalls: [RecordedCall] {
        stateLock.lock(); defer { stateLock.unlock() }
        return _calls
    }
}
