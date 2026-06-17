// Sources/EdgeRumCrash/HangDetector.swift
//
// F15/T15.1 — main-thread hang detection. Two collaborating pieces:
//
//   1. A `CFRunLoopObserver` on the main runloop (`.commonModes`,
//      `.entry | .beforeWaiting | .afterWaiting | .exit`) bumps an
//      atomic heartbeat counter every time the main runloop turns.
//   2. A dedicated background `HangWatchdogThread` polls the counter
//      every `tickIntervalSeconds` (250 ms). If the counter has not
//      advanced for longer than the configured `hangTimeout`, the
//      watchdog records one `app.crash` event with `cause = "Hang"`,
//      `crash.thread.main_stack`, `hang.duration_ms`, and
//      `hang.threshold_ms` (see `HangEventEncoder`).
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
// hops to its own utility queue so the hang event flushes
// asynchronously and doesn't extend the stall.
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
            cpuProvider: nil
        )
    }

    /// Tear down the watchdog. Removes the runloop observer and
    /// cancels the watchdog thread. After this returns no further
    /// hang events will be recorded until `install(...)` is called
    /// again. Idempotent; uninstall when nothing is installed is a
    /// no-op.
    public static func uninstall() {
        installLock.lock()
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
        stackProvider: (() -> [String])?,
        cpuProvider: (() -> Double?)?
    ) {
        installLock.lock()
        if watchdog != nil {
            installLock.unlock()
            return
        }
        let clamped = max(minimumThresholdSeconds, threshold)
        let stack = stackProvider ?? { MainThreadStackSnapshot.capture() }
        let cpu = cpuProvider ?? { nil }
        let newWatchdog = HangWatchdog(
            threshold: clamped,
            clock: clock,
            recorder: recorder,
            stackProvider: stack,
            cpuProvider: cpu,
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
        } else if debug {
            os_log(
                "HangDetector: CFRunLoopObserverCreateWithHandler returned nil — heartbeat disabled",
                log: log,
                type: .info
            )
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
    private let stackProvider: () -> [String]
    private let cpuProvider: () -> Double?
    private let debug: Bool
    private let log: OSLog

    private var lastSeenHeartbeat: UInt64 = 0
    private var hasObservedHeartbeat: Bool = false
    private var stalledStart: Date?
    private var firedForCurrentStall: Bool = false

    init(
        threshold: TimeInterval,
        clock: Clock,
        recorder: Recording,
        stackProvider: @escaping () -> [String],
        cpuProvider: @escaping () -> Double?,
        debug: Bool,
        log: OSLog
    ) {
        self.threshold = threshold
        self.clock = clock
        self.recorder = recorder
        self.stackProvider = stackProvider
        self.cpuProvider = cpuProvider
        self.debug = debug
        self.log = log
    }

    /// Run one decision tick. Returns `true` iff a hang event was
    /// recorded on this tick. Tests call this directly with a
    /// synthetic `currentHeartbeat` value.
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

        if currentHeartbeat != lastSeenHeartbeat {
            lastSeenHeartbeat = currentHeartbeat
            stalledStart = nil
            firedForCurrentStall = false
            return false
        }

        // Heartbeat hasn't advanced since the previous tick. Begin
        // (or continue) the stall window.
        if stalledStart == nil {
            stalledStart = now
            return false
        }

        guard !firedForCurrentStall,
              let start = stalledStart,
              now.timeIntervalSince(start) >= threshold else {
            return false
        }

        let durationMs = now.timeIntervalSince(start) * 1000.0
        let attrs = HangEventEncoder.encode(
            durationMs: durationMs,
            thresholdMs: threshold * 1000.0,
            cpuUsage: cpuProvider(),
            stackFrames: stackProvider(),
            timestamp: now
        )
        recorder.recordEvent(name: "app.crash", attributes: attrs)
        firedForCurrentStall = true

        if debug {
            os_log(
                "edge-rum: hang detected — %.0f ms ≥ %.0f ms",
                log: log,
                type: .info,
                durationMs,
                threshold * 1000.0
            )
        }
        return true
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
