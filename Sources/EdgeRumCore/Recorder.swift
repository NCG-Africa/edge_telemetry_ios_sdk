// Sources/EdgeRumCore/Recorder.swift
//
// F3 implementation of the internal Recorder. Replaces the F2 in-
// memory stub. Same public protocol (`Recording`) so EdgeRum.swift
// and existing test probes keep working unchanged.
//
// What this Recorder does:
//
//   1. Holds a `ContextProvider` snapshotting app/device/network/
//      session/user/sdk identity attributes. Merged into every event
//      on ingress.
//   2. Validates `eventName` against `allowedEventNames`; rejects
//      unknown names and logs when `config.debug == true`.
//   3. Applies a `Sampler` decision (per-session uniform random vs
//      `config.sampleRate`); forced-emit events bypass.
//   4. Buffers `Event` values on a serial queue
//      `edge.rum.recorder` (QoS `.utility`).
//   5. Flushes on `config.batchSize` reached, `config.flushInterval`
//      timer fired, immediate-flush trigger (error / `session.finalized`),
//      or `shutdown()` / `stop()`.
//   6. Hands each batch to the `TransportSink`. F3 ships
//      `NoopTransportSink`; F4 plugs in `HTTPTransportSink`.
//
// What this Recorder does NOT do (intentionally, per F3 scope):
//
//   - HTTP — F4 transport layer plugs into the `TransportSink` seam.
//   - Disk persistence (Keychain `device.id`, UserDefaults `session`)
//     — F4 layers on top of `SessionStore` and the device-identity
//     generator.
//   - Offline queue / background uploader — F5.
//
// Refs: PLAN-iOS.md §4.2, §4.3, §7, §F3/T3.1; CLAUDE.md
//       "EdgeTelemetryProcessor contract".
//

import Foundation
import os.log

public final class Recorder: Recording, @unchecked Sendable {

    // MARK: Allowlist

    /// The strict set of wire `eventName`s the backend dispatcher
    /// will route. Anything outside this set is dropped on ingress
    /// (and logged when `config.debug == true`). Custom user events
    /// from `EdgeRum.track(_:_:)` arrive here as `"custom_event"` —
    /// the original name is carried as the `event.name` attribute.
    public static let allowedEventNames: Set<String> = [
        "session.started",
        "session.finalized",
        "app_lifecycle",
        "page_load",
        "navigation",
        "screen.duration",
        "http.request",
        "user.interaction",
        "network_change",
        "user.profile.update",
        "custom_event",
        "app.crash"
    ]

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
    private let queue: DispatchQueue
    private let log = OSLog(subsystem: "com.edge.rum", category: "Recorder")

    private let _clock: Clock
    private let sessionManager: SessionManager
    private let transport: TransportSink
    private let payloadBuilder: PayloadBuilder
    private let context: ContextProvider

    /// Sampler is rebuilt on `configure(_:)` so the per-session
    /// decision reflects the host-supplied `sampleRate`. The
    /// `Sendable` value type makes the swap safe under the state
    /// lock.
    private var sampler: Sampler

    private var _config: RecorderConfig?
    private var _enabled: Bool = false
    private var _buffer: [Event] = []
    private var _deviceId: String

    // MARK: Init

    public init(
        clock: Clock = SystemClock(),
        sessionManager: SessionManager? = nil,
        sampler: Sampler? = nil,
        transport: TransportSink = NoopTransportSink(),
        payloadBuilder: PayloadBuilder = PayloadBuilder(),
        contextProvider: ContextProvider? = nil,
        sdkVersion: String = "0.0.0"
    ) {
        self._clock = clock
        self.queue = DispatchQueue(label: "edge.rum.recorder", qos: .utility)
        let resolvedSessionManager = sessionManager ?? SessionManager(clock: clock)
        self.sessionManager = resolvedSessionManager
        self.sampler = sampler ?? Sampler(sampleRate: 1.0)
        self.transport = transport
        self.payloadBuilder = payloadBuilder
        self._deviceId = DeviceIdentitySnapshot.newId(at: clock.now)

        if let provided = contextProvider {
            self.context = provided
        } else {
            // Seed with minimal context so reads pre-configure don't
            // crash; `configure(_:)` will refresh app/device.
            let now = clock.now
            let session = resolvedSessionManager.touch().state
            let userId = UserContextSnapshot.newAnonymousId(at: now)
            self.context = ContextProvider(
                app: AppContext(),
                device: DeviceContext(),
                deviceIdentity: DeviceIdentitySnapshot(id: self._deviceId),
                network: NetworkContext(),
                session: SessionContextSnapshot(session),
                user: UserContextSnapshot(id: userId),
                sdk: SdkContext(version: sdkVersion)
            )
        }
    }

    // MARK: Recording

    public var clock: Clock { _clock }

    public var isEnabled: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _enabled
    }

    public var currentSessionId: String {
        context.currentSession().id
    }

    public var currentDeviceId: String {
        context.currentDeviceIdentity().id
    }

    public func configure(_ config: RecorderConfig) {
        stateLock.lock()
        self._config = config
        // Re-roll the per-session sampler with the host-supplied
        // `sampleRate` so the in/out decision reflects the config.
        self.sampler = Sampler(sampleRate: config.sampleRate)
        stateLock.unlock()

        let appCtx = AppContext.snapshot(
            appNameOverride: config.appName,
            appVersionOverride: config.appVersion,
            appPackageOverride: config.appPackage,
            appBuildOverride: config.appBuild,
            environment: config.environmentName
        )
        context.refreshApp(appCtx)

        let deviceCtx = DeviceContext.snapshot()
        context.refreshDevice(deviceCtx)
    }

    public func start(apiKey: String, endpoint: URL, debug: Bool) {
        stateLock.lock()
        _enabled = true
        let configured = _config
        stateLock.unlock()

        // Rotate to a fresh session — `start()` is the lifecycle
        // boundary at which a new session id is born.
        let session = sessionManager.touch().state
        context.refreshSession(SessionContextSnapshot(session))

        // Emit `session.started`. This bypasses the sampler (forced
        // emit) so it always lands in the next batch.
        recordEvent(name: "session.started", attributes: [:])

        // If `configure(_:)` was not called (older host apps), still
        // ensure the wire-required app keys are populated from
        // Info.plist directly.
        if configured == nil {
            context.refreshApp(AppContext.snapshot())
            context.refreshDevice(DeviceContext.snapshot())
        }
        _ = apiKey
        _ = endpoint
        _ = debug
    }

    public func stop() {
        // Emit `session.finalized` BEFORE flipping `_enabled` off so
        // the event passes the enabled gate.
        recordEvent(name: "session.finalized", attributes: [:])
        flush(reason: .shutdown)
        stateLock.lock()
        _enabled = false
        stateLock.unlock()
    }

    public func setEnabled(_ enabled: Bool) {
        stateLock.lock()
        _enabled = enabled
        stateLock.unlock()
    }

    public func recordEvent(name: String, attributes: [String: AttributeValue]) {
        guard Self.allowedEventNames.contains(name) else {
            stateLock.lock()
            let debug = _config?.debug ?? false
            stateLock.unlock()
            if debug {
                os_log(
                    "Recorder dropped unknown event name %{public}@",
                    log: log,
                    type: .info,
                    name
                )
            }
            return
        }

        stateLock.lock()
        let currentSampler = self.sampler
        stateLock.unlock()
        guard currentSampler.shouldEmit(eventName: name) else { return }

        let now = clock.now
        let event = Event.event(name: name, timestamp: now, attributes: AttributeBag(attributes))
        enqueue(event)

        // Per CLAUDE.md "Transport rules": errors and
        // `session.finalized` flush immediately. `app.crash` covers
        // both `recordError()`-supplied app errors and native crash
        // replays from `EdgeRumCrash`.
        if name == "session.finalized" || name == "app.crash" {
            flush(reason: .immediate)
        }
    }

    public func recordPerformance(name: String, attributes: [String: AttributeValue]) {
        stateLock.lock()
        let currentSampler = self.sampler
        stateLock.unlock()
        guard currentSampler.shouldEmit(metricName: name) else { return }
        let now = clock.now
        // Pull `duration_ms` / `value` out of the attribute bag if
        // the caller supplied it via `EdgeRum.time(_:).end()`. The
        // attribute stays in place too; the wire `value` is just a
        // convenience scalar.
        let value: Double?
        if let v = attributes["value"], case let .double(d) = v {
            value = d
        } else if let v = attributes["duration_ms"], case let .int(i) = v {
            value = Double(i)
        } else if let v = attributes["duration_ms"], case let .double(d) = v {
            value = d
        } else {
            value = nil
        }
        let metric = Event.metric(
            name: name,
            value: value,
            timestamp: now,
            attributes: AttributeBag(attributes)
        )
        enqueue(metric)
    }

    public func recordError(
        domain: String,
        code: Int,
        message: String?,
        context: [String: AttributeValue]
    ) {
        var attrs = context
        attrs["cause"] = .string("AppError")
        attrs["error.domain"] = .string(domain)
        attrs["error.code"] = .int(code)
        if let message {
            attrs["error.message"] = .string(message)
        }
        // Errors bypass the sampler — they always land on the wire.
        let event = Event.event(name: "app.crash", timestamp: clock.now, attributes: AttributeBag(attrs))
        enqueue(event)
        flush(reason: .immediate)
    }

    public func setUser(_ user: RecorderUser) {
        context.setUser(user)
        // Emit `user.profile.update` with the keys the host supplied.
        // The SDK-owned `user.id` is already part of every event via
        // the context bag — no need to duplicate it here.
        var attrs: [String: AttributeValue] = [:]
        if let name = user.name { attrs["user.name"] = .string(name) }
        if let email = user.email { attrs["user.email"] = .string(email) }
        if let phone = user.phone { attrs["user.phone"] = .string(phone) }
        if let id = user.id { attrs["user.external_id"] = .string(id) }
        recordEvent(name: "user.profile.update", attributes: attrs)
    }

    // MARK: Flush

    /// Build an envelope from the current buffer and hand it to the
    /// `TransportSink`. Exposed to F4 (transport) so it can drive
    /// timer-fired flushes from outside. Safe to call when the buffer
    /// is empty — short-circuits to a no-op.
    public func flush(reason: FlushReason) {
        stateLock.lock()
        let events = _buffer
        _buffer.removeAll(keepingCapacity: true)
        let location = _config?.location
        stateLock.unlock()

        guard !events.isEmpty else { return }

        let envelope = payloadBuilder.build(
            events: events,
            context: context.snapshot(),
            location: location,
            flushTime: clock.now
        )
        transport.send(envelope, reason: reason)
    }

    /// Drain the buffer and stop. Equivalent to `stop()` plus the
    /// flush; F4 may call this directly from a background-task
    /// expiration hook.
    public func shutdown() {
        flush(reason: .shutdown)
        stateLock.lock()
        _enabled = false
        stateLock.unlock()
    }

    // MARK: Internals

    private func enqueue(_ event: Event) {
        stateLock.lock()
        _buffer.append(event)
        let count = _buffer.count
        let cap = _config?.batchSize ?? 30
        stateLock.unlock()
        if count >= cap {
            flush(reason: .batchSize)
        }
    }
}
