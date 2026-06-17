// Sources/EdgeRum/EdgeRumConfig.swift
//
// Refs: PLAN-iOS.md §3.2, §F2/T2.2; CLAUDE.md
//       "Error handling conventions" (precondition on misuse so it
//       fails in release too).
//

import Foundation

/// Configuration supplied to `EdgeRum.start(_:)`.
///
/// Required: `apiKey` and `endpoint`. Every other field has a
/// documented default tuned for production use. Mutate any field on
/// the struct before passing it to `start(_:)`.
///
/// ```swift
/// var config = EdgeRumConfig(
///     apiKey: "edge_live_abc123",
///     endpoint: URL(string: "https://collect.example.com")!
/// )
/// config.appName = "Shop"
/// config.appVersion = "2.1.0"
/// config.environment = .production
/// EdgeRum.start(config)
/// ```
public struct EdgeRumConfig: Sendable {

    // MARK: Identity (required + app-level)

    /// API key issued by the EdgeRum collector backend.
    /// Must start with `"edge_"`. Sent as the `X-API-Key` header on
    /// every request.
    public var apiKey: String

    /// Base URL of the EdgeRum collector backend. The SDK appends
    /// the collector path automatically. Must be `https://` unless
    /// `debug == true`.
    public var endpoint: URL

    /// Host app display name. Sent as `app.name` on every event.
    public var appName: String?

    /// Host app version (SemVer). Sent as `app.version`.
    public var appVersion: String?

    /// Host app bundle identifier. Sent as `app.package_name`.
    public var appPackage: String?

    /// Host app build number. Sent as `app.build_number`. Omitted
    /// from the wire when `nil`.
    public var appBuild: String?

    /// Deployment environment. Sent as `app.environment`.
    public var environment: Environment?

    // MARK: Location

    /// Optional batch-level location string in `City/Country` form
    /// (e.g. `"Nairobi/Kenya"`). Set explicitly or let
    /// `resolveLocation = true` populate it once at startup from
    /// `locationProviderUrl`.
    public var location: String?

    /// If `true`, the SDK calls `locationProviderUrl` once on init,
    /// caches the resolved `"City/Country"` for 24 hours in
    /// `UserDefaults`. Off by default — opt in only.
    public var resolveLocation: Bool = false

    /// Provider used when `resolveLocation == true`. Defaults to
    /// ipapi.co; replace with your own service to avoid sending the
    /// device IP to a third party.
    public var locationProviderUrl: URL? = URL(string: "https://ipapi.co/json/")

    // MARK: Sampling + queuing

    /// Per-session sample rate in `0.0...1.0`. `1.0` records every
    /// session; `0.5` records half (decided once at session start).
    public var sampleRate: Double = 1.0

    /// URLs matching any of these regular expressions are excluded
    /// from HTTP capture. Useful for keeping your own analytics
    /// endpoints out of the data.
    public var ignoreUrls: [NSRegularExpression] = []

    /// Maximum number of events held in the offline queue before
    /// the oldest are dropped.
    public var maxQueueSize: Int = 200

    /// Soft flush interval in seconds. The actual flush fires on
    /// whichever happens first: this timer, `batchSize` reached, or
    /// an immediate-flush event (errors, `session.finalized`).
    public var flushInterval: TimeInterval = 5.0

    /// Maximum events per batch payload.
    public var batchSize: Int = 30

    /// Optional URL sanitiser applied before any URL is recorded.
    /// Use it to strip query parameters, redact path segments, etc.
    public var sanitizeUrl: (@Sendable (URL) -> URL)?

    // MARK: Capture toggles

    /// Capture native crashes (PLCrashReporter). Default `true`.
    public var captureNativeCrashes: Bool = true

    /// Capture main-thread hangs via a runloop watchdog. Default `true`.
    public var enableHangDetection: Bool = true

    /// Main-thread responsiveness threshold in seconds.
    /// A stall longer than this records as a hang.
    public var hangTimeout: TimeInterval = 5.0

    /// Capture UIKit/SwiftUI screen entries and dwell. Default `true`.
    public var captureScreens: Bool = true

    /// Capture HTTP requests via URLProtocol + delegate hooks.
    public var captureHTTP: Bool = true

    /// Capture top-level tap interactions. Default `true`.
    public var captureTaps: Bool = true

    /// Capture continuous performance signals: per-second frame render
    /// time (max / p95 / dropped count), 10-second memory usage polls
    /// plus memory-pressure transitions, and main-thread long-task
    /// detection (≥50 ms). Default `true`.
    public var captureRenderingPerformance: Bool = true

    /// Capture app lifecycle transitions (`foregrounded` / `active` /
    /// `inactive` / `backgrounded` / `will_terminate`) and emit a
    /// session-finalize event on backgrounding so the in-memory buffer
    /// is flushed before the OS suspends or kills the process.
    /// Default `true`.
    public var captureLifecycle: Bool = true

    /// Capture network connectivity changes — emits one event per
    /// transition carrying `network.type`, `network.effectiveType`,
    /// `network.is_expensive`, `network.is_constrained`, and (iOS 14.2+)
    /// `network.unsatisfied_reason`. Default `true`.
    public var captureNetworkChanges: Bool = true

    // MARK: Diagnostics

    /// When `true`, the SDK logs verbose diagnostics via `os_log` and
    /// relaxes URL validation to accept `http://` endpoints. Disable
    /// for production builds.
    public var debug: Bool = false

    // MARK: Designated init

    /// Build a configuration with the two required fields. All other
    /// fields take their documented defaults; mutate the resulting
    /// struct before passing it to `EdgeRum.start(_:)`.
    public init(apiKey: String, endpoint: URL) {
        self.apiKey = apiKey
        self.endpoint = endpoint
    }

    // MARK: Validation (testable in isolation)

    internal enum ValidationResult: Equatable {
        case ok
        case invalidApiKey
        case invalidEndpoint
    }

    /// Pure validation — no side effects, safe to call from tests.
    /// The public `EdgeRum.start(_:)` calls this and wraps the result
    /// in a `precondition` so misuse fails in release builds too.
    internal static func validate(_ config: EdgeRumConfig) -> ValidationResult {
        guard !config.apiKey.isEmpty, config.apiKey.hasPrefix("edge_") else {
            return .invalidApiKey
        }
        if config.debug == false, config.endpoint.scheme?.lowercased() != "https" {
            return .invalidEndpoint
        }
        return .ok
    }
}
