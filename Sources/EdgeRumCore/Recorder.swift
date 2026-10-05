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
//   4. Buffers `Event` values under `stateLock`. Ingress, merge and
//      flush run synchronously on the caller's thread (main for taps
//      and `viewDidAppear`); the transport hops to its own queue for
//      encode + POST.
//   5. Flushes on `config.batchSize` reached, `config.flushInterval`
//      timer fired (armed while enabled, on a global utility queue),
//      immediate-flush trigger (`app.crash` / `session.finalized`), or
//      `shutdown()` / `stop()`.
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
        "http.request",
        "user.interaction",
        "network_change",
        "user.profile.update",
        "custom_event",
        "app.error",
        "app.hang",
        "app.crash"
    ]

    /// The bounded `metricName` space (F29). `recordPerformance`
    /// rejects anything else; host timers arrive as `custom_timer`
    /// with the host's name in `timer.name`.
    public static let allowedMetricNames: Set<String> = [
        "resource_timing",
        "long_task",
        "frame_render_time",
        "memory_usage",
        "cpu_usage",
        "custom_timer"
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
    private let sidecarLock = NSLock()
    private let log = OSLog(subsystem: "com.edge.rum", category: "Recorder")

    private let _clock: Clock
    private var sessionManager: SessionManager
    private var transport: TransportSink
    private let payloadBuilder: PayloadBuilder
    private let context: ContextProvider
    private let riders: Riders

    /// Sampler is rebuilt on `configure(_:)` so the per-session
    /// decision reflects the host-supplied `sampleRate`. The
    /// `Sendable` value type makes the swap safe under the state
    /// lock.
    private var sampler: Sampler

    private var _config: RecorderConfig?
    private var _enabled: Bool = false
    private var _buffer: [Event] = []
    private var _deviceId: String

    /// Persisted identity store, kept so `resetIdentity()` regenerates
    /// the persisted ids. `nil` until `installPersistedStores`.
    private var identityProvider: IdentityProvider?

    /// `session.finalized` for a session found expired at
    /// `installPersistedStores`, emitted by `start()`.
    private var _pendingFinalized: [String: AttributeValue]?

    /// Re-entrancy guard so synthetic `session.finalized` /
    /// `session.started` emissions during a mid-event rotation don't
    /// re-touch the session manager (which would recurse).
    private var _insideRotationEmission: Bool = false

    /// `flushInterval` timer. Armed while enabled; cancelled by
    /// `setEnabled(false)` / `stop()` / `shutdown()`.
    private var flushTimer: DispatchSourceTimer?

    /// `sdk.thread_time_ms` accumulator — caller-thread wall-time spent
    /// inside `recordEvent` / `recordPerformance` for the current
    /// session. Reset at every session boundary.
    // ponytail: measures the two ingress points only; setUser/configure
    // cost is outside it. Widen with a reentrancy-aware scope if needed.
    private var _threadTimeNs: UInt64 = 0

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
        sidecar: SessionSidecarWriting? = nil,
        riders: Riders = .shared
    ) {
        self._clock = clock
        self.riders = riders
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

    deinit { flushTimer?.cancel() }

    /// Optional sidecar that mirrors session + identity to a file the
    /// crash backend (F14) reads on next launch. F4 ships the writer;
    /// the reader lives in `EdgeRumCrash`.
    private var sidecar: SessionSidecarWriting?

    /// Production wiring: swap the in-memory IdentityProvider / session
    /// store for Keychain + UserDefaults-backed ones. Called once by
    /// `EdgeRum.start()`. Safe to call again — recomputes the merged
    /// identity from persisted values without rotating the session.
    public func installPersistedStores(
        identityProvider: IdentityProvider,
        sessionStore: SessionStore,
        sidecar: SessionSidecarWriting?
    ) {
        let snapshot = identityProvider.resolve()
        let revivedManager = SessionManager(
            store: sessionStore,
            clock: _clock
        )
        let touched = revivedManager.touch()
        let session = touched.state

        stateLock.lock()
        // The previous launch's session expired while the app was not
        // running: its `session.finalized` goes out once `start()`
        // enables emission.
        if let ended = touched.ended {
            _pendingFinalized = Self.finalizedAttributes(ended.state, reason: ended.reason)
        }
        self.sessionManager = revivedManager
        self._deviceId = snapshot.deviceId
        self.identityProvider = identityProvider
        self.sidecar = sidecar
        stateLock.unlock()

        context.refreshDeviceIdentity(DeviceIdentitySnapshot(id: snapshot.deviceId))
        context.refreshUser(UserContextSnapshot(id: snapshot.userId))
        context.refreshSession(SessionContextSnapshot(session))

        writeSidecar()
        // After the identity write, so volatile writes never land in a
        // file that lacks this process's identity.
        riders.attach(sidecar: sidecar)
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
        setFlushTimerLocked(armed: _enabled)
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
        setFlushTimerLocked(armed: true)
        stateLock.unlock()

        // Rotate to a fresh session — `start()` is the lifecycle
        // boundary at which a new session id is born.
        let priorSessionId = context.currentSession().id
        let touched = sessionManager.touch()
        let session = touched.state
        stateLock.lock()
        var pendingFinalized = _pendingFinalized
        _pendingFinalized = nil
        if let ended = touched.ended {
            pendingFinalized = Self.finalizedAttributes(ended.state, reason: ended.reason)
        }
        if session.id != priorSessionId {
            _threadTimeNs = 0
        }
        stateLock.unlock()
        context.refreshSession(SessionContextSnapshot(session))
        writeSidecar()

        // A rotation pair carries `session.rotation` on both halves.
        var startedAttrs: [String: AttributeValue] = [:]
        if let pendingFinalized {
            recordEventInternal(name: "session.finalized", attributes: pendingFinalized)
            startedAttrs["session.rotation"] = pendingFinalized["session.rotation"]
        }
        // Emit `session.started`. This bypasses the sampler (forced
        // emit) so it always lands in the next batch.
        recordEvent(name: "session.started", attributes: startedAttrs)

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

    /// Flush and stop. Emits no `session.finalized`: that marks a
    /// session ending by rotation, never a flush (F29).
    public func stop() {
        flush(reason: .shutdown)
        setEnabled(false)
    }

    public func setEnabled(_ enabled: Bool) {
        stateLock.lock()
        _enabled = enabled
        setFlushTimerLocked(armed: enabled)
        stateLock.unlock()
    }

    public func recordEvent(name: String, attributes: [String: AttributeValue]) {
        let t0 = DispatchTime.now().uptimeNanoseconds
        defer { addThreadTime(since: t0) }
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

        // `session.finalized` and `app.crash` (native crash replay —
        // the process died) flush immediately. `app.error` and
        // `app.hang` are sampled and ride the normal flush (F29).
        if name == "session.finalized" || name == "app.crash" {
            flush(reason: .immediate)
        }
    }

    public func recordPerformance(name: String, attributes: [String: AttributeValue]) {
        let t0 = DispatchTime.now().uptimeNanoseconds
        defer { addThreadTime(since: t0) }
        guard Self.allowedMetricNames.contains(name) else {
            if debug {
                os_log("Recorder dropped unknown metric name %{public}@", log: log, type: .info, name)
            }
            return
        }
        bumpLastActiveAndEmitRotationIfNeeded()
        stateLock.lock()
        let currentSampler = self.sampler
        stateLock.unlock()
        guard currentSampler.shouldEmit(metricName: name) else { return }
        let now = clock.now
        // The headline scalar moves to the envelope `value`; the copy
        // leaves `attributes` (#146). `duration_ms` is the fallback.
        var attributes = attributes
        let value: Double?
        let headline = attributes.removeValue(forKey: "value")
        if case let .double(d) = headline {
            value = d
        } else if case let .int(i) = headline {
            value = Double(i)
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
        writeSidecar()
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

    /// Non-merging replace: drops `user.name` / `user.email` /
    /// `user.phone`, keeps the SDK-owned `user.id`.
    public func clearUser() {
        context.refreshUser(UserContextSnapshot(id: context.currentUser().id))
        writeSidecar()
    }

    /// Erasure hook: regenerates the persisted `device.id` and `user.id`
    /// and drops host identity. The session is not rotated.
    public func resetIdentity() {
        stateLock.lock(); let provider = identityProvider; stateLock.unlock()
        let deviceId = provider?.regenerateDeviceId() ?? DeviceIdentitySnapshot.newId(at: _clock.now)
        let userId = provider?.regenerateUserId() ?? UserContextSnapshot.newAnonymousId(at: _clock.now)
        stateLock.lock(); _deviceId = deviceId; stateLock.unlock()
        context.refreshDeviceIdentity(DeviceIdentitySnapshot(id: deviceId))
        context.refreshUser(UserContextSnapshot(id: userId))
        writeSidecar()
    }

    // MARK: Flush

    /// Build an envelope from the current buffer and hand it to the
    /// `TransportSink`. Driven by the `flushInterval` timer, batch
    /// size, immediate triggers and shutdown. Safe to call when the buffer
    /// is empty — short-circuits to a no-op.
    public func flush(reason: FlushReason) {
        stateLock.lock()
        let events = _buffer
        _buffer.removeAll(keepingCapacity: true)
        let location = _config?.location
        let currentTransport = transport
        let threadTimeMs = Int(_threadTimeNs / 1_000_000)
        stateLock.unlock()

        guard !events.isEmpty else { return }

        let envelope = payloadBuilder.build(
            events: events,
            context: context.snapshot(),
            location: location,
            flushTime: clock.now,
            sdkThreadTimeMs: threadTimeMs
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
        setEnabled(false)
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
            writeSidecar()
        }
    }

    // MARK: Internals

    /// Mirror identity to the crash sidecar. Called only from the
    /// identity-mutation sites: `installPersistedStores`, `start()`,
    /// `setUser`, `clearUser`, `resetIdentity`, idle rotation,
    /// `didAckBatch`.
    /// Snapshot and write under one lock so concurrent sites (ACK on
    /// the transport thread vs `setUser` on the caller) cannot land a
    /// stale snapshot last.
    private func writeSidecar() {
        stateLock.lock(); let sidecar = self.sidecar; stateLock.unlock()
        guard let sidecar else { return }
        sidecarLock.lock(); defer { sidecarLock.unlock() }
        sidecar.write(snapshot: context.snapshot())
    }

    /// (Re-)arm or cancel the `flushInterval` timer. Caller holds
    /// `stateLock`, so the timer state always matches `_enabled`. A
    /// tick on an empty buffer is a no-op flush.
    // ponytail: ticks while idle (one wakeup per flushInterval); arm on
    // first enqueue instead if the idle wakeups ever show up in energy logs.
    private func setFlushTimerLocked(armed: Bool) {
        flushTimer?.cancel()
        flushTimer = nil
        guard armed else { return }
        let interval = max(0.01, _config?.flushInterval ?? 5.0)
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.flush(reason: .timer) }
        timer.resume()
        flushTimer = timer
    }

    internal var _flushTimerArmedForTests: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return flushTimer != nil
    }

    private func addThreadTime(since t0: UInt64) {
        let elapsed = DispatchTime.now().uptimeNanoseconds &- t0
        stateLock.lock(); _threadTimeNs &+= elapsed; stateLock.unlock()
    }

    /// Update the session's `lastActiveAt` to "now" and, if the touch
    /// crossed the 30-min idle threshold or the 4 h cap, emit the
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

        let result = sessionManager.touch()
        guard result.rotated else { return }
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
        let reason = result.ended?.reason ?? "idle"
        if let ended = result.ended {
            recordEventInternal(name: "session.finalized", attributes: Self.finalizedAttributes(ended.state, reason: reason))
        }

        // Reset after `session.finalized` flushed, so the prior
        // session's last envelope carries its own total.
        stateLock.lock(); _threadTimeNs = 0; stateLock.unlock()
        context.refreshSession(newSnapshot)
        writeSidecar()

        recordEventInternal(name: "session.started", attributes: ["session.rotation": .string(reason)])
    }

    /// `session.finalized` for an ended session: its own identity
    /// (the context has moved on), `session.end_time` = its last
    /// activity, and why it ended (`idle` / `max_duration`).
    private static func finalizedAttributes(_ ended: SessionState, reason: String) -> [String: AttributeValue] {
        [
            "session.id": .string(ended.id),
            "session.start_time": .string(WireDateFormatter.string(from: ended.startTime)),
            "session.sequence": .int(ended.sequence),
            "session.end_time": .string(WireDateFormatter.string(from: ended.lastActiveAt)),
            "session.rotation": .string(reason)
        ]
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

    /// Single choke point for every emission. Never writes the sidecar
    /// (O1, #212) — identity changes only at the mutation sites that
    /// call `writeSidecar()`. Stamps the riders (F28) into the event's
    /// own attributes, so they carry enqueue-time values.
    private func enqueue(_ event: Event) {
        let event = stampRiders(event)
        stateLock.lock()
        // Consent guard: `disable()` silences every emitter at once.
        guard _enabled else { stateLock.unlock(); return }
        _buffer.append(event)
        let count = _buffer.count
        let cap = _config?.batchSize ?? 30
        stateLock.unlock()
        if count >= cap {
            flush(reason: .batchSize)
        }
    }

    private func stampRiders(_ event: Event) -> Event {
        switch event {
        case let .event(name, timestamp, attributes):
            // A native crash is replayed from the previous process; its
            // riders come from the sidecar, never from this launch.
            if name == "app.crash" { return event }
            return .event(name: name, timestamp: timestamp, attributes: riders.stamp(attributes))
        case let .metric(name, value, timestamp, attributes):
            return .metric(name: name, value: value, timestamp: timestamp, attributes: riders.stamp(attributes))
        }
    }
}
