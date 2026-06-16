# PLAN-iOS.md — `edge-rum-ios`

Native iOS Real User Monitoring SDK. Ships the exact wire format already
served by `edge-rum` (Ionic/Angular/Capacitor) and the native Android SDK
so the EdgeTelemetryProcessor backend needs no breaking changes.

This document is a build plan, not code. It is binding on the public API
shape, wire contract, supported-iOS commitment, and module boundaries;
the "Backend asks" and "Risks and open questions" sections collect every
place where the iOS-native context demands either a backend concession
or a deliberate deviation from the other platforms.

---

## 1. Goals and non-goals

### 1.1 Goals

- Ship a single Swift package, `EdgeRum`, that drops into any iOS 14+
  app and produces batches byte-for-byte compatible with what the
  EdgeTelemetryProcessor already receives from web and Android.
- **Pragmatic device coverage.** Support iOS 14.0 as the minimum.
  Covers ~98% of currently active iOS devices in 2026; drops A7/A8/A9
  devices (iPhone 5s through iPhone 6s era). The floor matches the
  oldest iOS where `MetricKit`, the `PrivacyInfo.xcprivacy` manifest,
  and `URLSessionConfiguration.background` upload identifiers all
  behave consistently, so we avoid `@available` fallbacks for our
  load-bearing captures.
- Provide a public API surface that reads like a product RUM SDK
  (`EdgeRum.track`, `EdgeRum.captureError`, `RumTimer`) and contains
  zero OpenTelemetry vocabulary.
- Capture, automatically: screen entries (UIKit + SwiftUI), HTTP
  requests, taps, app lifecycle, connectivity changes, native crashes,
  Objective-C exceptions, Mach signals, main-thread hangs, frame render
  time, memory pressure, long tasks, and resource timing.
- Survive offline: queue batches to disk, retry with backoff, drain on
  reconnect, and flush on background using `URLSessionConfiguration.background`.
- Stay under a defined performance budget (§11) tiered by device class
  so the iPhone SE 2 floor is realistic and the iPhone 15 Pro target
  is ambitious.
- Be App Store reviewable on first submit: no private APIs, no IDFA,
  declared reasons for every restricted API, ATT-neutral identifier.
- **Developer-friendly documentation as a first-class deliverable.**
  Ship a README that gets a new developer from zero to first event in
  under 10 minutes, a DocC catalog that is the canonical API reference,
  three runnable sample apps, and a CI gate on documentation quality
  (link check, code-block compile check, supported-iOS claim audit).
  See §12.

### 1.2 Non-goals

- No replay (session replay video / DOM mirror). Out of scope for v1.
- No source-map / dSYM upload tooling in v1 — symbolication happens
  server-side from dSYMs uploaded by the host app's CI; see §14.
- No OTLP, protobuf, or gRPC. JSON over HTTP only (RULE 2).
- No iOS 13 support. Going below iOS 14 would force `@available`
  fallbacks for `MetricKit`'s richer diagnostic payloads and for the
  `PrivacyInfo.xcprivacy` manifest behaviour, with negligible
  install-base gain over the iOS 14 floor. The upstream
  `opentelemetry-swift` umbrella also requires iOS 13, which we
  deliberately do not adopt (§5.4) — but the floor is set by our own
  capture surfaces, not by any upstream dependency.
- No public OpenTelemetry surface — the firewall (RULE 1) is absolute.
- No Web Vitals (LCP/FCP/CLS/INP/TTFB). Flagged in §14.
- No third-party analytics SDK shimming (Firebase, Amplitude, etc.).
- No Combine-only or async-only public API; both styles must work over
  the same synchronous facade.
- No tvOS / watchOS / visionOS in v1. iPadOS comes free with iOS;
  Mac Catalyst is a slice in the XCFramework but not promised.

---

## 2. Package and distribution

### 2.1 Channels (in priority order)

| Channel        | Status | Notes                                                                       |
|----------------|--------|-----------------------------------------------------------------------------|
| Swift Package  | P0     | Primary channel. `Package.swift` lives at repo root.                         |
| CocoaPods      | P1     | Single podspec `EdgeRum.podspec` mirrors the SwiftPM targets.                |
| XCFramework    | P1     | Pre-built binary for closed-source consumers; published to GitHub Releases. |
| Carthage       | —      | Not supported in v1; XCFramework covers the same use case.                  |

### 2.2 Platform floors and supported devices

**Minimum**: **iOS 14.0** (released Sep 2020).
**Tooling**: Swift 6.0+, Xcode 16+ to *build* the package
(`swift-tools-version: 6.0`). Consumer apps build with Xcode 15+ and
target iOS 14+. The Swift-6 toolchain is mandatory because our pinned
upstream dependency, `opentelemetry-swift-core` 2.x, declares
`swift-tools-version: 6.0`; the consumer-visible public surface
remains Swift-5-compatible so host apps need not adopt Swift 6 strict
concurrency.

#### Device support matrix

iOS 14.0 covers every iPhone 6s and newer (A9+ silicon). The plan
tests on the oldest- and newest-supported device in each row.

| Device class                | Oldest model on iOS 14 | Newest model (2026)   | Notes                                  |
|-----------------------------|------------------------|-----------------------|----------------------------------------|
| iPhone (mid, A9-A12)        | iPhone 6s              | iPhone XS Max         | Common enterprise floor                |
| iPhone (modern, A13+)       | iPhone 11              | iPhone 15 Pro Max     | ProMotion 120 Hz from iPhone 13 Pro    |
| iPad (modern)               | iPad (5th gen)         | iPad Pro M4           |                                         |
| iPod touch                  | —                      | —                     | iPod touch 7 capped at iOS 15; not a v1 target |

#### Architecture matrix

| Slice                       | Included | Notes                                          |
|-----------------------------|----------|------------------------------------------------|
| `arm64` (device)            | yes      | All 64-bit iOS devices.                        |
| `arm64` (simulator)         | yes      | Apple Silicon Mac.                             |
| `x86_64` (simulator)        | yes      | Intel Mac.                                     |
| `arm64` (Mac Catalyst)      | yes (XCFramework only) | Best-effort; not promised in v1. |
| `armv7` / `armv7s` (32-bit) | **no**   | 64-bit only since iOS 11.                       |

#### Capability matrix — what unlocks at which iOS

At our iOS 14 floor, nearly every capture API is unconditionally
available; only ProMotion variable-refresh observation requires
`@available(iOS 15, *)`.

| Minimum iOS | Captures and APIs unlocked                                                                |
|-------------|--------------------------------------------------------------------------------------------|
| 14.0 (base) | `NWPathMonitor` (incl. `unsatisfiedReason`), `URLSessionTaskMetrics`, `os_log` / `OSLog`, `CADisplayLink.preferredFramesPerSecond`, `CFRunLoopObserver`, `mach_task_basic_info` + `phys_footprint`, `DispatchSource.makeMemoryPressureSource`, `os_signpost`, `SecRandomCopyBytes`, Keychain accessibility classes, UIWindow/UIViewController swizzles, URLProtocol/URLSession delegate hooks, `ISO8601DateFormatter` with `withFractionalSeconds`, `UIApplication` + `UIScene` lifecycle, SwiftUI ViewModifiers (`.edgeRumScreen`, `.edgeRumTrackTap`), `UIHostingController` swizzle path, `MXMetricPayload` + `MXCrashDiagnostic` + `MXHangDiagnostic`, `PrivacyInfo.xcprivacy`. |
| 15.0        | `CADisplayLink.preferredFrameRateRange` for ProMotion variable refresh observation, async URLSession overloads internally.                                                                                                                                                       |
| 16.0+       | No new captures planned. Live Activities, Symbol Effects, etc. are not in scope.                                                                                                                                                                                                |

The single `@available(iOS 15, *)` ProMotion gate has a documented
fallback (assume 60 Hz target). The README's "What works on what
iOS" table (§12.1) mirrors this matrix verbatim so consumers see
the same source of truth.

### 2.3 SwiftPM `Package.swift` layout

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EdgeRum",
    platforms: [
        .iOS(.v14)            // floor
    ],
    products: [
        .library(name: "EdgeRum",       targets: ["EdgeRum"]),
        .library(name: "EdgeRumStatic", type: .static, targets: ["EdgeRum"])
    ],
    dependencies: [
        .package(url: "https://github.com/open-telemetry/opentelemetry-swift-core.git",
                 from: "2.4.1")
    ],
    targets: [ /* EdgeRum, EdgeRumCore, EdgeRumCapture, EdgeRumCrash,
                  EdgeRumOTelBridge, plus test targets */ ]
)
```

Products:

- `EdgeRum` — public umbrella library. The only thing consumers import.
- `EdgeRumStatic` — same code as `EdgeRum` but `type: .static` for
  app-extension hosts.

Targets:

- `EdgeRum` (public)
- `EdgeRumCore` (internal, `@_implementationOnly` from `EdgeRum`)
- `EdgeRumCapture` (internal)
- `EdgeRumCrash` (internal, depends on `PLCrashReporter` binary target)
- `EdgeRumOTelBridge` (internal, depends on
  `OpenTelemetryApi` + `OpenTelemetrySdk` from
  `opentelemetry-swift-core`)
- `EdgeRumTests`, `EdgeRumContractTests`, `EdgeRumCaptureTests`,
  `EdgeRumDocsTests` (§12.5)

Binary dependencies, vendored as `.binaryTarget`:

- `CrashReporter.xcframework` (PLCrashReporter) — pinned to a known
  notarized release.

Source dependencies:

- `open-telemetry/opentelemetry-swift-core` — pinned at `from: "2.4.1"`.
  Used only by `EdgeRumOTelBridge` (§5). Re-imported as
  `@_implementationOnly` from every consumer so it is invisible from
  `import EdgeRum`. We deliberately do **not** depend on the
  `open-telemetry/opentelemetry-swift` umbrella package — rationale
  in §5.4.

### 2.4 CocoaPods

- One pod: `EdgeRum`. Subspecs map 1:1 to the internal SwiftPM targets
  but are private (`s.subspec "Internal/Core"` etc., not advertised).
- Vendors the same PLCrashReporter `xcframework`.
- `s.dependency 'OpenTelemetry-Swift-Api'` and
  `s.dependency 'OpenTelemetry-Swift-Sdk'` — both published from
  `opentelemetry-swift-core` (not the umbrella). The umbrella's
  additional pods are ignored.
- `s.ios.deployment_target = '14.0'`.
- `s.swift_versions = ['5.10', '6.0']`.
- Pod's `Info.plist` mirrors the framework's `PrivacyInfo.xcprivacy`
  (§10).

### 2.5 XCFramework

- Built via `xcodebuild -create-xcframework` across
  `iphoneos`, `iphonesimulator` (arm64 + x86_64 sim), and
  `maccatalyst`. Built with Xcode 16+.
- All slices set `IPHONEOS_DEPLOYMENT_TARGET = 14.0`.
- Distributed `.xcframework.zip` with a `Package.swift` shim for
  consumers who want SwiftPM+binary.
- Includes a `PrivacyInfo.xcprivacy` and signed via
  `codesign --options=runtime` against a CI-stored Developer ID.

### 2.6 Versioning

- SemVer. Wire-format-affecting changes bump major.
- **Minimum-iOS bumps are a major version.** Going from iOS 14 → iOS 15
  is a breaking change for consumers; never sneak it in on a minor.
  This commitment is published in the README and the DocC "Stability"
  page.
- `sdk.version` attribute is the SemVer string; sourced at build time
  from a generated `Generated/EdgeRumVersion.swift`.

---

## 3. Public Swift API surface

### 3.1 Hard rule restated

No symbol exported from `EdgeRum` may contain any forbidden term
(`opentelemetry`, `otel`, `otlp`, `span`, `trace`, `tracer`,
`TracerProvider`, `SpanProcessor`, `SpanExporter`, `MeterProvider`,
`LoggerProvider`, `instrumentation`, `telemetry`, or `metric` as an
API name). Consumer-facing strings (error descriptions, debug logs
when `debug=true`, README, doc comments) follow the same firewall.

### 3.2 Types

```swift
public enum EdgeRum {
    public static func start(_ config: EdgeRumConfig)
    public static func identify(_ user: UserContext)
    public static func track(_ name: String,
                             attributes: [String: AttributeValue]? = nil)
    public static func trackScreen(_ name: String,
                                   attributes: [String: AttributeValue]? = nil)
    public static func time(_ name: String) -> RumTimer
    public static func captureError(_ error: Error,
                                    context: [String: AttributeValue]? = nil)
    public static func disable()
    public static func enable()
    public static var sessionId: String { get }
    public static var isEnabled: Bool { get }
    public static var deviceId: String { get }
    public static func handleBackgroundEvents(identifier: String,
                                              completion: @escaping () -> Void)
}

public struct EdgeRumConfig {
    public var apiKey: String                     // must start with "edge_"
    public var endpoint: URL                      // required
    public var appName: String?
    public var appVersion: String?
    public var appPackage: String?                // app.package_name
    public var appBuild: String?                  // app.build_number
    public var environment: Environment?          // .production .staging .development
    public var location: String?
    public var resolveLocation: Bool = false
    public var locationProviderUrl: URL? = URL(string: "https://ipapi.co/json/")
    public var sampleRate: Double = 1.0
    public var ignoreUrls: [NSRegularExpression] = []
    public var maxQueueSize: Int = 200
    public var flushInterval: TimeInterval = 5.0
    public var batchSize: Int = 30
    public var sanitizeUrl: ((URL) -> URL)? = nil
    public var captureNativeCrashes: Bool = true
    public var enableHangDetection: Bool = true
    public var hangTimeout: TimeInterval = 5.0
    public var captureScreens: Bool = true
    public var captureHTTP: Bool = true
    public var captureTaps: Bool = true
    public var captureRenderingPerformance: Bool = true
    public var debug: Bool = false

    public init(apiKey: String, endpoint: URL)    // designated init
}

public enum Environment: String, Sendable {
    case production, staging, development
}

public struct UserContext: Sendable {
    public var id: String?
    public var name: String?
    public var email: String?
    public var phone: String?
    public init(id: String? = nil,
                name: String? = nil,
                email: String? = nil,
                phone: String? = nil)
}

public enum AttributeValue: Sendable, Hashable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
}

extension AttributeValue: ExpressibleByStringLiteral,
                          ExpressibleByIntegerLiteral,
                          ExpressibleByFloatLiteral,
                          ExpressibleByBooleanLiteral { /* literals only */ }

public final class RumTimer {
    public func end(attributes: [String: AttributeValue]? = nil)
    public func cancel()
}

// SwiftUI helpers — unconditional at the iOS 14 floor.
extension View {
    public func edgeRumScreen(_ name: String,
                              attributes: [String: AttributeValue]? = nil) -> some View
    public func edgeRumTrackTap(_ name: String,
                                attributes: [String: AttributeValue]? = nil) -> some View
}
```

Rationale:

- `AttributeValue` is a sealed enum, so the compiler enforces
  "primitives only — String, Int, Double, Bool". Dictionaries and
  arrays cannot be passed in. This is the type-system proof of the
  contract.
- `captureError` accepts `[String: AttributeValue]?` (not `[String: Any]`)
  for the same reason. The prompt sketch used `[String: Any]`; we
  tighten it deliberately and call this out in §14 / §15.
- `RumTimer` is a class so `end()` is idempotent and `cancel()` can
  null the underlying state without consumer reference juggling.
- `EdgeRum` is a caseless `enum` so it cannot be instantiated.
- SwiftUI modifiers are unconditional. SwiftUI is available since
  iOS 13 — our iOS 14 floor lets us drop the `@available` guard
  entirely.
- All public types are `Sendable` where possible.
- `start(_:)` is idempotent — second call with same `apiKey`+`endpoint`
  is a no-op; with different values, logs a warning and ignores.
- `handleBackgroundEvents(identifier:completion:)` is the one method
  the host app must wire from
  `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
  to fully drain the queue after process death.

### 3.3 What the public surface does NOT contain

- No `Tracer`, `Span`, `SpanBuilder`, `Exporter`, `Processor`, `Meter`,
  `Logger`, `Resource`, `Attributes`, `Context`, `Baggage`, `Scope`.
- No "instrumentation" in any symbol or doc.
- No "telemetry" in any public symbol.
- No `metric` as an API name.

### 3.4 Public doc comments

Doc comments use plain product vocabulary. Reviewed by lint script
`Tools/firewall-check.sh` that greps the build output of `swift package
dump-symbol-graph` for forbidden terms and fails CI.

---

## 4. Module layout and internal architecture

### 4.1 Targets and their responsibilities

```
┌─────────────────────────────────────────────┐
│ EdgeRum (public)                            │
│   EdgeRum.swift                             │
│   EdgeRumConfig.swift                       │
│   UserContext.swift                         │
│   AttributeValue.swift                      │
│   RumTimer.swift                            │
│   Environment.swift                         │
│   SwiftUI/ViewModifiers.swift               │
│                                             │
│  → @_implementationOnly imports EdgeRumCore │
└─────────────────────────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────────┐
│ EdgeRumCore (internal)                      │
│   Recorder.swift          (façade)          │
│   EventEnvelope.swift     (wire model)      │
│   AttributeBag.swift                        │
│   IdentityProvider.swift                    │
│   SessionManager.swift                      │
│   DeviceContext.swift                       │
│   AppContext.swift                          │
│   NetworkContext.swift                      │
│   Sampler.swift                             │
│   Clock.swift                               │
│   Transport/                                │
│     BatchTransport.swift                    │
│     OfflineQueue.swift                      │
│     RetryPolicy.swift                       │
│     BackgroundUploader.swift                │
│   Persistence/                              │
│     KeychainStore.swift                     │
│     DefaultsStore.swift                     │
│     QueueFileStore.swift                    │
│                                             │
│  → @_implementationOnly imports             │
│       EdgeRumCapture, EdgeRumCrash,         │
│       EdgeRumOTelBridge                     │
└─────────────────────────────────────────────┘
                  │
       ┌──────────┼─────────────────┐
       ▼          ▼                 ▼
 ┌──────────┐ ┌─────────────┐ ┌──────────────────┐
 │ Capture  │ │ Crash       │ │ OTelBridge       │
 │ swizzles │ │ PLCrash +   │ │ wraps opentel-   │
 │ network  │ │ hang detect │ │ swift-core Api/  │
 │ screens  │ │ MetricKit   │ │ Sdk; emits       │
 │ taps     │ │             │ │ events to        │
 │          │ │             │ │ Recorder         │
 └──────────┘ └─────────────┘ └──────────────────┘
```

`@_implementationOnly` is the load-bearing keyword: a downstream
consumer importing `EdgeRum` cannot see `EdgeRumCore`, cannot see any
PLCrashReporter type, cannot see any `OpenTelemetryApi` or
`OpenTelemetrySdk` type. This is the language-level firewall.

### 4.2 Recorder façade

`Recorder` is the single fan-in for everything every capture surface
produces. Its surface (internal, not exported):

```swift
final class Recorder {
    func recordEvent(name: String,
                     timestamp: Date,
                     attributes: AttributeBag)
    func recordMetric(name: String,
                      value: Double,
                      timestamp: Date,
                      attributes: AttributeBag)
    func flush(reason: FlushReason)
    func shutdown()
}
```

The `OTelBridge` (§5) is one of many things that call `Recorder`.
Captures that don't need OTel call `Recorder` directly.

### 4.3 Threading model

- One serial `DispatchQueue` per concerns group:
  - `edge.rum.recorder` — Recorder ingress (QoS `.utility`)
  - `edge.rum.transport` — HTTP I/O (QoS `.background`)
  - `edge.rum.capture.runloop` — hang/long-task observer (custom thread)
  - `edge.rum.crash` — PLCrashReporter init / replay
- No public surface returns control on a private queue; all consumer
  callbacks (`sanitizeUrl`) are dispatched on `Recorder.recordEvent`'s
  caller queue.
- See §11 for memory and CPU budgets.

---

## 5. OpenTelemetry usage — internal only

`opentelemetry-swift-core` (the API + SDK package, pinned at
`from: "2.4.1"`) is used as an in-process *event model and attribute
bag*, not as a transport. We never serialize an OTel `SpanData` to
OTLP. We use it to:

- Define attribute primitives (the OTel `AttributeValue` enum is a
  near-mirror of ours; we convert at the bridge).
- Pull a few well-tested utilities.
- Provide a `SpanProcessor`/`LogRecordProcessor` adapter so any
  consumer that ever feeds OTel data into our pipeline funnels it
  through our `Recorder`. In v1 this is architectural insurance,
  not a load-bearing path — every capture surface in §6 calls
  `Recorder.recordEvent` directly.

We deliberately do **not** depend on the upstream
`opentelemetry-swift` umbrella package, and we do not adopt any
upstream instrumentation library (`URLSessionInstrumentation`,
`NetworkStatus`, `MetricKitInstrumentation`, `Sessions`,
`ResourceExtension`, `SignPostIntegration`, `PersistenceExporter`).
Rationale in §5.4.

### 5.1 The bridge

`EdgeRumOTelBridge` exposes one internal type:

```swift
// internal, not exported beyond EdgeRumCore
struct OTelToRecorderAdapter: SpanProcessor, LogRecordProcessor {
    let recorder: Recorder
    // converts each finished SpanData -> Recorder.recordEvent
    // with eventName derived from a fixed mapping (NOT the span name)
}
```

Mapping rules in the bridge:

- An OTel span fed in by any future opt-in path becomes
  `eventName: "http.request"` (or another allowlisted name, by a
  fixed dispatch table) with attributes copied from the span and
  renamed to our dot-notation keys (`http.method`, `http.url`,
  `http.status_code`, `http.duration_ms`, etc.). Never `span.name`,
  `span.kind`, `traceId`, or `spanId`.
- An OTel log record (if we use the logs API for errors) becomes
  `eventName: "app.crash"` if the log's body or attributes indicate an
  error; otherwise dropped.
- Span links, trace IDs, parent IDs are dropped at the bridge.

### 5.2 What we will NOT do with OTel

- No `OtlpHttpExporter`. No exporter that talks to the network. The
  only exporter is `OTelToRecorderAdapter`.
- No semantic conventions package on the consumer side.
- No `TracerProvider` exposed; constructed in `Recorder.bootstrap()`
  and stored in an internal singleton.
- No baggage in v1.

### 5.3 Alternative considered

If `opentelemetry-swift-core` is judged to be more weight than value
(binary size, init cost), swap `EdgeRumOTelBridge` for a hand-rolled
minimal event model in one PR. No public-API change. This is the
architectural insurance.

### 5.4 Why we are NOT using the upstream `opentelemetry-swift` umbrella

The umbrella `opentelemetry-swift` package (separate repository as
of v2) ships maintained instrumentations that overlap with our §6
capture surfaces. We considered adopting them and rejected:

- **Wire-contract mismatch.** Our envelope (`telemetry_batch`, flat
  attributes, no `traceId`/`spanId`, exact `eventName` allowlist)
  forces us to rewrite every upstream span/log before it reaches
  the network. We pay the upstream code-generation and runtime cost
  without simplifying our pipeline.
- **`Sessions` instrumentation is incompatible.** Upstream's
  `SessionManager` persists its own UserDefaults-stored UUID-shaped
  IDs and emits OTel log records on session start/end. Our wire
  demands `session_<epochMs>_<hex>_ios` plus `session.start_time`
  plus a `session.sequence` counter incremented on transport ack.
  Bolting on a translation layer would be more code than rebuilding.
- **Dependency graph.** Adopting even one umbrella product
  (`URLSessionInstrumentation`, `NetworkStatus`, etc.) resolves the
  whole package and brings in `grpc-swift`, `swift-nio`,
  `swift-protobuf`, `Thrift-Swift`, and `opentracing-objc` through
  SPM resolution. SPM does not link unused targets, so binary size
  is fine — but our SBOM and build time both suffer. The lean
  core-only path keeps the resolved graph to `swift-atomics` plus
  `opentelemetry-swift-core`.
- **iOS floor.** The umbrella declares `iOS(.v13)`. We commit to
  iOS 14, so the floor is not the deciding factor — but adopting
  the umbrella would silently raise our resolved transitive
  minimum, removing one degree of freedom for future revisions.

---

## 6. Capture surfaces

Each subsection lists: source API, hook mechanism, mapped event/metric
name, attributes emitted, threading, opt-out flag, edge cases, and
**minimum iOS version**.

### 6.0 iOS availability matrix

At the iOS 14 floor, all capture surfaces are unconditional except
ProMotion variable-refresh observation, which requires iOS 15+.

| Capture                          | Min iOS | Notes                                                          |
|----------------------------------|---------|----------------------------------------------------------------|
| UIKit screen tracking            | 14.0    | Full feature.                                                  |
| SwiftUI screen tracking          | 14.0    | Full feature.                                                  |
| HTTP request (URLProtocol)       | 14.0    | Full feature.                                                  |
| HTTP delegate-swizzle fallback   | 14.0    | Full feature.                                                  |
| `URLSessionTaskMetrics`          | 14.0    | Full feature.                                                  |
| `page_load`                      | 14.0    | Full feature.                                                  |
| Tap / interaction                | 14.0    | Full feature.                                                  |
| `EdgeRum.captureError`           | 14.0    | Full feature.                                                  |
| PLCrashReporter crashes          | 14.0    | Full feature.                                                  |
| Hang detection (runloop watchdog)| 14.0    | Full feature.                                                  |
| Frame render (`CADisplayLink`)   | 14.0    | iOS 14: `preferredFramesPerSecond`; iOS 15+: `preferredFrameRateRange` for ProMotion variable refresh. |
| Memory usage (mach + pressure)   | 14.0    | Full feature; `phys_footprint` unconditional.                  |
| Long task                        | 14.0    | Full feature.                                                  |
| `session.started` / `finalized`  | 14.0    | Both `UIApplication` and `UIScene` lifecycle paths supported.  |
| App lifecycle                    | 14.0    | Full feature.                                                  |
| Network connectivity             | 14.0    | `NWPathMonitor` + `NWPath.unsatisfiedReason` (iOS 14.2+; the small dot-release gap is treated as base). |
| MetricKit augmentation           | 14.0    | `MXMetricPayload` + `MXCrashDiagnostic` + `MXHangDiagnostic` all unconditional. |

The single remaining `@available(iOS 15, *)` gate (ProMotion observation)
has a documented fallback: assume `frame.target_hz = 60` on iOS 14.

### 6.1 Screen tracking — UIKit

- **Source**: `UIViewController.viewDidAppear(_:)` and
  `viewWillDisappear(_:)`.
- **Hook**: method swizzling in
  `EdgeRumCapture.UIViewControllerCapture.install()`, called from
  `EdgeRum.start()` on the main thread, guarded by
  `dispatch_once`-equivalent.
- **eventName** on appear: `navigation`.
- **metricName** on disappear: `screen.duration` (a `metric`).
- **Attributes**:
  - `navigation.screen` = class name (or `accessibilityIdentifier` or
    custom title if set), `String`
  - `navigation.previous_screen` = last `navigation` event's screen
  - `navigation.type` = `"viewDidAppear"`
  - `navigation.kind` = `"uikit"`
  - For `screen.duration`: `value` = dwell in seconds (Double),
    `screen.name` = class name, `screen.duration_ms` = Int
- **Opt-out**: `config.captureScreens == false`.
- **Edge cases**:
  - Container VCs (`UINavigationController`, `UITabBarController`,
    `UIPageViewController`): skip via `is` checks.
  - Quick presentations under 200ms: not filtered;
    `screen.duration_ms` carries the truth.

### 6.2 Screen tracking — SwiftUI

- **Source**: no SwiftUI-native `viewDidAppear`. Two paths:
  1. **Public ViewModifier**: `.edgeRumScreen("Cart")` exposed via an
     unconditional `extension View`. Implementation uses `.onAppear`
     / `.onDisappear`. Named with the product prefix so the public
     surface stays clean.
  2. **Automatic UIHostingController detection**: the UIKit
     swizzle fires when a SwiftUI screen is presented via
     `UIHostingController<Content>`. We emit `navigation` with
     `navigation.screen` = `String(reflecting: Content.self)`, and
     `navigation.kind = "swiftui"`.
- **eventName**: `navigation` and `screen.duration` — same as UIKit.
  No new eventNames.
- **Attribute differentiator**: `navigation.kind` ∈ `"uikit"`,
  `"swiftui"`, `"hosting"`.

### 6.3 HTTP request capture

- **Source**: `URLSession`. Two layered hooks:
  1. `URLProtocol` subclass registered globally.
  2. `URLSessionConfiguration` swizzle to inject our delegate proxy on
     `default` and `ephemeral`.
- **eventName**: `http.request`.
- **Attributes**: `http.method`, `http.url`, `http.host`, `http.path`,
  `http.status_code` (Int), `http.duration_ms` (Int),
  `http.request_size`, `http.response_size`, `http.error` (String,
  if any), `http.from_cache` (Bool).
- **`resource_timing` metric**: read `URLSessionTaskMetrics` after the
  task completes, emit `metric` with `metricName = "resource_timing"`,
  attributes: `resource.dns_ms`, `resource.connect_ms`, `resource.tls_ms`,
  `resource.ttfb_ms`, `resource.response_ms`.
- **Suppress own POSTs**: URL prefix check + thread-local marker
  (`task.taskDescription = "edge-rum-internal"`) + `X-Edge-Rum-Internal: 1`
  request header — three checks for defense-in-depth.
- **Combine and async/await**: both go through `URLSession`; no special
  casing. Our hooks see them as ordinary tasks.
- **`sanitizeUrl`**: synchronous callback on caller thread.
- **`ignoreUrls`**: regex matched against `http.url`; on match the
  event is dropped before enqueue.
- **Opt-out**: `config.captureHTTP == false`.
- **Edge case**: `URLSessionConfiguration.background` sessions not
  instrumented; documented.

### 6.4 `page_load` analogue

- **Source**: `UIApplication.didFinishLaunchingNotification` start time
  → first `CADisplayLink` callback after the app is `.active`.
- **eventName**: `page_load`.
- **Attributes**:
  - `page_load.duration_ms` (Int)
  - `page_load.cold` (Bool)
  - `page_load.prewarm` (Bool — from
    `ProcessInfo.processInfo.environment["ActivePrewarm"] == "1"`,
    iOS 15+; absent on iOS 14).
- Fired exactly once per process.

### 6.5 Tap / interaction capture

- **Source**: `UIWindow.sendEvent(_:)`.
- **Hook**: swizzle on `UIWindow` to inspect `UIEvent.allTouches`.
- **eventName**: `user.interaction`.
- **Attributes**:
  - `interaction.kind` = `"tap"`
  - `interaction.target` = view class name
  - `interaction.target_id` = `accessibilityIdentifier` or
    `UIButton.title`; nil-omitted otherwise
  - `interaction.screen` = current `navigation.screen`
- **Privacy**: skip `isSecureTextEntry == true` fields; never record
  text values.
- **Opt-out**: `config.captureTaps == false`.

### 6.6 Error capture (JS-error analogue)

- **Source**: explicit `EdgeRum.captureError(_:context:)`.
- **eventName**: `app.crash` with `cause = "AppError"`.
- **Attributes**: `error.type`, `error.message`, `error.kind`
  (`"swift"`/`"nserror"`), `error.domain` / `error.code` /
  flattened `error.userInfo` for `NSError`, `error.stack` captured
  synchronously at call site, `runtime = "swift"`.

### 6.7 Native crash — NSException + Mach signal

- **Source**: PLCrashReporter with BSD signal handler + Mach exception
  handling. Catches Mach signals
  (`SIGSEGV`/`SIGABRT`/`SIGBUS`/`SIGILL`/`SIGFPE`) and NSException.
- **eventName**: `app.crash`.
- **Attributes**: `cause = "NativeCrash"`, `runtime = "native"`,
  `crash.signal`, `crash.exception_name`, `crash.exception_reason`,
  `crash.report_json` (the PLCR raw report base64-or-JSON-stringified
  into a single String attribute, since the wire forbids nested objects),
  `crash.binary_uuid`, `crash.report_format_version`.
- **Replay on next launch**: read pending report → restore previous
  session/identity from crash sidecar → emit one `app.crash` →
  flush immediately → delete report.

### 6.8 Main-thread hangs

- **Source**: `CFRunLoopObserver` on the main runloop, timed by a
  dedicated watchdog `Thread`.
- **eventName**: `app.crash` with `cause = "Hang"`, `runtime = "native"`.
- **Attributes**: `hang.duration_ms`, `hang.stack` (best-effort),
  `hang.threshold_ms`.
- **No private APIs**.
- **MetricKit augmentation (iOS 14+)**: `MXHangDiagnostic` payloads
  enrich the hang stack on a 24h-delayed basis.

### 6.9 Web Vitals — omitted in v1.

### 6.10 Frame render time
**ProMotion variable-refresh observation gated on iOS 15+.**

- **Source**: `CADisplayLink` attached to `.common` runloop modes.
- **iOS 14**: use `preferredFramesPerSecond`. `frame.target_hz`
  reports 60 Hz unconditionally on non-ProMotion devices.
- **iOS 15+**: use `preferredFrameRateRange`. `frame.target_hz`
  reports the actual range for ProMotion (`maximum` of the range,
  e.g. 120).
- **eventName**: `metric` with `metricName = "frame_render_time"`.
- **Attributes**: `frame.max_ms`, `frame.p95_ms`,
  `frame.dropped_count`, `frame.target_hz`, `frame.source =
  "displaylink"`.
- **MetricKit augmentation**:
  `MXAnimationMetric.scrollHitchTimeRatio` populates
  `frame.scroll_hitch_ratio` on the daily payload, with
  `frame.source = "metrickit"`.

### 6.11 Memory usage

- **Source A**: poll `mach_task_basic_info` every 10s.
- **Source B**: `DispatchSource.makeMemoryPressureSource(eventMask:
  .all, queue: ...)`.
- **eventName**: `metric` with `metricName = "memory_usage"`.
- **Attributes**: `memory.resident_kb`, `memory.virtual_kb`,
  `memory.footprint_kb` (via `phys_footprint`),
  `memory.pressure` ∈ `"normal"`/`"warning"`/`"critical"`.
- **MetricKit augmentation**: `MXMemoryMetric` fills
  `memory.peak_usage_kb`.

### 6.12 Long task

- Same `CFRunLoopObserver` as hang detection (§6.8). Threshold 50ms.
- **eventName**: `metric` with `metricName = "long_task"`.
- **Attributes**: `value` (Double ms), `long_task.threshold_ms`,
  `long_task.stack`.

### 6.13 Resource timing — covered by §6.3.

### 6.14 `session.started`

- **Source**: `EdgeRum.start()` + `UIApplication.didBecomeActive` /
  `UIScene.didActivate`. The SDK subscribes to both; whichever is
  wired in the host app fires first wins.
- **eventName**: `session.started`.
- **Attributes**: `session.id`, `session.start_time`,
  `session.sequence = 0`, `session.is_resumed`.

### 6.15 `session.finalized`

- **Source**: `UIApplication.willResignActive` /
  `UIScene.willDeactivate`; dedup if both fire.
- **eventName**: `session.finalized`.
- **Attributes**: `session.id`, `session.duration_ms`,
  `session.event_count`.
- **Behavior**: triggers immediate flush.

### 6.16 `user.profile.update` and `custom_event`

- **`identify()`** → `eventName: "user.profile.update"`.
- **`track()`** → `eventName: "custom_event"`, consumer-provided name
  goes into attribute `event.name`.

### 6.17 `time()`

- **`time(_:) -> RumTimer`** captures the start moment.
- **`.end()`** emits `metric` with `metricName = <name>`,
  `value = elapsed_ms`.
- **`.cancel()`** discards. Idempotent.

### 6.18 App lifecycle

- **Source**: UIApplication notifications and UIScene notifications.
- **eventName**: `app_lifecycle`.
- **Attributes**: `lifecycle.state` ∈ `"foregrounded"`/`"backgrounded"`/
  `"will_terminate"`/`"active"`/`"inactive"`.

### 6.19 Network connectivity change

- **Source**: `NWPathMonitor`.
- **eventName**: `network_change`.
- **Attributes**: `network.type` ∈ `"wifi"`/`"cellular"`/`"wired"`/
  `"loopback"`/`"unknown"`/`"none"`, `network.effectiveType`,
  `network.is_expensive`, `network.is_constrained`.
- `NWPath.unsatisfiedReason` (iOS 14.2+) populates a
  `network.unsatisfied_reason` attribute when path is `.unsatisfied`.
  On iOS 14.0 / 14.1 the attribute is omitted.

---

## 7. Wire format conformance

The endpoint, headers, envelope, identity attribute set, and per-event
shape are all fixed by the existing SDKs.

### 7.1 HTTP request

```
POST <config.endpoint>/collector/telemetry
X-API-Key: <config.apiKey>
Content-Type: application/json
User-Agent: EdgeRum-iOS/<sdk.version> (<device.model>; iOS <os>)
```

### 7.2 Envelope

```json
{
  "type": "telemetry_batch",
  "timestamp": "2026-06-14T10:15:32.512Z",
  "location": "Nairobi/Kenya",
  "batch_size": 3,
  "events": [ /* … */ ]
}
```

`timestamp` uses `ISO8601DateFormatter` with
`[.withInternetDateTime, .withFractionalSeconds]`. `JSONEncoder`
runs with `outputFormatting = []`; dates are encoded as strings
manually (since older runtimes' `.iso8601` strategy omits fractional
seconds).

### 7.3 Per-event shape (event)

```json
{
  "type": "event",
  "eventName": "navigation",
  "timestamp": "2026-06-14T10:15:32.512Z",
  "attributes": {
    "navigation.screen": "CartViewController",
    "navigation.kind": "uikit",
    "app.package_name": "com.example.shop",
    "app.version": "1.4.2",
    "device.id": "device_1717234876123_a1b2c3d4e5f60718_ios",
    "device.platform": "ios",
    "device.model": "iPhone15,3",
    "device.os": "ios",
    "device.platform_version": "17.4.1",
    "network.type": "wifi",
    "network.effectiveType": "4g",
    "session.id": "session_1717234870002_ff009988aabbccdd_ios",
    "session.start_time": "2026-06-14T10:15:30.002Z",
    "session.sequence": 12,
    "user.id": "user_1717100000000_deadbeefcafef00d",
    "sdk.version": "1.0.0",
    "sdk.platform": "ios-native"
  }
}
```

### 7.4 Per-event shape (metric)

```json
{
  "type": "metric",
  "metricName": "frame_render_time",
  "value": 18.4,
  "timestamp": "2026-06-14T10:15:35.000Z",
  "attributes": { "frame.target_hz": 60, "...": "..." }
}
```

### 7.5 Attribute key mapping table

iOS-side internal name → wire key.

| Domain  | Source                                                          | Wire key                  |
|---------|-----------------------------------------------------------------|---------------------------|
| App     | `Bundle.main.bundleIdentifier`                                  | `app.package_name`        |
| App     | `CFBundleDisplayName`                                           | `app.name`                |
| App     | `CFBundleShortVersionString`                                    | `app.version`             |
| App     | `CFBundleVersion`                                               | `app.build_number`        |
| App     | `config.environment?.rawValue`                                  | `app.environment`         |
| Device  | persistent SDK-owned identifier (§8)                            | `device.id`               |
| Device  | constant `"ios"`                                                | `device.platform`         |
| Device  | `utsname.machine`                                               | `device.model`            |
| Device  | constant `"Apple"`                                              | `device.manufacturer`     |
| Device  | constant `"ios"`                                                | `device.os`               |
| Device  | `UIDevice.current.systemVersion`                                | `device.platform_version` |
| Device  | `TARGET_OS_SIMULATOR` flag                                      | `device.isVirtual`        |
| Device  | `UIScreen.main.nativeBounds.width`                              | `device.screenWidth`      |
| Device  | `UIScreen.main.nativeBounds.height`                             | `device.screenHeight`     |
| Device  | `UIScreen.main.nativeScale`                                     | `device.pixelRatio`       |
| Device  | `UIDevice.current.batteryLevel`                                 | `device.batteryLevel`     |
| Device  | `UIDevice.current.batteryState == .charging \|\| .full`         | `device.batteryCharging`  |
| Network | NWPathMonitor                                                   | `network.type`            |
| Network | derived (§6.19)                                                 | `network.effectiveType`   |
| Session | `SessionManager.current.id`                                     | `session.id`              |
| Session | ISO 8601 of session start                                       | `session.start_time`      |
| Session | `SessionManager.current.sequence`                               | `session.sequence`        |
| User    | `IdentityProvider.user.id`                                      | `user.id`                 |
| User    | `IdentityProvider.user.name`                                    | `user.name`               |
| User    | `IdentityProvider.user.email`                                   | `user.email`              |
| User    | `IdentityProvider.user.phone`                                   | `user.phone`              |
| SDK     | build-time constant                                             | `sdk.version`             |
| SDK     | constant `"ios-native"`                                         | `sdk.platform`            |

### 7.6 Type discipline

`AttributeBag` rejects any value not in {String, Int, Double, Bool}.
The bag holds an internal `AttributeValue` enum identical in shape to
the public one (§3) and used everywhere; `JSONEncoder` encodes each
case to its raw type.

### 7.7 What we will NOT emit

- No `traceId`, `spanId`, `parentSpanId`.
- No `resource` object, no nested `attributes.kind` object.
- No `severity_number`, no `severity_text`.
- No `body` field at the top level of an event.
- No event with `eventName` outside the §6 table.

---

## 8. Session, identity, and ID generation

### 8.1 Identity types

| ID         | Format                                              | Storage             |
|------------|-----------------------------------------------------|---------------------|
| device.id  | `device_{epochMs}_{16 hex}_ios`                     | Keychain            |
| session.id | `session_{epochMs}_{16 hex}_ios`                    | UserDefaults        |
| user.id    | `user_{epochMs}_{16 hex}`                           | UserDefaults        |

16 hex chars = 64 bits of entropy from `SecRandomCopyBytes`
(8 random bytes, `%02x`). Not `UUID()`.

### 8.2 Storage choice: Keychain vs UserDefaults

- **`device.id` in Keychain** with
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. iOS 10.3+ clears
  the keychain on uninstall, so device.id regenerates on reinstall in
  practice. Stated explicitly in §12 README "Privacy" section.
- **`session.id` and `user.id` in UserDefaults**, suite
  `com.edge.rum.session`. UserDefaults is faster; session is
  short-lived; user.id durability is host-app concern.

### 8.3 Session lifecycle

- Session starts on `EdgeRum.start()` if no active session, OR if the
  persisted session is older than 30 minutes of last-active time.
- Last-active updates on every `didBecomeActive` and every
  `Recorder.recordEvent`.
- Expiry triggers `session.finalized` then `session.started`.
- `session.sequence` starts at 0; increments on every successfully sent
  batch (transport ack); persisted under an `NSLock`.

### 8.4 Crash sidecar

`Library/Caches/edge-rum/last-session.json` mirrors current identity
on every event. Read on next launch when a crash report is pending,
so the replay event carries the *previous* session.

---

## 9. Transport, retry, offline queue, batching

### 9.1 Batching

Recorder enqueues into an in-memory ring buffer.
`BatchTransport` triggers when ANY of:
- buffer size ≥ `config.batchSize` (default 30)
- `config.flushInterval` elapsed (default 5s)
- `session.finalized` enqueued (immediate)
- `app.crash` with `cause == "AppError"` (immediate)
- `UIApplication.willResignActiveNotification`

### 9.2 Send path

- Primary: `URLSession` with `URLSessionConfiguration.default`,
  `httpAdditionalHeaders` carrying `X-API-Key`, `Content-Type:
  application/json`, and `X-Edge-Rum-Internal: 1`.
- Our session is created *before* swizzles install.
- `task.taskDescription = "edge-rum-internal"` for defence-in-depth.

### 9.3 Retry policy

- On status 0 / 429 / 503: retry 0s → 2s → 8s → 30s → push to offline.
- Respect `Retry-After` (cap 60s).
- Non-retryable 4xx (other than 429): drop the batch and log in `debug`.
- 5xx other than 503: treat as 503.

### 9.4 Offline queue

- Files under `Library/Caches/edge-rum/queue/<epochMs>-<seq>.json`.
- Cap: `maxQueueSize` total events; FIFO drop on overflow.
- Replay on: `NWPathMonitor` `.satisfied`, `didBecomeActive`,
  `enable()`.

### 9.5 Background flush

- Separate `URLSession` with
  `URLSessionConfiguration.background(withIdentifier:
  "com.edge.rum.upload")`.
- Host wires
  `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
  → `EdgeRum.handleBackgroundEvents(identifier:completion:)`.
- Falls back to next-foreground replay if unwired.

### 9.6 Sampling

Per-session uniform random vs `sampleRate`. Excluded sessions emit
only `session.started`, `session.finalized`, `app.crash`, and
`network_change`.

---

## 10. Privacy, opt-in flags, IP geolocation

### 10.1 IDs

- No IDFA. No IDFV.
- `device.id` is SDK-owned, generated locally, stored in Keychain.

### 10.2 ATT

- We do not call `ATTrackingManager.requestTrackingAuthorization()`.
- We do not read IDFA. No `AdSupport` import.

### 10.3 IP geolocation

- Off by default. When on: GET `<locationProviderUrl>` once on first
  session, parse `city` and `country_name`, cache 24 hours in
  UserDefaults.
- Tagged `X-Edge-Rum-Internal: 1` to prevent self-capture.

### 10.4 `PrivacyInfo.xcprivacy`

Declared restricted-reason APIs (per Apple's required-reason list):

| API category           | Reason code | Use                                              |
|------------------------|-------------|--------------------------------------------------|
| File timestamp APIs    | `C617.1`    | Queue file mtime for FIFO ordering               |
| System boot time APIs  | `35F9.1`    | Uptime in `page_load`                            |
| Disk space APIs        | `E174.1`    | Skip queue persistence on low disk               |
| User defaults APIs     | `CA92.1`    | Storing session.id / user.id                     |

The `PrivacyInfo.xcprivacy` manifest ships in every framework slice
and is enforced by Apple at App Store submission; at the iOS 14 floor
the manifest's required-reason behaviour is consistent across all
supported OS versions.

Data collected:
- `NSPrivacyCollectedDataTypeCrashData`
- `NSPrivacyCollectedDataTypePerformanceData`
- `NSPrivacyCollectedDataTypeOtherDiagnosticData`
- `NSPrivacyCollectedDataTypeUserID` (when `identify()` is used)

Linked to user: TRUE for the above when `identify()` is used.
Used for tracking: FALSE.

### 10.5 Opt-out flags

All capture-disabling booleans skip swizzle registration entirely.
There is no runtime "recording but not emitting" mode.

### 10.6 Disable / enable

- `disable()`: stop emission + flush timer; queue stays on disk.
- `enable()`: resume. State persists across launches in UserDefaults.

### 10.7 Secure text fields

Tap capture skips any view in a responder chain ending at an
`isSecureTextEntry == true` text field. Never read `text` values.

### 10.8 URL sanitization

`config.sanitizeUrl` is called on every captured URL before recording.
Also applies to `resource_timing` URLs.

---

## 11. Threading, performance budget, memory ceiling

### 11.1 Threads

- Main: swizzle install at `start()` (~5ms), then read-only.
- Recorder ingress on `edge.rum.recorder` (`.utility`).
- Transport I/O on `edge.rum.transport` (`.background`).
- Watchdog thread for hang detector, dedicated `Thread`,
  `.userInitiated`.

### 11.2 CPU budget (steady state)

Budgets are tiered by device class. CI gates against the modern
target; weekly perf-lab runs gate against the mid target.

| Device class                | 1 ev/s budget | 30 ev/s budget |
|-----------------------------|---------------|----------------|
| Modern (iPhone 12+)         | < 0.3% CPU    | < 2% CPU       |
| Mid (iPhone 8 / SE2 / 11)   | < 0.5% CPU    | < 3% CPU       |

### 11.3 Memory ceiling

- In-memory buffer: max 200 items (~300 KB).
- Offline queue file cap: 5 MB.
- Per-batch JSON: ~45 KB for 30 events.
- Total resident overhead target: < 4 MB across all supported devices.

### 11.4 Binary size budget

- `EdgeRum` framework slim dynamic arm64: target < 1.4 MB
  (~400–500 KB from `opentelemetry-swift-core` Api+Sdk linked,
  ~600 KB PLCrashReporter shared, remainder our code).
- Without `opentelemetry-swift-core` (§5.3): target < 900 KB.
- The iOS 14 floor leaves at most a handful of bytes for the
  single `@available(iOS 15, *)` ProMotion path.

### 11.5 Cold start cost

Tiered by device class:

| Device                 | Target            |
|------------------------|-------------------|
| iPhone 12 and newer    | < 8 ms wall       |
| iPhone 8 / SE2 / 11    | < 18 ms wall      |

`start()` returns synchronously; heavy bootstrap is dispatched to
`edge.rum.recorder.bootstrap`. First send happens at the first
flush tick, never synchronously from `start()`.

---

## 12. Documentation, README, and developer experience

Documentation is shipped as part of the SDK release artifact, not as
an afterthought. The README and the DocC catalog are the two
canonical surfaces; sample apps are the proof. A new iOS developer
should be able to integrate the SDK and see their first event in the
backend in **under 10 minutes** without leaving the README.

### 12.1 README.md — structure

The single `README.md` at repo root is the entry point for every
consumer. It is written for an iOS engineer who has heard of RUM but
never seen the SDK before. Hard size limit: ~600 lines. Sections, in
order:

1. **Badge row** — SwiftPM compatible, CocoaPods version,
   supported iOS, license, CI status. No npm badges, no irrelevant
   ones.
2. **One-paragraph TL;DR** — what this is, what it captures, where
   the data goes. Mentions "no OpenTelemetry vocabulary exposed,"
   "JSON only," "App Store reviewable."
3. **Supported iOS table** — copy of §2.2 capability matrix.
   Crucial: a consumer must know within 30 seconds whether their
   floor matches.
4. **Install** — three side-by-side blocks:
   - SwiftPM: `dependencies: [.package(url: "…", from: "1.0.0")]`
   - CocoaPods: `pod 'EdgeRum', '~> 1.0'`
   - XCFramework: link to the GitHub Release with copy-paste
     drag-and-drop instructions
5. **5-minute quickstart** — three sub-tabs, one each for:
   - **UIKit / AppDelegate**:
     ```swift
     import EdgeRum

     func application(_ application: UIApplication,
                      didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
         var config = EdgeRumConfig(apiKey: "edge_…",
                                    endpoint: URL(string: "https://your.endpoint")!)
         config.appName = "Shop"
         config.environment = .production
         EdgeRum.start(config)
         return true
     }
     ```
   - **UIKit / SceneDelegate**.
   - **SwiftUI App**:
     ```swift
     @main
     struct ShopApp: App {
         init() {
             var config = EdgeRumConfig(apiKey: "edge_…",
                                        endpoint: URL(string: "https://your.endpoint")!)
             EdgeRum.start(config)
         }
         var body: some Scene {
             WindowGroup {
                 ContentView().edgeRumScreen("Home")
             }
         }
     }
     ```
6. **Configuration reference** — every `EdgeRumConfig` field in a
   table with default, type, purpose, and a one-line example.
7. **What gets captured automatically** — list of auto-captures
   with a one-sentence "what it sends" each.
8. **Recipes** (each is < 20 lines):
   - Identify a user
   - Track a custom event
   - Time an operation with `RumTimer`
   - Capture an error
   - Track a SwiftUI screen
   - Track a UIKit screen manually
   - Sanitize URLs (strip tokens from query)
   - Ignore certain URLs
   - Opt out of HTTP capture
   - Disable / enable at runtime
   - Wire background flush (this is the one mandatory consumer step
     beyond `start()`)
9. **What gets sent** — one realistic batch JSON example (copy from
   §7.3), plus a one-line "every value here is a primitive."
10. **Privacy and App Store** — IDFA-free, ATT-neutral, declared
    restricted-reason APIs (linked to §10.4), keychain behaviour on
    reinstall, links to `PrivacyInfo.xcprivacy`.
11. **Versioning and stability** — SemVer commitment,
    minimum-iOS-bumps-are-major commitment, deprecation policy
    (one minor cycle of warning before removal).
12. **Troubleshooting** — top 5 issues:
    - "I don't see any events" → enable `debug = true`, check
      `X-API-Key` prefix, check endpoint is reachable.
    - "App Store rejected my upload" → check the SDK's privacy
      manifest is merged with the host app's.
    - "My HTTP requests aren't captured" → check the URLSession is
      not a background-session.
    - "Crash event arrived without the previous session ID" → check
      the crash sidecar permissions.
    - "Cold start is slow on iPhone SE 2" → expected; see §11.5.
13. **FAQ** — six entries:
    - Why no Web Vitals?
    - Can I use this in an extension?
    - Does this collect IDFA?
    - Why doesn't it require ATT?
    - Why isn't there an OpenTelemetry exporter?
    - What's the supported-iOS commitment?
14. **Migrating to a new major version** — link to
    `docs/migration/<version>.md`. Empty in v1 but the section header
    stays for muscle memory.
15. **Contributing and license** — links and a short note.

The README is build-time tested: every code block is extracted by a
script (§12.5) and compiled against the package. A broken README is a
CI failure.

### 12.2 DocC catalog — `Sources/EdgeRum/EdgeRum.docc/`

Authoritative API reference. Built by `swift package
generate-documentation` and hosted as GitHub Pages from `docs-site/`
(generated artifact, committed periodically by CI).

Structure:

```
EdgeRum.docc/
├── EdgeRum.md             ← landing page, mirrors README TL;DR
├── GettingStarted.md      ← extended quickstart with UIKit + SwiftUI
├── Configuration.md       ← prose around EdgeRumConfig
├── Captures.md            ← what auto-captures emit
├── Privacy.md             ← duplicate of README §10 for SEO inside Xcode
├── Stability.md           ← versioning commitments
├── Recipes/
│   ├── IdentifyUser.md
│   ├── TrackCustomEvent.md
│   ├── TimeOperation.md
│   ├── CaptureError.md
│   ├── SanitizeURLs.md
│   └── BackgroundFlush.md
└── Resources/
    └── arch-overview.png  ← one diagram showing public/internal boundary
```

Rules:

- Every `public` symbol carries a `///` doc comment. CI fails on
  undocumented public symbols (`swift package
  diagnose-api-documentation` or equivalent).
- Doc comments use product vocabulary only (Rule 1 firewall extends
  here). A separate CI grep enforces this.
- Code samples inside doc comments are compiled by the
  `EdgeRumDocsTests` target — see §12.5.

### 12.3 Sample apps — `Samples/`

Three runnable Xcode projects, each its own `xcodeproj`. Building
them is part of CI on PRs.

- **`Samples/EdgeRumSampleApp/`** — UIKit. Demonstrates AppDelegate
  init, multiple view controllers (so `navigation` and
  `screen.duration` are exercised), a couple of `URLSession.shared`
  calls (HTTP capture), and a debug screen with buttons that fire
  `track()`, `identify()`, `time()`, and `captureError()`.
- **`Samples/EdgeRumSwiftUISampleApp/`** — SwiftUI App.
  Demonstrates the `.edgeRumScreen` and `.edgeRumTrackTap` modifiers,
  navigation, and the `@main` entry point.
- **`Samples/EdgeRumCrashSampleApp/`** — UIKit. Has buttons that
  intentionally produce a `SIGSEGV`, an `NSException`, an
  `EdgeRum.captureError()`, and a 6s main-thread block. Used for the
  manual QA of crash replay and for the UI test in §13.3.

Each sample's `README.md` is one screenshot + one paragraph + how to
plug in your own API key.

### 12.4 Migration guide template

`docs/migration/TEMPLATE.md` is in the repo from day one. When v2
lands, it's copied to `docs/migration/v1-to-v2.md`. Template sections:

- What's changing
- Why
- Wire format impact (yes / no)
- Public API diff with before/after Swift
- Auto-mappable changes (we ship a Swift codemod when feasible)
- Manual changes needed
- Minimum iOS impact

### 12.5 Doc-quality CI

`EdgeRumDocsTests` target plus three scripts run on every PR:

- **`Tools/extract-readme-code.sh`** — pulls every fenced Swift block
  out of `README.md` and `EdgeRum.docc/**/*.md`, wraps each in a
  minimal compilable Swift file, builds them against the package.
  Test fails if any block doesn't compile or uses a banned term.
- **`Tools/check-links.sh`** — runs `lychee` over all `.md` files.
  Fails on any broken link.
- **`Tools/check-supported-ios.sh`** — diffs the README's "Supported
  iOS" table against `Package.swift`'s platforms declaration and
  `PLAN-iOS.md` §2.2. Fails on mismatch — a single source of truth
  enforced.
- **DocC build check** — `swift package generate-documentation`
  must succeed without warnings.
- **Undocumented symbols** — fails on any `public` Swift symbol
  without a doc comment.

### 12.6 Versioning and stability commitments — published

A first-class section in both README (§12.1 #11) and DocC's
`Stability.md`:

- SemVer.
- Public API additions: minor.
- Public API removals or signature changes: major.
- **Minimum-iOS bumps: major.** A consumer on iOS 14 will never wake
  up to a minor version that won't compile.
- Wire-format-affecting changes: major, coordinated with backend.
- Deprecation policy: one full minor cycle (~3 months) of
  `@available(*, deprecated, ...)` warnings before any removal in the
  next major.
- Bug fixes that change observable behaviour are called out
  in `CHANGELOG.md` under a "Behaviour changes" sub-heading.

---

## 13. Testing strategy

### 13.1 Unit tests (`EdgeRumTests`)

- `SessionManagerTests` — expiry math, sequence increment, resume vs.
  new session, crash sidecar reads.
- `IdentityProviderTests` — ID format regex, Keychain round-trip,
  fallback to UserDefaults on Keychain failure.
- `AttributeBagTests` — type discipline.
- `BatchTransportTests` — happy path, 429 with Retry-After, 503
  backoff, 4xx drop, 5xx-as-503.
- `OfflineQueueTests` — FIFO eviction, corruption tolerance,
  drain on `.satisfied`.
- `SamplerTests` — per-session sampling, force-emit carve-outs.
- `RecorderTests` — eventName allowlist enforcement.
- **`SupportedIOSTests`** — assert key Foundation/UIKit APIs we
  depend on are callable on iOS 14 simulator slices.

### 13.2 Capture tests (`EdgeRumCaptureTests`)

- URLProtocol harness; UIViewController swizzle harness; tap capture
  via `UIWindow.sendEvent`; hang detector via fake runloop.
- Each test is parameterised over `availability` so the single
  iOS-15+ ProMotion path doesn't fail on iOS 14 simulator slices.

### 13.3 Crash tests

- `CrashSampleApp` (§12.3) UI test:
  1. Launch.
  2. Tap "Crash with SIGSEGV".
  3. Re-launch.
  4. Assert the next batch contains an `app.crash` with the previous
     session's identity.

### 13.4 Contract tests (`EdgeRumContractTests`)

`WireAssertions` helper as in CLAUDE.md, asserting:

- `envelope.type == "telemetry_batch"`
- `envelope.timestamp` matches `^\d{4}-\d{2}-\d{2}T`
- each `event.type ∈ {"event","metric"}`
- each `event.attributes["session.id"]` matches `^session_`
- each `event.attributes["device.id"]` matches `^device_`
- each `event.attributes["sdk.platform"] == "ios-native"`
- `JSON.stringify` contains none of `traceId`, `spanId`,
  `resourceSpans`, `opentelemetry`
- every attribute value is `String`, `Int`, `Double`, or `Bool`
- request header `X-API-Key` starts with `edge_`
- `Content-Type: application/json`

**Golden batch test**: generate one batch from fixed fixture (frozen
clock, identity, device); diff against
`Tests/Fixtures/golden-batch-ios.json`, which is reviewed against the
Android and web SDKs' equivalents.

### 13.5 Firewall check

`Tools/firewall-check.sh`:

1. `swift package dump-symbol-graph --target EdgeRum`
2. Grep for forbidden public symbols.
3. Grep doc comments via DocC build output.
4. Grep README and any `docs/` consumer-facing `.md` for forbidden
   vocabulary.

### 13.6 Doc tests — see §12.5.

### 13.7 Device matrix in CI

CI runs the test suite on three simulator slices:

- `platform=iOS Simulator,OS=14.5,name=iPhone SE (2nd generation)` — minimum-supported
- `platform=iOS Simulator,OS=16.4,name=iPhone 11` — mid
- `platform=iOS Simulator,OS=17.4,name=iPhone 15 Pro` — current

Performance tests run weekly on real hardware in a small lab (one
iPhone SE 2, one iPhone 11, one iPhone 15 Pro). Results posted to
`docs/perf/<date>.md`.

### 13.8 Performance test

- `XCTMetric.cpu`, `.memory`, `.applicationLaunch` in a sample app.
- Assert cold-start budget per device tier (§11.5).
- Assert 60 fps maintained while emitting 30 events/sec for 30s on
  modern hardware; 10 ev/s on iPhone SE 2 / 11.

---

## 14. Backend asks

1. **Accept `sdk.platform = "ios-native"` as a valid value.** Only
   new identity-attribute value in the iOS payload.

2. **Accept iOS dSYM symbolication** for `app.crash` events with
   `runtime = "native"`. Confirm the backend's symbolication pipeline
   handles `crash.report_json` containing the PLCR raw report.
   Confirm or define a `/symbols/upload` endpoint for dSYMs.

3. **Confirm absence of Web Vital metrics is fine.**

4. **Confirm SwiftUI does not require new eventNames.** We ship under
   `navigation` / `screen.duration` with `navigation.kind = "swiftui"`.

5. **Hang events under `app.crash` with `cause = "Hang"`.** Confirm
   crash dashboards do not double-count hangs as fatal crashes.

6. **`crash.report_json` size cap.** Please confirm a max single-event
   size. We'll truncate top-30 frames per thread by default.

7. **Tolerate `user.id` regeneration on user reinstall.**

8. **`User-Agent` header.** Acceptable for log triage purposes.

9. **`network.effectiveType`.** iOS cannot reliably emit the same web
   set. Confirm dashboards tolerate `"unknown"`.

10. **`device.batteryLevel = -1.0`** when battery monitoring is off
    (simulator). Forwarded as-is.

---

## 15. Risks and open questions

1. **`captureError` attribute type.** Web/Android accept `[String: Any]`;
   we tightened to `[String: AttributeValue]`. Confirm with parity team.

2. **`opentelemetry-swift-core` 2.x toolchain pin.** The dependency
   declares `swift-tools-version: 6.0`, so the package will only
   resolve under Xcode 16+. We pin at `from: "2.4.1"` until each new
   minor is validated against our XCFramework build pipeline. If
   the upstream ever raises its iOS floor above 14, hold the pin or
   invoke §5.3 (drop the dep for a hand-rolled minimal event model).

3. **`URLProtocol.registerClass(_:)`.** Configurations created before
   register may not see our protocol class. Delegate swizzle is the
   belt-and-braces path.

4. **Background URLSession in extensions.** Without shared keychain,
   extensions get a distinct `device.id`. Documented.

5. **Hang detection false positives on mid-tier hardware.** Older
   iPhone 8 / SE 2 can stall the main thread under heavy load.
   Clamp `hangTimeout` minimum at 2s; add `hang.cpu_usage`
   attribute to help filter.

6. **App Review for `mach_task_basic_info`.** Public API; no risk.

7. **iOS 14 single-gate `@available`.** The only remaining gate is
   `iOS 15+` for `CADisplayLink.preferredFrameRateRange` ProMotion
   observation (§6.10). Fallback documented; CI device matrix
   (§13.7) covers iOS 14.5, 16.4, and 17.4 to catch regressions.

8. **`X-API-Key` over plain HTTP.** Reject in `EdgeRumConfig`
    initializer in debug; warn in release.

9. **Snapshot golden batch drift.** Pin the model to `iPhone15,3`.

10. **`session.sequence` race.** Single writer (UserDefaults under
    `NSLock`). Background uploader runs in next process, not
    concurrently.

11. **MetricKit asynchrony.** `MXMetricPayload` arrives a day late;
    enriched events carry *current* session identity, not originating.
    Deliberate trade-off; flagged in §14.

12. **`Recorder` allowlist drift.** CI job scrapes the backend's
    dispatcher and diffs the list.

13. **Public SwiftUI modifier surface.** Reasonable but new vs. prompt
    sketch. Confirm.

14. **Documentation rot.** README and DocC drift from code over time.
    Mitigated by §12.5 doc-quality CI but not eliminated.
    Quarterly doc audit on the calendar.

---

## 16. Feature, task, and subtask breakdown

The work-breakdown view of the plan. A **Feature** is a capability
deliverable; a **Task** is a 1-3 day PR-shaped unit of work; a
**Subtask** is a concrete code/test/doc deliverable. Sections §1-15
are the architectural reference that supports the work here.

### 16.1 Conventions

**Status tags** (consistent with `docs/data-flow.md` § "Status conventions"):

| Tag      | Meaning                                                            |
|----------|--------------------------------------------------------------------|
| `v1.0`   | Ships in the first release.                                         |
| `v1.0+`  | Additive within v1.0 — pure context enrichment, no new event type. |
| `v1.1`   | Proposed for v1.1. Backend confirmation required before code lands. |
| `v1.2+`  | Proposed for v1.2+. Requires a new host-opt-in public API.          |
| `ongoing`| Cross-cutting work that spans every release.                        |

**Milestone alignment.** M0-M3 map onto v1.0 / v1.0+ scope. v1.1 and
v1.2+ are scoped after v1.0 ships. Documentation moves with the
feature it documents — never deferred.

**Acceptance.** Every task has a one-line acceptance criterion. Tasks
without testable acceptance are split until they do.

**Cross-refs.** Tasks reference the supporting architectural section
(`→ §6.3`) so the implementer reads the canonical surface before
writing code.

### 16.2 Milestone summary

| Milestone | Window  | Features                                            | Exit criterion                                       |
|-----------|---------|-----------------------------------------------------|------------------------------------------------------|
| M0 Boot   | wks 1-2 | F1, F2 (partial), F3 (partial), F4, F18 (skeleton), F19 (skeleton) | Empty envelope passes contract test on three iOS simulator slices |
| M1 Trans  | wks 3-4 | F3 (complete), F5, F2 (complete), F18 (quickstart), F20 (partial)  | `track`/`identify`/`time`/`captureError` paths + offline queue work end-to-end |
| M2 Capt   | wks 5-7 | F6, F7, F8, F9, F10 (frames/memory/long task), F11, F12, F16, F17  | All v1.0 + v1.0+ captures emit wire-valid data on golden batch |
| M3 Crash  | wks 8-10| F13, F14, F15, F19 (complete), F20 (complete), F18 (final), F1 (XCFramework) | Signed XCFramework + podspec + privacy manifest + green CI on device matrix |
| v1.1      | post v1 | F21, F22                                            | MetricKit + `memory_warning` + scene attribution shipping |
| v1.2+     | post v1 | F23                                                 | Host-opt-in events (`background_task`, `notification_interaction`) shipping |

### 16.3 Feature index

| #   | Feature                                          | Status   | Milestone | Modules                                       |
|-----|--------------------------------------------------|----------|-----------|-----------------------------------------------|
| F1  | Package & build infrastructure                   | v1.0     | M0 / M3   | `Package.swift`, `EdgeRum.podspec`, `Tools/`  |
| F2  | Public API surface                               | v1.0     | M0 / M1   | `Sources/EdgeRum/`                            |
| F3  | Core pipeline (Recorder, context, payload)       | v1.0     | M0 / M1   | `Sources/EdgeRumCore/`                        |
| F4  | Identity & session management                    | v1.0     | M0 / M1   | `Sources/EdgeRumCore/`                        |
| F5  | Batch transport, retry, offline, background      | v1.0     | M1        | `Sources/EdgeRumCore/Transport/`              |
| F6  | UIKit screen capture                             | v1.0     | M2        | `Sources/EdgeRumCapture/UIViewControllerCapture.swift` |
| F7  | SwiftUI screen capture                           | v1.0     | M2        | `Sources/EdgeRum/SwiftUI/`                    |
| F8  | HTTP capture + `URLSessionTaskMetrics`           | v1.0     | M2        | `Sources/EdgeRumCapture/HTTPCapture.swift`    |
| F9  | Interaction capture                              | v1.0     | M2        | `Sources/EdgeRumCapture/InteractionCapture.swift` |
| F10 | Performance samplers (frame, memory, long task)  | v1.0     | M2        | `Sources/EdgeRumCapture/`                     |
| F11 | Lifecycle & connectivity                         | v1.0     | M2        | `Sources/EdgeRumCapture/`                     |
| F12 | Page-load timing                                 | v1.0     | M2        | `Sources/EdgeRumCapture/PageLoadCapture.swift`|
| F13 | Error capture (`captureError`)                   | v1.0     | M1 / M3   | `Sources/EdgeRum/EdgeRum.swift`               |
| F14 | Native crash capture (PLCrashReporter + replay)  | v1.0     | M3        | `Sources/EdgeRumCrash/`                       |
| F15 | Hang detection                                   | v1.0     | M3        | `Sources/EdgeRumCrash/HangDetector.swift`     |
| F16 | Context bag enrichment (thermal, a11y, NW extras)| v1.0+    | M2        | `Sources/EdgeRumCore/Context/`                |
| F17 | URLSession metrics enrichment (TLS, redirects)   | v1.0+    | M2        | `Sources/EdgeRumCapture/HTTPCapture.swift`    |
| F18 | Documentation (README, DocC, samples)            | ongoing  | M0-M3     | `README.md`, `Sources/EdgeRum/EdgeRum.docc/`, `Samples/` |
| F19 | Testing & CI                                     | ongoing  | M0-M3     | `Tests/`, `.github/workflows/`                |
| F20 | Privacy & App Store readiness                    | v1.0     | M0 / M3   | `PrivacyInfo.xcprivacy`, `Tools/verify-privacy-manifest.sh` |
| F21 | MetricKit subscriber                             | v1.1     | post v1   | `Sources/EdgeRumCapture/MetricKitSubscriber.swift` |
| F22 | Lifecycle extensions (memory warning, scenes)    | v1.1     | post v1   | `Sources/EdgeRumCapture/LifecycleCapture.swift` |
| F23 | Host-opt-in events (BGTask, notifications)       | v1.2+    | post v1   | `Sources/EdgeRum/EdgeRum.swift`               |

### 16.4 Features in detail

---

#### F1 — Package & build infrastructure

**Goal.** SwiftPM, CocoaPods, and XCFramework distribution with the
iOS 14 floor and Swift-6 toolchain. **Status.** `v1.0`. **Refs.**
§2.3, §2.4, §2.5.

##### T1.1 — Initialize `Package.swift` `[M0]`
- Declare products: `EdgeRum`, `EdgeRumStatic`.
- Declare internal targets: `EdgeRumCore`, `EdgeRumCapture`,
  `EdgeRumCrash`, `EdgeRumOTelBridge`.
- Pin `opentelemetry-swift-core` at `from: "2.4.1"`.
- Add `.binaryTarget` for `CrashReporter.xcframework`.
- `platforms: [.iOS(.v14)]`, `swift-tools-version: 6.0`.

**Acceptance.** `swift build -c release` succeeds for `iphoneos` and `iphonesimulator`.

##### T1.2 — XCFramework build script `[M3]`
- `Tools/build-xcframework.sh` runs `xcodebuild archive` + `-create-xcframework`.
- Slices: `iphoneos`, `iphonesimulator` (arm64 + x86_64), `maccatalyst`.
- Bundle `PrivacyInfo.xcprivacy` into every slice.
- `codesign --options=runtime` with CI-stored Developer ID.

**Acceptance.** Local invocation produces a signed `.xcframework.zip` ≤ 1.6 MB.

##### T1.3 — Generated version file `[M0]`
- `Tools/gen-version.sh` writes `Sources/EdgeRum/Generated/EdgeRumVersion.swift`.
- Reads SemVer from a `VERSION` file at repo root.
- Wired through SwiftPM build plugin so it runs before compile.

**Acceptance.** Runtime `sdk.version` attribute matches `VERSION` file at build time.

##### T1.4 — CocoaPods podspec `[M3]`
- `EdgeRum.podspec` mirrors SwiftPM targets as private subspecs.
- Vendors `CrashReporter.xcframework`.
- Depends on `OpenTelemetry-Swift-Api`, `OpenTelemetry-Swift-Sdk` (core-only).
- `s.ios.deployment_target = '14.0'`, `s.swift_versions = ['5.10', '6.0']`.
- Privacy manifest declared via `s.resource_bundles`.

**Acceptance.** `pod lib lint EdgeRum.podspec` is clean on macOS CI.

##### T1.5 — Supported-iOS audit script `[M0]`
- `Tools/check-supported-ios.sh` diffs README "Supported iOS" table
  against `Package.swift` platforms and §2.2.
- Wired into PR CI.

**Acceptance.** A README/Package.swift mismatch fails CI; fixing it passes.

---

#### F2 — Public API surface

**Goal.** Product-vocabulary Swift API with zero OTel leak.
**Status.** `v1.0`. **Refs.** §3.

##### T2.1 — `EdgeRum` namespace enum `[M0 → M1]`
- Caseless `public enum EdgeRum` with static methods (§3.2).
- Route every call to internal `Recorder` via a stored singleton.
- `start(_:)` idempotent (same config → no-op; different → warn-and-ignore).

**Acceptance.** `swift package dump-symbol-graph` lists only the methods in §3.2.

##### T2.2 — `EdgeRumConfig` struct `[M0]`
- All fields per §3.2 with documented defaults.
- `init(apiKey:endpoint:)` validates `apiKey` prefix `"edge_"` and `https://` scheme.
- `precondition` on misuse so it fails in release too.

**Acceptance.** Building with `apiKey: "abc"` precondition-fails on `start()`.

##### T2.3 — `AttributeValue` sealed enum `[M0]`
- Cases `.string` / `.int` / `.double` / `.bool`.
- Conform to `ExpressibleBy{String,Integer,Float,Boolean}Literal`.
- `Sendable`, `Hashable`.

**Acceptance.** Passing any other type to `track(attributes:)` is a compile error.

##### T2.4 — `UserContext` and `Environment` `[M1]`
- Implement per §3.2; `Sendable`, `Hashable`.

**Acceptance.** Round-trips through `EdgeRum.identify(_:)` unchanged.

##### T2.5 — `RumTimer` class `[M1]`
- `end(attributes:)` emits one metric; idempotent.
- `cancel()` discards; idempotent.
- Start moment from injectable `Clock`.

**Acceptance.** Second `end()` call is a no-op — no second metric emitted.

##### T2.6 — SwiftUI view modifiers `[M2]`
- `.edgeRumScreen(_:attributes:)` via `.onAppear` / `.onDisappear`.
- `.edgeRumTrackTap(_:attributes:)` via overlay tap recognizer.
- Unconditional at iOS 14 floor.

**Acceptance.** Modifier emits `navigation` with `navigation.kind = "swiftui"`.

##### T2.7 — Firewall check script `[M0, ongoing]`
- `Tools/firewall-check.sh` greps `swift package dump-symbol-graph` for banned terms (§3.1).
- Greps DocC build output for banned terms in `///` comments.
- Greps `README.md` and consumer-facing `docs/*.md`.

**Acceptance.** Adding `Span` to any public doc comment fails CI.

---

#### F3 — Core pipeline

**Goal.** Single `Recorder` fan-in, context merging, payload build,
type-safe attributes. **Status.** `v1.0`. **Refs.** §4.2, §7.

##### T3.1 — `Recorder` façade `[M0]`
- `recordEvent` / `recordMetric` / `flush` / `shutdown`.
- Serial queue `edge.rum.recorder` (QoS `.utility`).
- Static `allowedEventNames` set; reject unknowns (log when `debug`).

**Acceptance.** Recording `eventName = "foo"` is dropped and logged in debug.

##### T3.2 — `EventEnvelope` + `AttributeBag` `[M0]`
- `EventEnvelope` wraps `[Event]` with batch metadata (§7.2).
- `AttributeBag` holds `[String: AttributeValue]`.
- `merging(_:)` — event attrs win on conflict.
- `JSONEncoder` extension encodes each `AttributeValue` to raw JSON.

**Acceptance.** `JSONSerialization.jsonObject(with: encoded)` round-trips lossless.

##### T3.3 — `ContextProvider` `[M0 → M1]`
- Snapshots `AppContext`, `DeviceContext`, `NetworkContext`,
  `SessionContext`, `UserContext`, `SdkContext`.
- Refreshes on `start()`, `identify()`, `NWPath` transition, session rotation, battery notification.

**Acceptance.** Snapshot taken at `start()` matches direct `Bundle.main` / `UIDevice` reads.

##### T3.4 — `Sampler` + `Clock` `[M1]`
- `Sampler` is per-session uniform random vs `config.sampleRate` (§9.6).
- Forced-emit allowlist: `session.started`, `session.finalized`, `app.crash`, `network_change`.
- `Clock` protocol; `SystemClock` for prod, `FixedClock` for tests.

**Acceptance.** `sampleRate = 0` still emits the forced-emit set.

##### T3.5 — `PayloadBuilder` `[M1]`
- Builds the `telemetry_batch` envelope (§7.2).
- Stamps batch timestamp at build time, not enqueue time.
- ISO 8601 with fractional seconds (manual encoding, not `.iso8601` strategy).

**Acceptance.** Output passes `WireAssertions.assertValidEnvelope`.

---

#### F4 — Identity & session management

**Goal.** Device, user, and session IDs in the exact wire format, with
crash sidecar for next-launch replay. **Status.** `v1.0`. **Refs.** §8.

##### T4.1 — ID format generator + regex `[M0]`
- Helper that produces `device_<epochMs>_<16 hex>_ios` etc. using `SecRandomCopyBytes(8)`.
- Round-trip regex validates persisted IDs on load; regenerate on mismatch.

**Acceptance.** `XCTAssertMatches(id, "^device_\\d+_[0-9a-f]{16}_ios$")` holds across 10k generated samples.

##### T4.2 — `IdentityProvider` (Keychain + UserDefaults) `[M0]`
- `device.id` in Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
- `user.id` in UserDefaults suite `com.edge.rum.session`.
- Fallback path: if Keychain write fails, log and fall back to UserDefaults.

**Acceptance.** Reinstalling the host app on the simulator regenerates `device.id`.

##### T4.3 — `SessionManager` lifecycle `[M0 → M1]`
- Start a session on `start()` if none active or last-active > 30 min ago.
- Update last-active on every `Recorder.recordEvent` and `didBecomeActive`.
- Increment `session.sequence` on transport ack (under `NSLock`).
- Emit `session.started` on rotation; `session.finalized` on `willResignActive`.

**Acceptance.** Three consecutive ACKed batches yield `session.sequence = 3`.

##### T4.4 — Crash sidecar `[M3]`
- `Library/Caches/edge-rum/last-session.json` mirrors current identity on every event.
- Read on next launch when a crash report is pending — emit replay event with the **previous** session's identity.

**Acceptance.** Crash sample app (§13.3) test: replayed `app.crash` carries the crashing session's `session.id`, not the current one.

---

#### F5 — Batch transport, retry, offline queue, background uploader

**Goal.** Survive offline, retry with backoff, drain on reconnect,
flush on background. **Status.** `v1.0`. **Refs.** §9.

##### T5.1 — `BatchTransport` happy-path POST `[M0 → M1]`
- `URLSessionConfiguration.default` session created before swizzles install.
- Headers per §7.1; `taskDescription = "edge-rum-internal"`.
- Triggers per §9.1.

**Acceptance.** Posting a 30-event batch produces a 200 and a single ACK.

##### T5.2 — `RetryPolicy` `[M1]`
- Schedule 0 / 2 / 8 / 30 s for status 0 / 429 / 503.
- Respect `Retry-After` capped at 60 s.
- 5xx other than 503 → treat as 503.
- Non-retryable 4xx → drop batch, log in debug.

**Acceptance.** Mock server returning 503 yields four attempts then offline-queue.

##### T5.3 — `OfflineQueue` (file-backed) `[M1]`
- Files under `Library/Caches/edge-rum/queue/<epochMs>-<seq>.json`.
- `maxQueueSize` cap; FIFO drop on overflow.
- Sequential drain on `.satisfied` / `didBecomeActive` / `enable()`.

**Acceptance.** Filling the queue past `maxQueueSize` drops the oldest file first.

##### T5.4 — `BackgroundUploader` `[M1]`
- `URLSessionConfiguration.background(withIdentifier: "com.edge.rum.upload")`.
- Public `EdgeRum.handleBackgroundEvents(identifier:completion:)` wired into the uploader's completion.

**Acceptance.** Suspending the app mid-upload and re-launching completes the upload.

##### T5.5 — Per-session sampling `[M1]`
- Uniform random at session start vs `sampleRate` (§9.6).
- Excluded sessions emit only forced-emit allowlist.

**Acceptance.** `sampleRate = 0.5` over 10k synthetic sessions yields 5000 ± 200 sampled.

---

#### F6 — UIKit screen capture

**Goal.** Auto-emit `navigation` + `screen.duration` for every UIKit
screen entry / exit. **Status.** `v1.0`. **Refs.** §6.1.

##### T6.1 — `viewDidAppear` / `viewWillDisappear` swizzle install `[M2]`
- Once-token in `EdgeRum.start()`, main thread.
- Swizzle base `UIViewController`; never a subclass.

**Acceptance.** Swizzling does not break vanilla `UIViewController` subclasses (smoke test app boots).

##### T6.2 — Screen name resolution `[M2]`
- Prefer `accessibilityIdentifier`, fall back to `String(reflecting:)`.
- Skip container controllers (`UINavigationController`, `UITabBarController`, `UIPageViewController`).

**Acceptance.** Pushing two VCs emits two `navigation` events with the right `navigation.previous_screen` chaining.

##### T6.3 — Screen-duration metric `[M2]`
- Pair `viewDidAppear` / `viewWillDisappear`, emit `screen.duration` with `screen.duration_ms`.

**Acceptance.** Holding a screen 4.3 s emits `screen.duration_ms ≈ 4300` (±50 ms).

##### T6.4 — `UIHostingController` detection `[M2]`
- Recognise hosting controllers in the swizzle; emit with `navigation.kind = "swiftui"`.

**Acceptance.** Presenting a SwiftUI view via `UIHostingController` emits `navigation.kind = "swiftui"`.

---

#### F7 — SwiftUI screen capture

**Goal.** Public `.edgeRumScreen` / `.edgeRumTrackTap` modifiers
emitting allowlisted events. **Status.** `v1.0`. **Refs.** §6.2.

##### T7.1 — `.edgeRumScreen` modifier `[M2]`
- `.onAppear` → emit `navigation` with `navigation.kind = "swiftui"`.
- `.onDisappear` → emit `screen.duration`.

**Acceptance.** Modifier on a SwiftUI view emits both events with consistent screen name.

##### T7.2 — `.edgeRumTrackTap` modifier `[M2]`
- Overlay tap recognizer; emit `user.interaction` with `interaction.kind = "tap"`.

**Acceptance.** Tapping the modified view fires exactly one `user.interaction` event.

##### T7.3 — Sample SwiftUI app `[M2]`
- `Samples/EdgeRumSwiftUISampleApp/` exercising both modifiers.

**Acceptance.** App builds and runs on iOS 14 simulator.

---

#### F8 — HTTP capture

**Goal.** Auto-emit `http.request` and `resource_timing` for every
`URLSession` request that isn't ours. **Status.** `v1.0`. **Refs.** §6.3.

##### T8.1 — `URLProtocol` subclass + registration `[M2]`
- Register globally from `start()`; observe `default` / `ephemeral` sessions.

**Acceptance.** A `URLSession.shared.dataTask(with:)` produces one `http.request` event.

##### T8.2 — `URLSessionConfiguration` swizzle fallback `[M2]`
- Inject delegate proxy on configurations created after `URLProtocol` registration is too late.

**Acceptance.** A `URLSession(configuration: .default, delegate: customDelegate, ...)` still produces `http.request`.

##### T8.3 — `URLSessionTaskMetrics` → `resource_timing` `[M2]`
- Collect transaction metrics; emit metric with `resource.dns_ms` etc.

**Acceptance.** A real cold request to `https://example.com` produces non-zero `resource.dns_ms`.

##### T8.4 — Internal-request filter `[M2]`
- Three checks: `taskDescription`, `X-Edge-Rum-Internal: 1` header, host prefix.

**Acceptance.** SDK transport POSTs do not appear as `http.request` events.

##### T8.5 — `ignoreUrls` + `sanitizeUrl` `[M2]`
- Regex match `ignoreUrls` before record; drop on match.
- Run `sanitizeUrl` synchronously on URL before record (also on `resource_timing.url`).

**Acceptance.** Token-bearing URL is recorded with the token replaced per `sanitizeUrl`.

---

#### F9 — Interaction capture

**Goal.** Auto-emit `user.interaction` for taps on `UIControl` / cell
targets. **Status.** `v1.0`. **Refs.** §6.5.

##### T9.1 — `UIWindow.sendEvent` swizzle `[M2]`
- Inspect `UIEvent.allTouches`; resolve to `UIControl` or cell.
- Emit with `interaction.kind = "tap"`, `interaction.target = class name`, `interaction.accessibility_id`.

**Acceptance.** Tapping a button with `accessibilityIdentifier = "checkout"` emits `interaction.accessibility_id = "checkout"`.

##### T9.2 — Secure text field exclusion `[M2]`
- Skip any view whose responder chain reaches an `isSecureTextEntry == true` field.
- Never read `text` values.

**Acceptance.** Tapping a `UITextField` with `isSecureTextEntry = true` emits no `user.interaction`.

---

#### F10 — Performance samplers

**Goal.** `frame_render_time`, `memory_usage`, `long_task` metrics on
a steady cadence. **Status.** `v1.0`. **Refs.** §6.10, §6.11, §6.12.

##### T10.1 — `FrameSampler` (`CADisplayLink`) `[M2]`
- iOS 14 path: `preferredFramesPerSecond`.
- iOS 15+ path: `preferredFrameRateRange` for ProMotion (gated by `@available`).
- Batch per-second windows; emit `frame_render_time` with `frame.target_hz`.

**Acceptance.** On iOS 15+ simulator with ProMotion model, `frame.target_hz = 120`; on iOS 14, `60`.

##### T10.2 — `MemorySampler` `[M2]`
- Poll `mach_task_basic_info` every 10 s + listen on `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE`.
- Emit `memory_usage` with `memory.resident_mb`, `memory.virtual_mb`, `memory.pressure`.

**Acceptance.** Triggering a synthetic memory-pressure event emits `memory.pressure = "warn"`.

##### T10.3 — `RunLoopObserverCapture` (long task) `[M2]`
- `CFRunLoopObserver` measures `kCFRunLoopBeforeWaiting` → `kCFRunLoopAfterWaiting`.
- Threshold 50 ms emits `long_task` metric.

**Acceptance.** `Thread.sleep(forTimeInterval: 0.2)` on main thread emits `long_task` with `value > 200`.

---

#### F11 — Lifecycle & connectivity

**Goal.** `app_lifecycle`, `network_change`, `session.started`,
`session.finalized` events. **Status.** `v1.0`. **Refs.** §6.18, §6.19.

##### T11.1 — `LifecycleCapture` `[M2]`
- Subscribe to `UIApplication.willResignActive` / `didEnterBackground` / `willEnterForeground` / `didBecomeActive`.
- Emit `app_lifecycle` with `lifecycle.state` and `lifecycle.previous_state`.
- On `willResignActive`: trigger immediate flush + `session.finalized`.

**Acceptance.** Backgrounding the sample app flushes the buffer before suspension.

##### T11.2 — `NetworkPathCapture` `[M2]`
- `NWPathMonitor` listener; emit `network_change` on each transition.
- Refresh `ContextProvider.networkContext` so subsequent events carry the new `network.type`.
- `.satisfied` transitions nudge `OfflineQueue.drain()`.

**Acceptance.** Toggling simulator's "Network Link Conditioner" emits `network_change`.

---

#### F12 — Page-load timing

**Goal.** Single `page_load` event per process from launch to first
frame. **Status.** `v1.0`. **Refs.** §6.4.

##### T12.1 — Cold-start window `[M2]`
- Start timing at `UIApplication.didFinishLaunchingNotification`.
- Close on first `CADisplayLink` callback while `applicationState == .active`.
- Emit `page_load` with `page_load.cold_start = true`, `page_load.source = "displaylink"`.

**Acceptance.** A cold sample-app launch produces exactly one `page_load` event with `page_load.duration_ms > 0`.

##### T12.2 — Prewarm detection `[M2]`
- Read `ProcessInfo.processInfo.environment["ActivePrewarm"]` (iOS 15+).
- Set `page_load.cold_start = false`, `page_load.prewarmed = true` when applicable.

**Acceptance.** On iOS 15+ simulator with prewarm env var set, the event reports `prewarmed = true`.

---

#### F13 — Error capture (`captureError`)

**Goal.** `EdgeRum.captureError` funnels into `app.crash` with
`cause = "AppError"`. **Status.** `v1.0`. **Refs.** §6.6.

##### T13.1 — `EdgeRum.captureError(_:context:)` `[M1]`
- Accept `Error` (Swift / NSError) and `[String: AttributeValue]?`.
- Capture stack at call site (`Thread.callStackSymbols`).
- Flatten `context` with `crash.context.` prefix.

**Acceptance.** `captureError(DecodingError.keyNotFound(...))` emits `app.crash` with `crash.cause = "AppError"`.

##### T13.2 — `NSError` flattening `[M1]`
- Encode `domain`, `code`, `userInfo` flatly (drop non-primitive userInfo values, log in debug).

**Acceptance.** `NSError(domain: "x", code: 1, userInfo: ["k": "v"])` emits `error.userInfo.k = "v"`.

---

#### F14 — Native crash capture

**Goal.** PLCrashReporter integration with replay-on-next-launch and
crash sidecar. **Status.** `v1.0`. **Refs.** §6.7, §8.4.

##### T14.1 — PLCrashReporter integration `[M3]`
- Initialize in `start()` if `captureNativeCrashes == true`.
- BSD signal handler + Mach exception handling enabled.

**Acceptance.** Triggering `raise(SIGSEGV)` in the crash sample app produces a PLCR report on disk.

##### T14.2 — Crash sidecar writer `[M3]`
- Wire `Recorder.recordEvent` to mirror identity + current screen into `Library/Caches/edge-rum/last-session.json`.

**Acceptance.** After every event, sidecar JSON contains current `session.id`.

##### T14.3 — Replay path `[M3]`
- On `start()`, call `PLCrashIntegration.replayIfNeeded()` before sampler install.
- Read PLCR report + sidecar; build `app.crash` with previous-session identity; flush immediately; delete report.

**Acceptance.** Crash → relaunch → first batch contains `app.crash` with `crash.fatal = true` carrying the crashed session's `session.id`.

##### T14.4 — Stack truncation `[M3]`
- Truncate to top-30 frames per thread by default.
- Stringify the rest into `crash.thread.other_stacks` with `…N more…` marker.

**Acceptance.** Crash with 200-frame stack emits an `app.crash` ≤ size cap negotiated with backend.

---

#### F15 — Hang detection

**Goal.** Main-thread watchdog emitting `app.crash` with `cause = "Hang"`.
**Status.** `v1.0`. **Refs.** §6.8.

##### T15.1 — `HangDetector` runloop watchdog `[M3]`
- Dedicated `Thread` (`.userInitiated`) sampling main-runloop heartbeat.
- Threshold `hangTimeout` (default 5 s, clamped min 2 s).

**Acceptance.** Synthetic 6 s main-thread block emits one `app.crash` with `crash.cause = "Hang"`.

##### T15.2 — Best-effort stack snapshot `[M3]`
- Capture main-thread stack at the moment of detection.
- Public-API only — no `_pthread_*` private calls.

**Acceptance.** Hang event carries a non-empty `crash.thread.main_stack`.

---

#### F16 — Context bag enrichment (`v1.0+`)

**Goal.** Sixteen additional context attributes per `docs/data-flow.md`
§ 3. **Status.** `v1.0+`. **Refs.** `docs/data-flow.md` § 3.

##### T16.1 — `PowerContext` (thermal + Low Power Mode) `[M2]`
- New `Sources/EdgeRumCore/Context/PowerContext.swift`.
- Subscribe to `thermalStateDidChangeNotification` + `NSProcessInfoPowerStateDidChange`.
- Emit `device.thermal_state`, `device.low_power_mode`.

**Acceptance.** Toggling Low Power Mode in simulator flips `device.low_power_mode` on the next event.

##### T16.2 — Accessibility attributes `[M2]`
- Subscribe to all `UIAccessibility.*DidChangeNotification`.
- Emit `device.dynamic_type`, `device.reduce_motion`, `device.bold_text`, `device.voiceover`, `device.increase_contrast`.

**Acceptance.** Toggling VoiceOver in simulator flips `device.voiceover` on the next event.

##### T16.3 — `NetworkContext` extras `[M2]`
- Add `network.expensive`, `network.constrained`, `network.interface`.

**Acceptance.** Connecting via personal hotspot in real-device test emits `network.expensive = true`.

##### T16.4 — `StorageContext` `[M2]`
- New `Sources/EdgeRumCore/Context/StorageContext.swift`.
- Refresh at session start + every 5 min.
- Emit `device.disk_free_mb`, `device.disk_total_mb`, `app.background_refresh`.

**Acceptance.** Free disk value matches `df -k` ±5%.

##### T16.5 — Locale & timezone `[M2]`
- Emit `device.locale`, `device.timezone`, `device.timezone_offset_min`.

**Acceptance.** Changing simulator region produces a matching `device.locale` on next event.

---

#### F17 — URLSession metrics enrichment (`v1.0+`)

**Goal.** Eight additional `http.request` + three `resource_timing`
attributes from `URLSessionTaskMetrics`. **Status.** `v1.0+`.
**Refs.** `docs/data-flow.md` § 3.3.

##### T17.1 — TLS / connection details on `http.request` `[M2]`
- Add `http.redirect_count`, `http.tls_protocol`, `http.tls_cipher`,
  `http.reused_connection`, `http.proxy_connection`, `http.network_protocol`,
  `http.request_body_bytes_before_encoding`.

**Acceptance.** A 1.3 TLS request emits `http.tls_protocol = "1.3"`.

##### T17.2 — `http.cellular_fallback` (iOS 17+) `[M2]`
- `@available(iOS 17, *)` block reads multipath flag.
- Omitted on earlier iOS.

**Acceptance.** Attribute present only on iOS 17+ runs.

##### T17.3 — Multi-transaction `resource_timing` `[M2]`
- Iterate `transactionMetrics`; populate `resource.redirect_count`,
  `resource.transaction_count`, `resource.fetch_start_to_response_end_ms`.

**Acceptance.** A request with one redirect emits `resource.transaction_count = 2`.

---

#### F18 — Documentation

**Goal.** README, DocC, sample apps, migration template, doc CI per §12.
**Status.** `ongoing`. **Refs.** §12.

##### T18.1 — README skeleton `[M0]`
- TL;DR, supported-iOS table, install (all three channels), quickstart placeholder.

**Acceptance.** `Tools/check-supported-ios.sh` passes on first commit.

##### T18.2 — Quickstart finalized `[M1]`
- UIKit AppDelegate, SceneDelegate, SwiftUI App tabs (§12.1 #5).
- Compile-tested by `Tools/extract-readme-code.sh`.

**Acceptance.** Every fenced Swift block in README compiles against the package.

##### T18.3 — DocC catalog `[M2]`
- `Sources/EdgeRum/EdgeRum.docc/{EdgeRum,GettingStarted,Configuration,Captures,Privacy,Stability}.md`.
- Recipes per §12.2.

**Acceptance.** `swift package generate-documentation` succeeds without warnings.

##### T18.4 — Sample apps `[M1 → M3]`
- `EdgeRumSampleApp` (M1), `EdgeRumSwiftUISampleApp` (M2), `EdgeRumCrashSampleApp` (M3).

**Acceptance.** All three build in CI on every PR.

##### T18.5 — Migration template + CHANGELOG `[M0 / M3]`
- `docs/migration/TEMPLATE.md` checked in at M0.
- `CHANGELOG.md` v1.0.0 entry at M3.

**Acceptance.** Template present in M0; CHANGELOG entry present in M3 release tag.

##### T18.6 — Doc-quality CI `[M2 → M3]`
- `Tools/extract-readme-code.sh`, `Tools/check-links.sh`,
  `Tools/check-supported-ios.sh`, DocC build, undocumented-symbol check.

**Acceptance.** Removing a `///` from any public symbol fails CI.

---

#### F19 — Testing & CI

**Goal.** Unit, capture, contract, golden batch, firewall, device-matrix,
and performance tests. **Status.** `ongoing`. **Refs.** §13.

##### T19.1 — `EdgeRumTests` (unit) `[M0 → M3]`
- `SessionManagerTests`, `IdentityProviderTests`, `AttributeBagTests`,
  `BatchTransportTests`, `OfflineQueueTests`, `SamplerTests`,
  `RecorderTests`, `SupportedIOSTests` (§13.1).

**Acceptance.** ≥ 80% line coverage on `EdgeRumCore`.

##### T19.2 — `EdgeRumCaptureTests` `[M2]`
- URLProtocol harness, UIViewController swizzle harness, tap harness, hang fake-runloop.

**Acceptance.** All capture paths produce expected attributes on a fixture.

##### T19.3 — `EdgeRumContractTests` `[M0 → M2]`
- `WireAssertions` (§13.4) on every fixture batch.

**Acceptance.** Forbidden tokens (`traceId`, `spanId`, `opentelemetry`) never appear in any emitted byte.

##### T19.4 — Golden-batch fixture `[M2]`
- `Tests/Fixtures/golden-batch-ios.json`.
- Frozen `Clock`, frozen `IdentityProvider`, frozen `DeviceContext`.

**Acceptance.** Snapshot test matches byte-for-byte across runs.

##### T19.5 — Crash UI test `[M3]`
- Launch → tap "SIGSEGV" → relaunch → assert replay event identity.

**Acceptance.** Crash UI test green on three simulator slices.

##### T19.6 — Device matrix CI `[M0, ongoing]`
- iPhone SE (2nd gen) / iOS 14.5, iPhone 11 / iOS 16.4, iPhone 15 Pro / iOS 17.4.

**Acceptance.** All slices green on every PR.

##### T19.7 — Performance budget tests `[M3]`
- `XCTMetric.cpu` / `.memory` / `.applicationLaunch` per §11.

**Acceptance.** Cold-start ≤ tiered budget; 30 ev/s sustains ≤ 2% CPU on modern tier.

---

#### F20 — Privacy & App Store readiness

**Goal.** `PrivacyInfo.xcprivacy`, restricted-reason API audit, opt-out
flags, URL sanitization, secure-text exclusion. **Status.** `v1.0`.
**Refs.** §10.

##### T20.1 — `PrivacyInfo.xcprivacy` manifest `[M0 / M3]`
- All restricted-reason APIs declared with reason codes (§10.4).
- Data types and tracking declarations per §10.4.

**Acceptance.** `Tools/verify-privacy-manifest.sh` matches code usage to declaration.

##### T20.2 — Opt-out flag wiring `[M2]`
- `config.captureScreens`, `captureHTTP`, `captureTaps`, `captureRenderingPerformance` short-circuit swizzle install (§10.5).

**Acceptance.** Setting any flag to `false` prevents the corresponding events from being recorded.

##### T20.3 — `disable()` / `enable()` `[M1]`
- Stop emission + flush timer; queue stays on disk.
- State persists across launches in UserDefaults.

**Acceptance.** Disabling, recording, then re-enabling produces no new events for the disabled window.

##### T20.4 — IP geolocation (opt-in) `[M1]`
- `resolveLocation = true` → one-shot GET to `locationProviderUrl`; cache 24 h.
- Tag with `X-Edge-Rum-Internal: 1`.

**Acceptance.** With flag on, location is set on the next batch envelope.

##### T20.5 — Privacy verifier script `[M3]`
- `Tools/verify-privacy-manifest.sh` greps code for restricted-reason calls and diffs against the manifest.

**Acceptance.** Adding a `stat()` call without updating the manifest fails CI.

---

#### F21 — MetricKit subscriber (`v1.1`)

**Goal.** Subscribe to MetricKit payloads and route into the existing
event/metric pipeline. **Status.** `v1.1`. **Refs.**
`docs/data-flow.md` § 6.

##### T21.1 — `MetricKitSubscriber` skeleton `[v1.1]`
- Implement `MXMetricManagerSubscriber`; subscribe once from `start()`.
- Route `[MXMetricPayload]` and `[MXDiagnosticPayload]` to dispatchers.

**Acceptance.** Synthetic payload delivered via MetricKit's testing harness reaches `Recorder`.

##### T21.2 — Crash / hang routing → existing `app.crash` `[v1.1]`
- `MXCrashDiagnostic` and `MXHangDiagnostic` → `app.crash` with
  `crash.source = "metrickit"` and new MetricKit-specific attributes
  (`crash.virtual_memory_region_info`, `crash.metrickit_payload_id`).
- Dedup keyed on `crash.metrickit_payload_id` (backend ask § 16.5).

**Acceptance.** MetricKit-delivered crash emits an `app.crash` with `crash.source = "metrickit"`.

##### T21.3 — Launch metric augmentation → existing `page_load` `[v1.1]`
- `MXAppLaunchMetric` → `page_load` with `page_load.source = "metrickit"`,
  including `page_load.prewarmed`, `first_draw_avg_ms`, `resume_avg_ms`,
  `optimized_avg_ms` (iOS 16+), `sample_count`.

**Acceptance.** Next-launch MetricKit delivery emits a second `page_load` with `page_load.source = "metrickit"`.

##### T21.4 — New metric `scroll_hitch_ratio` `[v1.1]`
- Route `MXAnimationMetric.scrollHitchTimeRatio` to a metric.
- Add `scroll_hitch_ratio` to `Recorder.allowedMetricNames`.

**Acceptance.** Backend confirms ingestion; metric flows in staging.

##### T21.5 — New metric `system_exception` `[v1.1]`
- Fold `MXCPUExceptionDiagnostic` + `MXDiskWriteExceptionDiagnostic` under one metric with `exception.kind` discriminator.

**Acceptance.** Backend confirms ingestion; both kinds route correctly.

##### T21.6 — New metric `energy_impact` `[v1.1]`
- Route `MXEnergyMetric` to a metric with foreground / background breakdown.

**Acceptance.** Backend confirms ingestion; values are non-zero on a real-device test run.

---

#### F22 — Lifecycle extensions (`v1.1`)

**Goal.** `memory_warning` event + scene attribution on `app_lifecycle`.
**Status.** `v1.1`. **Refs.** `docs/data-flow.md` § 5a, § 4.3.

##### T22.1 — `memory_warning` event `[v1.1]`
- Subscribe to `applicationDidReceiveMemoryWarning`.
- Emit `memory_warning` with `memory.resident_mb`, `memory.pressure`, `memory.screen`.
- Add to `Recorder.allowedEventNames`.

**Acceptance.** Simulator's "Simulate Memory Warning" menu item produces one event.

##### T22.2 — Scene attribution on `app_lifecycle` `[v1.1]`
- Subscribe to `UIScene` lifecycle.
- Add `lifecycle.scene_id`, `lifecycle.scene_count`, `lifecycle.scene_role` attributes.

**Acceptance.** On iPad multi-window, two open windows emit `lifecycle.scene_count = 2`.

---

#### F23 — Host-opt-in events (`v1.2+`)

**Goal.** `background_task` and `notification_interaction` via new
opt-in public APIs. **Status.** `v1.2+`. **Refs.**
`docs/data-flow.md` § 7.

##### T23.1 — `EdgeRum.observeBackgroundTask(_:)` `[v1.2+]`
- Public API that takes a `BGTask` reference; observes expiration and completion.
- Emit `background_task` with `bgtask.identifier`, `bgtask.kind`, `bgtask.outcome`, `bgtask.duration_ms`.
- Add to `Recorder.allowedEventNames`.

**Acceptance.** Sample app's `BGAppRefreshTask` handler produces one `background_task` per run.

##### T23.2 — `EdgeRum.handleNotificationResponse(_:)` `[v1.2+]`
- Public API for hosts to forward `UNNotificationResponse` from their delegate.
- Emit `notification_interaction` with `notification.id`, `notification.action`, `notification.category`, `notification.foreground`.
- Add to `Recorder.allowedEventNames`.

**Acceptance.** Sample app tap on a delivered push produces one `notification_interaction`.

---

### 16.5 Backend asks introduced by this breakdown

In addition to the existing § 14 asks, the v1.1 / v1.2+ tasks above
introduce new asks. These mirror `docs/data-flow.md` § 11; restated
here so the PLAN is self-contained.

**v1.0+ (additive, no new event/metric — informational only):**

- Tier-1 context-bag attribute keys (F16) and URLSession enrichment
  keys (F17). Backend should confirm storage/indexing strategy but
  no parsing risk.

**v1.1 (proposed, blocking for v1.1 ship):**

- `crash.source` discriminator on `app.crash` with values
  `plcrashreporter` · `metrickit` · `watchdog` · `captureerror`. Dedup
  keyed on `crash.metrickit_payload_id` when present.
- New `metricName` values: `scroll_hitch_ratio`, `system_exception`,
  `energy_impact`.
- New `eventName` value: `memory_warning` (or fold into `app_lifecycle`?).
- Scene attribution attributes on `app_lifecycle`.

**v1.2+ (proposed, blocking for v1.2+ ship):**

- New `eventName` values: `background_task`, `notification_interaction`.

### 16.6 Post-v1.2 backlog

Items deliberately out of scope for v1.0 / v1.1 / v1.2+ and parked
until a separate ADR or scope decision lands:

- `opentelemetry-swift-core` removal (if binary-size pressure forces §5.3).
- Distributed trace context propagation (W3C `traceparent` over our
  own URLSession instrumentation, surfaced via a config flag — does
  not affect wire shape).
- Session replay.
- Carthage distribution.
- watchOS / tvOS / visionOS support.
- Mac Catalyst promotion from "best-effort slice" to "supported".
- Items listed in `docs/data-flow.md` § 8 ("Deferred signal") — Core
  Location, StoreKit, CoreMotion, audio session interruption, etc.
  Each needs its own ADR before promotion to a Feature.

---

*End of PLAN-iOS.md.*
