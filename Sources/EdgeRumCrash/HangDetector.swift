// Sources/EdgeRumCrash/HangDetector.swift
//
// F15/T15.1 — main-thread hang detection. Two collaborating pieces:
//
//   1. A `CFRunLoopObserver` on the main runloop (`.commonModes`,
//      `.entry | .beforeWaiting | .afterWaiting | .exit`) bumps an
//      atomic heartbeat counter every time the main runloop turns.
//   2. A dedicated background `HangWatchdogThread` polls the counter
//      every `tickIntervalSeconds` (250 ms).
//
// F33 two-phase hang (W19): once the counter has not advanced for the
// configured `hangTimeout`, the watchdog captures the stack and
// persists a pending-hang record (`PendingHangFile`) — main is stuck,
// so the write costs the user nothing — and emits nothing. When the
// heartbeat resumes it records one `app.hang` with the real
// `hang.duration_ms` and deletes the record. If the process dies
// first, `replayPending(...)` re-emits the record at next launch with
// `hang.terminated = true` on the previous session's identity.
//
// Idempotent install (NSLock-protected `installed` flag mirrors
// `PLCrashIntegration` lines 38-72). `uninstall()` removes the
// observer and cancels the watchdog thread so a host that calls
// `EdgeRum.disable()` mid-run leaves no live timers behind.
//
// Threshold is clamped to a 2.0 s floor (PLAN-iOS.md §17 risk #5 —
// older iPhone 8 / SE 2 hardware can produce false positives at
// sub-2 s thresholds).
//
// The watchdog never blocks the main thread. The Mach-based stack
// capture (`MainThreadStackSnapshot.capture`) runs on the watchdog
// thread, suspends the main thread for a few microseconds while it
// walks the frame-pointer chain, then resumes. `Recorder.recordEvent`
// runs synchronously on the calling (watchdog) thread and only
// buffers (`app.hang` is sampled, no forced flush).
//
// Refs: PLAN-iOS.md §6.8, §F15/T15.1, §F15/T15.2;
//       docs/decisions.md ADR-011; CLAUDE.md "Touching crash code?"
//

import Foundation
import os.log
#if canImport(EdgeRumCore)
import EdgeRumCore
#endif

public enum HangDetector {

    // MARK: - Tunables

    /// Watchdog poll interval. 250 ms is a balance between detection
    /// responsiveness (we'll spot a 5 s hang within ~250 ms of the
    /// threshold) and watchdog overhead.
    internal static let tickIntervalSeconds: TimeInterval = 0.25

    /// Hard floor on the host-supplied `hangTimeout`. Below 2 s the
    /// false-positive rate on mid-tier hardware (iPhone 8 / SE 2) is
    /// unacceptable per PLAN-iOS.md §17 risk #5.
    internal static let minimumThresholdSeconds: TimeInterval = 2.0

    /// The threshold the watchdog actually runs at for a host-supplied
    /// `hangTimeout` — the `long_task` ceiling (F33 disjoint rungs).
    public static func effectiveThreshold(_ hangTimeout: TimeInterval) -> TimeInterval {
        max(minimumThresholdSeconds, hangTimeout)
    }

    // MARK: - State

    private static let installLock = NSLock()
    nonisolated(unsafe) private static var watchdog: HangWatchdog?
    nonisolated(unsafe) private static var observer: CFRunLoopObserver?
    nonisolated(unsafe) private static var watchdogThread: HangWatchdogThread?

    private static let heartbeatLock = NSLock()
    nonisolated(unsafe) private static var heartbeat: UInt64 = 0

    private static let log = OSLog(subsystem: "com.edge.rum", category: "edge.rum.hang")

    // MARK: - Public install

    /// Install the watchdog. Idempotent; second and subsequent calls
    /// are silent no-ops. Safe to call from any thread — the observer
    /// install hops to the main thread internally.
    ///
    /// - Parameters:
    ///   - threshold: host-supplied `hangTimeout`. Clamped to a 2 s
    ///     floor before use.
    ///   - debug: when `true`, logs a one-line summary on detection.
    public static func install(
        threshold: TimeInterval,
        debug: Bool
    ) {
        _install(
            threshold: threshold,
            debug: debug,
            recorder: Recorder.shared,
            clock: SystemClock(),
            stackProvider: nil,
            cpuProvider: nil,  // → whole-process `ProcessCPUReader`
            pending: PendingHangFile(url: PendingHangFile.defaultURL())
        )
    }

    /// Replay a pending-hang record left by a process that died
    /// mid-stall as one `app.hang` with `hang.terminated = true`,
    /// attributed to the previous session via the sidecar, then delete
    /// it. Call before this launch's watchdog can write a new record.
    public static func replayPending(
        recorder: Recording,
        sidecarContents: [String: AttributeValue]?
    ) {
        _replayPending(
            recorder: recorder,
            sidecarContents: sidecarContents,
            pending: PendingHangFile(url: PendingHangFile.defaultURL())
        )
    }

    internal static func _replayPending(
        recorder: Recording,
        sidecarContents: [String: AttributeValue]?,
        pending: PendingHangFile
    ) {
        guard var attrs = pending.read() else { return }
        pending.delete()
        attrs["hang.terminated"] = .bool(true)
        if let snapshot = sidecarContents.flatMap(CrashSidecarReader.parse) {
            attrs.merge(CrashSidecarReader.replayAttributes(snapshot)) { own, _ in own }
        }
        recorder.recordEvent(name: "app.hang", attributes: attrs)
    }

    /// Tear down the watchdog. Removes the runloop observer and
    /// cancels the watchdog thread. After this returns no further
    /// hang events will be recorded until `install(...)` is called
    /// again. Idempotent; uninstall when nothing is installed is a
    /// no-op.
    public static func uninstall() {
        installLock.lock()
        // A stall still open here never ends under our watch; its record
        // must not replay as `terminated`.
        watchdog?.discardPending()
        let removedObserver = observer
        let removedThread = watchdogThread
        watchdog = nil
        observer = nil
        watchdogThread = nil
        installLock.unlock()

        if let observer = removedObserver {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
        removedThread?.cancel()
    }

    // MARK: - Internal install (test-only knobs)

    /// Test entry point exposed so `HangDetectorDetectionTests` can
    /// inject a `Recording` probe + a deterministic `Clock` + an
    /// in-memory stack provider. The public `install(...)` uses the
    /// real `Recorder.shared`, `SystemClock`, and
    /// `MainThreadStackSnapshot.capture`.
    internal static func _install(
        threshold: TimeInterval,
        debug: Bool,
        recorder: Recording,
        clock: Clock,
        stackProvider: (() -> [StackFrame])?,
        cpuProvider: (() -> Double?)?,
        pending: PendingHangFile = PendingHangFile(url: nil)
    ) {
        installLock.lock()
        if watchdog != nil {
            installLock.unlock()
            return
        }
        let clamped = max(minimumThresholdSeconds, threshold)
        let stack = stackProvider ?? { MainThreadStackSnapshot.capture() }
        // Delta reader; the watchdog re-primes it at stall start.
        let cpu = cpuProvider ?? ProcessCPUReader().sample
        let newWatchdog = HangWatchdog(
            threshold: clamped,
            clock: clock,
            recorder: recorder,
            stackProvider: stack,
            cpuProvider: cpu,
            pending: pending,
            debug: debug,
            log: log
        )
        watchdog = newWatchdog
        installLock.unlock()

        // Observer + watchdog thread install on main. Use sync hop
        // when we're already on main to keep test setup synchronous.
        if Thread.isMainThread {
            installOnMain(debug: debug)
        } else {
            DispatchQueue.main.async {
                installOnMain(debug: debug)
            }
        }
    }

    /// Test hook — fully reset state between cases. Cancels the
    /// watchdog thread, removes the observer, clears the heartbeat
    /// counter, and resets `MainThreadStackSnapshot`'s cached port.
    internal static func _resetForTests() {
        uninstall()
        heartbeatLock.lock()
        heartbeat = 0
        heartbeatLock.unlock()
        MainThreadStackSnapshot._resetForTests()
    }

    /// Test hook — read the live heartbeat counter without taking
    /// the install lock.
    internal static func _currentHeartbeat() -> UInt64 {
        heartbeatLock.lock(); defer { heartbeatLock.unlock() }
        return heartbeat
    }

    /// Test hook — synthesize a runloop bump so detection tests can
    /// drive the watchdog without spinning up a real CFRunLoop.
    internal static func _bumpHeartbeatForTests() {
        bumpHeartbeat()
    }

    /// Test hook — peek at the active watchdog for direct `tick`
    /// invocation in unit tests.
    internal static func _activeWatchdog() -> HangWatchdog? {
        installLock.lock(); defer { installLock.unlock() }
        return watchdog
    }

    /// Test hook — surface whether an observer is currently
    /// attached. Used by install / uninstall tests to assert
    /// teardown actually removed the runloop observer.
    internal static func _hasObserver() -> Bool {
        installLock.lock(); defer { installLock.unlock() }
        return observer != nil
    }

    // MARK: - Observer + thread install (main only)

    private static func installOnMain(debug: Bool) {
        assert(Thread.isMainThread, "installOnMain must run on the main thread")

        // Capture the main thread Mach port for cross-thread stack
        // snapshots BEFORE the watchdog thread starts polling.
        MainThreadStackSnapshot.installFromMainThread()

        let activities = CFRunLoopActivity.entry.rawValue
            | CFRunLoopActivity.beforeWaiting.rawValue
            | CFRunLoopActivity.afterWaiting.rawValue
            | CFRunLoopActivity.exit.rawValue

        let createdObserver = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            activities,
            true,   // repeats
            0,      // order — first observer in the queue
            { _, _ in
                HangDetector.bumpHeartbeat()
            }
        )

        if let createdObserver {
            CFRunLoopAddObserver(CFRunLoopGetMain(), createdObserver, .commonModes)
        } else {
            SdkHealth.shared.fail(.hangObserver)
            if debug {
                os_log(
                    "HangDetector: CFRunLoopObserverCreateWithHandler returned nil — heartbeat disabled",
                    log: log,
                    type: .info
                )
            }
        }

        let thread = HangWatchdogThread(tickInterval: tickIntervalSeconds)
        thread.start()

        installLock.lock()
        observer = createdObserver
        watchdogThread = thread
        installLock.unlock()
    }

    // MARK: - Heartbeat

    fileprivate static func bumpHeartbeat() {
        heartbeatLock.lock()
        heartbeat &+= 1
        heartbeatLock.unlock()
    }
}

// MARK: - Watchdog state machine

/// Pure decision logic for the watchdog poll loop. Single-owner —
/// only the `HangWatchdogThread` calls `tick(...)` in production, and
/// only the unit test calls it from the test thread. The state is
/// therefore not lock-protected.
internal final class HangWatchdog {

    let threshold: TimeInterval
    private let clock: Clock
    private let recorder: Recording
    private let stackProvider: () -> [StackFrame]
    private let cpuProvider: () -> Double?
    private let pending: PendingHangFile
    private let debug: Bool
    private let log: OSLog

    private var lastSeenHeartbeat: UInt64 = 0
    private var hasObservedHeartbeat: Bool = false
    private var stalledStart: Date?
    /// Attributes captured at threshold crossing; non-nil while a hang
    /// is open (crossed, not yet ended).
    private var openHang: [String: AttributeValue]?
    private let pendingLock = NSLock()

    init(
        threshold: TimeInterval,
        clock: Clock,
        recorder: Recording,
        stackProvider: @escaping () -> [StackFrame],
        cpuProvider: @escaping () -> Double?,
        pending: PendingHangFile = PendingHangFile(url: nil),
        debug: Bool,
        log: OSLog
    ) {
        self.threshold = threshold
        self.clock = clock
        self.recorder = recorder
        self.stackProvider = stackProvider
        self.cpuProvider = cpuProvider
        self.pending = pending
        self.debug = debug
        self.log = log
    }

    /// Drop an open hang without emitting it (`uninstall`).
    func discardPending() {
        pendingLock.lock(); defer { pendingLock.unlock() }
        openHang = nil
        pending.delete()
    }

    /// Run one decision tick. Returns `true` iff an `app.hang` was
    /// recorded on this tick — at stall end, never at threshold. Tests
    /// call this directly with a synthetic `currentHeartbeat` value.
    @discardableResult
    func tick(currentHeartbeat: UInt64) -> Bool {
        let now = clock.now

        // Wait for the first observer firing before we start counting
        // stall ticks. Without this guard a freshly-installed watchdog
        // would interpret the (very brief) "no heartbeat yet" window
        // as a hang.
        if !hasObservedHeartbeat {
            if currentHeartbeat > 0 {
                hasObservedHeartbeat = true
                lastSeenHeartbeat = currentHeartbeat
            }
            return false
        }

        pendingLock.lock(); defer { pendingLock.unlock() }

        if currentHeartbeat != lastSeenHeartbeat {
            lastSeenHeartbeat = currentHeartbeat
            defer { stalledStart = nil; openHang = nil }
            guard var attrs = openHang, let start = stalledStart else { return false }
            // Stall over: one event with the real length (± one tick).
            let durationMs = now.timeIntervalSince(start) * 1000.0
            attrs["hang.duration_ms"] = .double(durationMs)
            pending.delete()
            recorder.recordEvent(name: "app.hang", attributes: attrs)
            if debug {
                os_log("edge-rum: hang ended — %.0f ms", log: log, type: .info, durationMs)
            }
            return true
        }

        // Heartbeat hasn't advanced since the previous tick. Begin
        // (or continue) the stall window.
        guard let start = stalledStart else {
            stalledStart = now
            // Re-prime the delta reader so the detection read covers
            // the stall window, not everything since the last hang.
            _ = cpuProvider()
            return false
        }
        let durationMs = now.timeIntervalSince(start) * 1000.0

        if var attrs = openHang {
            // ponytail: rewrites the record every tick (≤ 4/s, only while
            // main is stuck) so a replay's duration is time-to-death
            // ± 250 ms. Throttle if the write ever shows up.
            attrs["hang.duration_ms"] = .double(durationMs)
            openHang = attrs
            pending.write(attrs)
            return false
        }

        guard now.timeIntervalSince(start) >= threshold else { return false }

        let attrs = HangEventEncoder.encode(
            durationMs: durationMs,
            thresholdMs: threshold * 1000.0,
            cpuUsage: cpuProvider(),
            stackFrames: stackProvider(),
            timestamp: now
        )
        openHang = attrs
        pending.write(attrs)

        if debug {
            os_log(
                "edge-rum: hang detected — %.0f ms ≥ %.0f ms",
                log: log,
                type: .info,
                durationMs,
                threshold * 1000.0
            )
        }
        return false
    }
}

// MARK: - Pending-hang record

/// `Library/Caches/edge-rum/pending-hang.json` — the open hang's
/// attributes, so a stall the process dies in replays next launch.
/// A `nil` URL makes every operation a no-op (tests).
internal struct PendingHangFile {

    let url: URL?

    static func defaultURL() -> URL? {
        SessionSidecar.defaultBaseDirectoryURL()?
            .appendingPathComponent("pending-hang.json", isDirectory: false)
    }

    func write(_ attrs: [String: AttributeValue]) {
        guard let url, let data = try? JSONEncoder().encode(attrs) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    func read() -> [String: AttributeValue]? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([String: AttributeValue].self, from: data)
    }

    func delete() {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Watchdog thread

/// `Thread` subclass that polls the heartbeat counter on its own
/// scheduler. Marked `.userInitiated` per F15/T15.1 spec.
internal final class HangWatchdogThread: Thread {

    private let tickInterval: TimeInterval

    init(tickInterval: TimeInterval) {
        self.tickInterval = tickInterval
        super.init()
        name = "edge.rum.hang.watchdog"
        qualityOfService = .userInitiated
    }

    override func main() {
        while !isCancelled {
            Thread.sleep(forTimeInterval: tickInterval)
            if isCancelled { break }
            let beat = HangDetector._currentHeartbeat()
            _ = HangDetector._activeWatchdog()?.tick(currentHeartbeat: beat)
        }
    }
}
