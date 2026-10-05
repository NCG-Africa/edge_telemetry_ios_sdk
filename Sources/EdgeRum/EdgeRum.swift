// Sources/EdgeRum/EdgeRum.swift
//
// Public umbrella namespace. The entire consumer-facing surface of
// the SDK is exposed through static methods on this caseless enum so
// it cannot be instantiated.
//
// Every method routes to the internal `Recorder` shared instance in
// `EdgeRumCore`. F2 ships a no-op Recorder; F3 swaps the real one
// behind the same protocol.
//
// Refs: PLAN-iOS.md §3.2, §F2/T2.1; CLAUDE.md
//       "Public API surface" and "Error handling conventions".
//

import Foundation
import os.log
#if canImport(EdgeRumCore)
// SwiftPM: `EdgeRumCore` is a separate internal target. CocoaPods
// rolls every subspec into one `EdgeRum` module — the same types
// are already visible without an import.
import EdgeRumCore
#endif
#if canImport(EdgeRumCapture)
import EdgeRumCapture
#endif
#if canImport(EdgeRumCrash)
import EdgeRumCrash
#endif

/// Top-level entry point for the EdgeRum SDK.
///
/// The namespace is a caseless `enum` so it cannot be instantiated.
/// Call `start(_:)` once at app launch with an `EdgeRumConfig`, then
/// use `track`, `identify`, `time`, `captureError` and the SwiftUI
/// view modifiers from anywhere in the host app.
///
/// ```swift
/// EdgeRum.start(EdgeRumConfig(
///     apiKey: "edge_live_abc123",
///     endpoint: URL(string: "https://collect.example.com")!
/// ))
/// EdgeRum.track("checkout_started")
/// ```
public enum EdgeRum {

    // MARK: SemVer string

    /// SemVer string for this build of the SDK, sent as the
    /// `sdk.version` attribute on every event.
    ///
    /// Sourced at build time from the repo-root `VERSION` file via
    /// `EdgeRumVersionPlugin` — see PLAN-iOS.md §2.6.
    public static let sdkVersion: String = EdgeRumGeneratedVersion.string

    // MARK: Idempotency state

    /// Minimal `(apiKey, endpoint)` snapshot used to decide whether a
    /// repeat `start(_:)` is the same identity. We deliberately do
    /// NOT retain the full `EdgeRumConfig` here because it carries a
    /// consumer-supplied `sanitizeUrl` closure whose lifetime should
    /// not be extended to "process lifetime".
    private struct StartedIdentity: Equatable {
        let apiKey: String
        let endpoint: URL
    }

    private static let stateLock = NSLock()
    nonisolated(unsafe) private static var startedIdentity: StartedIdentity?

    /// The shared background uploader, instantiated at `start()` time
    /// so `handleBackgroundEvents(identifier:completion:)` can attach
    /// the system-supplied completion to the live `URLSession`. Lives
    /// behind the same `stateLock` as `startedIdentity` because it is
    /// set and read across the public API boundary.
    nonisolated(unsafe) private static var sharedBackgroundUploader: BackgroundUploader?

    private static let log = OSLog(subsystem: "com.edge.rum", category: "EdgeRum")

    // MARK: Lifecycle

    /// Start the SDK. Idempotent: a second call with the same
    /// `apiKey` + `endpoint` is a no-op; a second call with a
    /// different `apiKey` or `endpoint` logs a warning and is
    /// ignored.
    ///
    /// Validates `config.apiKey` (must start with `"edge_"`) and
    /// `config.endpoint.scheme` (must be `https` unless
    /// `config.debug == true`). Misuse fails fast via `precondition`
    /// so the same crash surfaces in debug and release builds.
    public static func start(_ config: EdgeRumConfig) {
        switch EdgeRumConfig.validate(config) {
        case .ok:
            break
        case .invalidApiKey:
            preconditionFailure(
                "EdgeRum.start: invalid apiKey. Expected non-empty value with the \"edge_\" prefix."
            )
        case .invalidEndpoint:
            preconditionFailure(
                "EdgeRum.start: endpoint must use https://. Set config.debug = true to allow http://."
            )
        }

        let identity = StartedIdentity(apiKey: config.apiKey, endpoint: config.endpoint)

        stateLock.lock()
        if let existing = startedIdentity {
            stateLock.unlock()
            if existing == identity {
                // Same identity — silent no-op. Repeat `start()` calls
                // happen on hot-reload and in some unit-test harnesses.
                return
            }
            os_log(
                "EdgeRum.start called twice with a different apiKey or endpoint — second call ignored.",
                log: log,
                type: .info
            )
            return
        }
        startedIdentity = identity
        stateLock.unlock()

        // If the shared Recorder is the real concrete type (i.e. the
        // host hasn't swapped in a test probe), upgrade its in-memory
        // identity stores to the persisted Keychain + UserDefaults
        // pair so `device.id` and `session.id` survive across launches.
        // Read the crashed launch's sidecar before this launch rewrites
        // it — the volatile zone (screen, orientation, app state) only
        // lives in the old file.
        let priorSidecar = SessionSidecar().read()
        // F31 — likewise the prior launch's breadcrumb ring; read and
        // deleted before this launch records its first crumb.
        let priorBreadcrumbs = Breadcrumbs.takePrior()
        Breadcrumbs.shared.configure(
            capturing: config.captureBreadcrumbs,
            url: config.captureBreadcrumbs ? Breadcrumbs.defaultURL() : nil
        )

        if let realRecorder = Recorder.shared as? Recorder {
            realRecorder.installPersistedStores(
                identityProvider: IdentityProvider(),
                sessionStore: UserDefaultsSessionStore(),
                sidecar: SessionSidecar(),
                debug: config.debug
            )

            // F5 — replace the F3 NoopTransportSink with the real
            // HTTP-backed sink. The sink takes a weak reference back to
            // the Recorder so it can call `didAckBatch()` on 2xx
            // (F4 carry-over hook, issue #43).
            let transport = BatchTransport(
                endpoint: config.endpoint,
                apiKey: config.apiKey,
                sdkVersion: EdgeRum.sdkVersion,
                deviceModel: TransportEnvironment.deviceModel(),
                osVersion: TransportEnvironment.osVersion(),
                debug: config.debug
            )
            sharedBackgroundUploader = BackgroundUploader(debug: config.debug)
            let offlineQueue = OfflineQueue(maxQueueSize: config.maxQueueSize, debug: config.debug)
            if offlineQueue == nil { SdkHealth.shared.fail(.offlineQueue) }
            let sink = HTTPTransportSink(
                transport: transport,
                offlineQueue: offlineQueue,
                backgroundUploader: sharedBackgroundUploader,
                apiKey: config.apiKey,
                userAgent: BatchTransport.makeUserAgent(
                    sdkVersion: EdgeRum.sdkVersion,
                    deviceModel: TransportEnvironment.deviceModel(),
                    osVersion: TransportEnvironment.osVersion()
                ),
                debug: config.debug
            )
            realRecorder.installTransport(sink)
        }

        // Hand the full settings to the internal Recorder before
        // it starts so context snapshots, sample rate, batch size,
        // and location are all in place when the first event lands.
        Recorder.shared.configure(RecorderConfig(
            apiKey: config.apiKey,
            endpoint: config.endpoint,
            debug: config.debug,
            sampleRate: config.sampleRate,
            batchSize: config.batchSize,
            flushInterval: config.flushInterval,
            location: config.location,
            appName: config.appName,
            appVersion: config.appVersion,
            appPackage: config.appPackage,
            appBuild: config.appBuild,
            environmentName: config.environment?.rawValue
        ))
        // F12 — anchor the launch-start instant as early as possible.
        // The static let backing `launchStart` is lazily initialized
        // on first reference; this call forces that initialization
        // before anything else `EdgeRum.start(...)` does so the
        // measured page-load duration starts as close to host-app
        // launch as the SDK can observe.
        PageLoadCapture.touchLaunchStart()

        // F14 — replay BEFORE rotating to a new session. If the prior
        // launch crashed, PLCrashIntegration reads the pending PLCR
        // report, folds in the *crashed* session's identity from the
        // sidecar, and pushes one `app.crash` event through the
        // recorder (which immediately flushes). Skipped here for any
        // host swap-in test probe — replay only makes sense against
        // the real Recorder pipeline.
        if let realRecorder = Recorder.shared as? Recorder {
            // The Recorder drops events while disabled, and replay runs
            // before `start()` enables it — open the gate first.
            realRecorder.setEnabled(true)
            let crashed = config.captureNativeCrashes && PLCrashIntegration.replayIfNeeded(
                recorder: realRecorder,
                sidecarContents: priorSidecar,
                priorBreadcrumbs: config.captureBreadcrumbs ? priorBreadcrumbs : nil,
                config: PLCrashIntegrationConfig(),
                debug: config.debug
            )
            // F33 — a stall the previous process died in, as
            // `app.hang` + `hang.terminated`. Before this launch's
            // watchdog can write a new record.
            HangDetector.replayPending(recorder: realRecorder, sidecarContents: priorSidecar)
            // F33 — how the previous process ended, on `session.started`.
            realRecorder.setLaunchEvidence(
                PreviousSession.attributes(prior: priorSidecar, crashed: crashed)
            )
        }

        Recorder.shared.start(
            apiKey: config.apiKey,
            endpoint: config.endpoint,
            debug: config.debug
        )

        // F16 — install the context-enrichment observers (thermal,
        // accessibility, NWPath extras, storage, locale) so the
        // ContextProvider stays current without the Recorder having to
        // re-snapshot on every event. Idempotent.
        if let realRecorder = Recorder.shared as? Recorder {
            ContextObservers.install(
                provider: realRecorder.currentContextProvider,
                debug: config.debug
            )
        }

        // F6 — install UIKit screen capture once. Idempotent and
        // main-thread-safe; on non-UIKit hosts (the macOS unit-test
        // runner) `install(...)` is a no-op so this call site stays
        // unconditional.
        if config.captureScreens {
            UIViewControllerCapture.install(debug: config.debug)
        }

        // F8 — install HTTP request capture. The config carries the
        // host's `ignoreUrls` regex set, `sanitizeUrl` callback, and
        // the collector's own host so the capture layer can filter the
        // SDK's own POSTs as a third defense layer (in addition to the
        // `X-Edge-Rum-Internal` header and `edge-rum-internal` task
        // description that `BatchTransport` sets on every internal
        // request).
        if config.captureHTTP {
            HTTPCapture.configure(HTTPCaptureConfig(
                ignoreUrls: config.ignoreUrls,
                sanitizeUrl: config.sanitizeUrl,
                endpointHost: config.endpoint.host
            ))
            HTTPCapture.install(debug: config.debug)
        }

        // F9 — install UIKit tap capture once. Idempotent and
        // main-thread-safe; on non-UIKit hosts (the macOS unit-test
        // runner) `install(...)` is a no-op so this call site stays
        // unconditional.
        // F30 — the same swizzle arms frame motion windows, so it also
        // installs (tap emission off) when only frame capture is on.
        if config.captureTaps || config.captureRenderingPerformance {
            InteractionCapture.install(
                debug: config.debug,
                captureButtonTitles: config.captureButtonTitles,
                emitTaps: config.captureTaps
            )
        }

        // F10 — install the performance samplers (frame, memory,
        // long-task) once. Each `install(...)` is idempotent and
        // main-thread-safe; on non-UIKit hosts the CADisplayLink path
        // short-circuits, but the memory + run-loop samplers still
        // arm so the test target exercises them.
        if config.captureRenderingPerformance {
            FrameSampler.install(debug: config.debug)
            MemorySampler.install(debug: config.debug)
            // F33 disjoint rungs: a stall at or past the hang threshold
            // is an `app.hang`, not a `long_task`.
            RunLoopObserverCapture.install(
                debug: config.debug,
                ceilingMs: config.enableHangDetection
                    ? HangDetector.effectiveThreshold(config.hangTimeout) * 1000 : nil
            )
        }

        // F11 — install lifecycle + connectivity capture. Idempotent;
        // each `install(...)` is a no-op on subsequent calls and on
        // non-UIKit / non-Network hosts.
        if config.captureLifecycle {
            LifecycleCapture.install(debug: config.debug)
        }
        if config.captureNetworkChanges {
            NetworkPathCapture.install(debug: config.debug)
        }

        // F12 — install the single-shot page-load capture. Idempotent;
        // arms a CADisplayLink that fires once the app is `.active`
        // and emits one `page_load` event per process.
        if config.capturePageLoad {
            PageLoadCapture.install(debug: config.debug)
        }

        // F14 — install PLCrashReporter LAST so its Mach exception
        // server registers after every other capture is wired. Inside
        // `install(...)` a single-shot guard makes repeat `start()`
        // calls a no-op.
        if config.captureNativeCrashes {
            PLCrashIntegration.install(
                config: PLCrashIntegrationConfig(),
                debug: config.debug
            )
        }

        // F15 — install the main-thread hang watchdog. Idempotent;
        // the install hops to the main thread internally to attach
        // the `CFRunLoopObserver`, and the watchdog `Thread` is the
        // one we cancel from `disable()` so a paused SDK leaves no
        // live timers behind.
        if config.enableHangDetection, Recorder.shared is Recorder {
            HangDetector.install(
                threshold: config.hangTimeout,
                debug: config.debug
            )
        }
    }

    /// Attach a host-app user profile to subsequent events. Calling
    /// `identify` before `start(_:)` is a no-op with a warning.
    public static func identify(_ user: UserContext) {
        guard requireStarted("identify") else { return }
        Recorder.shared.setUser(RecorderUser(
            id: user.id,
            name: user.name,
            email: user.email,
            phone: user.phone
        ))
    }

    /// Detach the host-app user profile set by `identify(_:)` — call on
    /// logout. Later events carry no `user.name`, `user.email` or
    /// `user.phone`; the SDK's anonymous `user.id` is kept. Calling
    /// before `start(_:)` is a no-op with a warning.
    public static func clearUser() {
        guard requireStarted("clearUser") else { return }
        Recorder.shared.clearUser()
    }

    /// Erase the link between this install and past data — for a user's
    /// data-deletion request. Generates a new ``deviceId`` and anonymous
    /// user id, and detaches any `identify(_:)` profile. Calling before
    /// `start(_:)` is a no-op with a warning.
    public static func resetIdentity() {
        guard requireStarted("resetIdentity") else { return }
        Recorder.shared.resetIdentity()
    }

    // MARK: Recording

    /// Record a custom event. The user-supplied `name` travels on the
    /// wire as the `event.name` attribute under the wire-required
    /// `custom_event` event name — the backend dispatcher routes
    /// custom events through that single channel. Attribute keys under
    /// a reserved SDK prefix (such as `device.` or `user.`) are dropped.
    public static func track(_ name: String, attributes: [String: AttributeValue]? = nil) {
        guard requireStarted("track") else { return }
        var merged = HostAttributes.sanitize(attributes, debug: Recorder.shared.debug)
        merged["event.name"] = .string(name)
        Recorder.shared.recordEvent(name: "custom_event", attributes: merged)
    }

    /// Record a screen entry. Equivalent to the SwiftUI
    /// `.edgeRumScreen(_:)` modifier — provided for UIKit screens
    /// that don't go through the auto-capture swizzle. Attribute keys
    /// under a reserved SDK prefix are dropped.
    public static func trackScreen(_ name: String, attributes: [String: AttributeValue]? = nil) {
        guard requireStarted("trackScreen") else { return }
        var merged = HostAttributes.sanitize(attributes, debug: Recorder.shared.debug)
        merged["navigation.screen"] = .string(name)
        merged["navigation.kind"] = .string("manual")
        Riders.shared.enterScreen(name)
        FrameSampler.noteMotion()  // F30: screen transition
        Recorder.shared.recordEvent(name: "navigation", attributes: merged)
    }

    /// Start measuring an interval of code. Call `end()` on the
    /// returned `RumTimer` to record a performance data point with
    /// the elapsed duration.
    ///
    /// If called before `start(_:)`, a pre-cancelled timer is
    /// returned so subsequent `end()` calls are no-ops. A warning is
    /// logged once per call.
    public static func time(_ name: String) -> RumTimer {
        let timer = RumTimer(name: name, recorder: Recorder.shared, clock: Recorder.shared.clock)
        if !requireStarted("time") {
            timer.cancel()
        }
        return timer
    }

    /// Report a thrown `Error` as an `app.error` event. It follows
    /// `sampleRate` and the normal flush cadence — it never forces an
    /// upload. The error's type, domain, code,
    /// `localizedDescription`, and (for `NSError`) the primitive
    /// entries of `userInfo` are flattened into wire attributes
    /// automatically. A snapshot of the call-site stack — captured
    /// here, synchronously, before any queue handoff — is attached
    /// as `error.stack`. Say what kind of failure this was with
    /// `type:` — a free string of your choosing (for example
    /// `"decoding_error"`), sent as `error_type` and capped at 128
    /// UTF-8 bytes; the SDK never classifies errors itself. Supply
    /// additional caller context with `context:`; those keys are
    /// prefixed `crash.context.` on the wire so they never collide
    /// with the standard `error.*` payload.
    public static func captureError(
        _ error: Error,
        type: String? = nil,
        context: [String: AttributeValue]? = nil
    ) {
        guard requireStarted("captureError") else { return }
        // Call-site stack capture — taken here, before the Recorder
        // call, so SDK frames stay out of the captured stack.
        let stack = StackFrames.symbolicate(Thread.callStackReturnAddresses.map(\.uintValue))
        let recorder = Recorder.shared
        let attrs = AppErrorBuilder.build(
            error: error,
            type: type,
            context: context ?? [:],
            stack: stack,
            debug: recorder.debug
        )
        recorder.recordEvent(name: "app.error", attributes: attrs)
    }

    // MARK: Enable / disable

    /// Halt all capture and emission. The offline queue is preserved.
    /// Use `enable()` to resume.
    public static func disable() {
        Recorder.shared.setEnabled(false)
        // F15 — tear down the watchdog so a paused SDK has no live
        // timers. `enable()` does NOT re-arm by design; `start(_:)`
        // is the install boundary, mirroring the swizzle-installer
        // rule (we cannot safely un-swizzle, so we cannot safely
        // re-swizzle either).
        HangDetector.uninstall()
    }

    /// Resume capture and emission after a `disable()` call. Also
    /// asks the transport layer to drain any envelopes that landed in
    /// the offline queue while the SDK was paused (CLAUDE.md
    /// "Offline queue rules" — `enable()` is one of the three drain
    /// triggers).
    public static func enable() {
        Recorder.shared.setEnabled(true)
        if let realRecorder = Recorder.shared as? Recorder {
            realRecorder.drainOfflineQueue()
        }
    }

    // MARK: Read-only state

    /// The current session id, in the documented format prefix shape
    /// (`session_<epochMs>_<16 hex>_ios`).
    public static var sessionId: String {
        Recorder.shared.currentSessionId
    }

    /// The SDK-owned anonymous device id, in the documented format
    /// prefix shape (`device_<epochMs>_<16 hex>_ios`).
    public static var deviceId: String {
        Recorder.shared.currentDeviceId
    }

    /// `true` if the SDK is currently capturing and emitting events.
    public static var isEnabled: Bool {
        Recorder.shared.isEnabled
    }

    // MARK: Background uploader hook

    /// Forward `application(_:handleEventsForBackgroundURLSession:
    /// completionHandler:)` to the SDK so any pending background
    /// uploads can finish after process death. Wire from
    /// `AppDelegate` or `SceneDelegate`.
    ///
    /// `completion` is `@Sendable` so it can be hopped onto the main
    /// queue under Swift 6 strict-concurrency. The system-supplied
    /// completion handler from
    /// `application(_:handleEventsForBackgroundURLSession:
    /// completionHandler:)` is sendable in practice.
    public static func handleBackgroundEvents(
        identifier: String,
        completion: @Sendable @escaping () -> Void
    ) {
        // F5 — forward into the live `BackgroundUploader` so the
        // system-supplied completion fires once the background
        // URLSession finishes its pending tasks. When the host calls
        // this before `start(_:)` we don't have an uploader yet — hop
        // straight to main and complete so the system gets its ack.
        stateLock.lock()
        let uploader = sharedBackgroundUploader
        stateLock.unlock()
        if let uploader {
            uploader.attachCompletion(completion, for: identifier)
        } else {
            DispatchQueue.main.async { completion() }
        }
    }

    // MARK: Internal helpers

    private static func requireStarted(_ method: String) -> Bool {
        stateLock.lock()
        let started = startedIdentity != nil
        stateLock.unlock()
        if !started {
            os_log(
                "EdgeRum.%{public}@ called before EdgeRum.start(_:) — ignored.",
                log: log,
                type: .info,
                method
            )
        }
        return started
    }

    // MARK: Test support

    /// Test-only — clears the started state so successive tests can
    /// drive `start()` again. Not exposed in release builds.
    internal static func _resetStartedConfigForTesting() {
        stateLock.lock()
        startedIdentity = nil
        stateLock.unlock()
    }
}
