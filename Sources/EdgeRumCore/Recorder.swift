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
    private var sessionManager: SessionManager
    private var transport: TransportSink
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

    /// Re-entrancy guard so synthetic `session.finalized` /
    /// `session.started` emissions during a mid-event rotation don't
    /// re-touch the session manager (which would recurse).
    private var _insideRotationEmission: Bool = false

    // MARK: Init

    public init(
        clock: Clock = SystemClock(),
        sessionManager: SessionManager? = nil,
        sampler: Sampler? = nil,
        transport: TransportSink = NoopTransportSink(),
        payloadBuilder: PayloadBuilder = PayloadBuilder(),
        contextProvider: ContextProvider? = nil,
        sdkVersion: String = "0.0.0",
        identityProvider: IdentityProvider? = nil,
        sidecar: SessionSidecar? = nil
    ) {
        self._clock = clock
        self.queue = DispatchQueue(label: "edge.rum.recorder", qos: .utility)
        let resolvedSessionManager = sessionManager ?? SessionManager(clock: clock)
        self.sessionManager = resolvedSessionManager
        self.sampler = sampler ?? Sampler(sampleRate: 1.0)
        self.transport = transport
        self.payloadBuilder = payloadBuilder
        self.sidecar = sidecar

        let deviceId: String
        let userId: String
        if let identityProvider {
            let snapshot = identityProvider.resolve()
            deviceId = snapshot.deviceId
            userId = snapshot.userId
        } else {
            deviceId = DeviceIdentitySnapshot.newId(at: clock.now)
            userId = UserContextSnapshot.newAnonymousId(at: clock.now)
        }
        self._deviceId = deviceId

        if let provided = contextProvider {
            self.context = provided
        } else {
            // Seed with minimal context so reads pre-configure don't
            // crash; `configure(_:)` will refresh app/device.
            let session = resolvedSessionManager.touch().state
            self.context = ContextProvider(
                app: AppContext(),
                device: DeviceContext(),
                deviceIdentity: DeviceIdentitySnapshot(id: deviceId),
                network: NetworkContext(),
                session: SessionContextSnapshot(session),
                user: UserContextSnapshot(id: userId),
                sdk: SdkContext(version: sdkVersion)
            )
        }
    }

    /// Optional sidecar that mirrors session + identity to a file the
    /// crash backend (F14) reads on next launch. F4 ships the writer;
    /// the reader lives in `EdgeRumCrash`.
    private var sidecar: SessionSidecar?

    /// Production wiring: swap the in-memory IdentityProvider / session
    /// store for Keychain + UserDefaults-backed ones. Called once by
    /// `EdgeRum.start()`. Safe to call again — recomputes the merged
    /// identity from persisted values without rotating the session.
    public func installPersistedStores(
        identityProvider: IdentityProvider,
        sessionStore: SessionStore,
        sidecar: SessionSidecar?
    ) {
        let snapshot = identityProvider.resolve()
        let revivedManager = SessionManager(
            store: sessionStore,
            clock: _clock
        )
        let session = revivedManager.touch().state

        stateLock.lock()
        self.sessionManager = revivedManager
        self._deviceId = snapshot.deviceId
        self.sidecar = sidecar
        stateLock.unlock()

        context.refreshDeviceIdentity(DeviceIdentitySnapshot(id: snapshot.deviceId))
        context.refreshUser(UserContextSnapshot(id: snapshot.userId))
        context.refreshSession(SessionContextSnapshot(session))

        sidecar?.write(snapshot: context.snapshot())
    }

    /// F5 production wiring: swap the in-memory `NoopTransportSink` for
    /// a real HTTP-backed sink. Called once by `EdgeRum.start()` after
    /// `installPersistedStores`. If the sink is an `HTTPTransportSink`
    /// it gets a weak reference back to this Recorder so it can call
    /// `didAckBatch()` on 2xx responses.
    public func installTransport(_ newTransport: TransportSink) {
        stateLock.lock()
        self.transport = newTransport
        stateLock.unlock()
        if let http = newTransport as? HTTPTransportSink {
            http.attach(recorder: self)
        }
    }

    // MARK: Recording

    public var clock: Clock { _clock }

    public var isEnabled: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _enabled
    }

    public var debug: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _config?.debug ?? false
    }

    public var currentSessionId: String {
        context.currentSession().id
    }

    public var currentDeviceId: String {
        context.currentDeviceIdentity().id
    }

    /// Expose the held `ContextProvider` so the F16 `ContextObservers`
    /// installer (and tests) can refresh individual context groups
    /// without going through the Recorder API. Intentionally typed as
    /// the concrete `ContextProvider` because that's the only
    /// implementation; if alternative providers ever land this will
    /// move behind a protocol.
    public var currentContextProvider: ContextProvider {
        context
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
        // T5.5 — re-roll the per-session sampler so the new session
        // gets its own in/out decision rather than inheriting the
        // configure() roll.
        if let rate = _config?.sampleRate {
            self.sampler = Sampler(sampleRate: rate)
        }
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

        bumpLastActiveAndEmitRotationIfNeeded()

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
        bumpLastActiveAndEmitRotationIfNeeded()
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
        let currentTransport = transport
        stateLock.unlock()

        guard !events.isEmpty else { return }

        let envelope = payloadBuilder.build(
            events: events,
            context: context.snapshot(),
            location: location,
            flushTime: clock.now
        )
        currentTransport.send(envelope, reason: reason)
    }

    /// Forward an offline-queue drain request to the installed
    /// transport. Called from `EdgeRum.enable()` and F11's
    /// `didBecomeActive` lifecycle hook.
    public func drainOfflineQueue() {
        stateLock.lock()
        let currentTransport = transport
        stateLock.unlock()
        currentTransport.drainOfflineQueue()
    }

    /// Refresh the in-memory `NetworkContext` so subsequent events
    /// carry the new `network.type` / `network.effectiveType` /
    /// derived flags. F11's `NetworkPathCapture` calls this from its
    /// `NWPathMonitor` callback before emitting the `network_change`
    /// event so the event itself rides under the refreshed context.
    public func refreshNetworkContext(_ network: NetworkContext) {
        context.refreshNetwork(network)
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

    /// Called by the transport layer after a successful (`2xx`) batch
    /// flush. Increments `session.sequence` under the SessionManager's
    /// lock and refreshes the context so subsequent events carry the
    /// new sequence value.
    ///
    /// Acceptance #43: three consecutive ACKed batches → an event
    /// emitted after the third ACK reads `session.sequence == 3`.
    public func didAckBatch() {
        sessionManager.incrementSequence()
        if let state = sessionManager.currentState() {
            context.refreshSession(SessionContextSnapshot(state))
            sidecar?.write(snapshot: context.snapshot())
        }
    }

    // MARK: Internals

    /// Update the session's `lastActiveAt` to "now" and, if the touch
    /// crossed the 30-min idle threshold, emit the
    /// `session.finalized` → `session.started` rotation pair for the
    /// prior and new sessions respectively. Synthetic emissions go
    /// through `recordEventInternal` which skips this hook to avoid
    /// re-entry.
    private func bumpLastActiveAndEmitRotationIfNeeded() {
        stateLock.lock()
        if _insideRotationEmission {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        let prior = context.currentSession()
        let result = sessionManager.touch()
        guard result.rotated else { return }
        let priorSession = prior
        let newSnapshot = SessionContextSnapshot(result.state)

        stateLock.lock()
        _insideRotationEmission = true
        // T5.5 — re-roll the sampler so the new session has its own
        // in/out decision instead of inheriting the prior session's
        // roll. Idle rotation crosses a session boundary, so per-spec
        // (§9.6 "per-session uniform random") the decision is fresh.
        if let rate = _config?.sampleRate {
            self.sampler = Sampler(sampleRate: rate)
        }
        stateLock.unlock()
        defer {
            stateLock.lock()
            _insideRotationEmission = false
            stateLock.unlock()
        }

        // The prior session's identity needs to ride with the
        // `session.finalized` event since the context is about to
        // refresh to the new session before the buffer's next flush.
        var finalizedAttrs: [String: AttributeValue] = [
            "session.id": .string(priorSession.id),
            "session.start_time": .string(WireDateFormatter.string(from: priorSession.startTime)),
            "session.sequence": .int(priorSession.sequence)
        ]
        finalizedAttrs["session.rotation"] = .string("idle")
        recordEventInternal(name: "session.finalized", attributes: finalizedAttrs)

        context.refreshSession(newSnapshot)

        recordEventInternal(name: "session.started", attributes: ["session.rotation": .string("idle")])
    }

    /// Bypass-touch event emission used by the rotation hook.
    private func recordEventInternal(name: String, attributes: [String: AttributeValue]) {
        guard Self.allowedEventNames.contains(name) else { return }
        let now = clock.now
        let event = Event.event(name: name, timestamp: now, attributes: AttributeBag(attributes))
        enqueue(event)
        if name == "session.finalized" || name == "app.crash" {
            flush(reason: .immediate)
        }
    }

    private func enqueue(_ event: Event) {
        stateLock.lock()
        _buffer.append(event)
        let count = _buffer.count
        let cap = _config?.batchSize ?? 30
        let sidecar = self.sidecar
        stateLock.unlock()
        sidecar?.write(snapshot: context.snapshot())
        if count >= cap {
            flush(reason: .batchSize)
        }
    }
}
