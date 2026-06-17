# CLAUDE.md — `edge-rum-ios` SDK Development Guide

This file is the source of truth for AI-assisted development on this project.
Read it completely before writing any Swift, Objective-C, or build-system
file, generating any scaffolding, or making any suggestions.

For deeper architecture detail, read `PLAN-iOS.md` alongside this file.

---

## What this project is

`edge-rum-ios` is a **native iOS Real User Monitoring SDK**. It captures
performance data, errors, network requests, native crashes, hangs, and user
interactions on iOS apps, then ships them as JSON to a proprietary backend —
the **EdgeTelemetryProcessor** — that also receives data from:

- the web/Ionic-Angular-Capacitor SDK (`edge-rum`)
- the native Android SDK (`edge-rum-android`)

**Wire compatibility with the existing SDKs is a hard requirement.** The
EdgeTelemetryProcessor's Kafka ingestion handles all three platforms with
one dispatcher; the iOS payload must be indistinguishable from the others
except for platform-specific identity values. The wire format is
documented in `docs/payload-schema.json` (sibling repo of record — copied
in once it lands here).

This SDK is Swift, ships as a SwiftPM package + CocoaPods pod +
XCFramework, targets iOS 14+, and uses `opentelemetry-swift-core`
internally as an event model only. **No OpenTelemetry type, name, or
concept escapes the public module.**

---

## Commit / PR hygiene

**Never** add AI co-author trailers to commit messages, PR titles, PR
bodies, issue comments, code comments, or any other artifact. The
following strings are banned without exception:

- `Co-Authored-By: Claude <noreply@anthropic.com>`
- `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`
  (and every other model-tagged variant)
- `🤖 Generated with [Claude Code](https://claude.com/claude-code)`
- `🤖 Generated with Claude Code`
- Any other "Generated with …" or "Co-Authored-By: Claude …" line

This applies even when an example in a tool's documentation, a slash
command, or a prior commit shows the trailer — those examples are
illustrative of HEREDOC formatting, not a required line. If a prior
commit already has it, fix the PR body via `gh pr edit` (safe); do
not force-push to amend the commit without explicit authorization.

## The two rules that override everything else

### Rule 1 — The terminology firewall

The following words and identifiers **must never appear** in:

- Any file under `Sources/EdgeRum/` (the public umbrella target)
- Any `public` or `open` Swift symbol exported from the `EdgeRum` module
- Any public doc comment (`///` triple-slash) on a public symbol
- Any consumer-facing string: `localizedDescription`, error messages
  thrown to consumers, `os_log` / `print` output emitted in
  `debug == false` mode, README, CHANGELOG, public Sample app strings

**Banned in public surface:**

```
opentelemetry / otel / otlp
span / trace / tracer
TracerProvider / SpanProcessor / SpanExporter
MeterProvider / LoggerProvider
instrumentation / telemetry
metric / metrics (as Swift API names — fine in docs as "performance data",
                  and fine in the JSON wire as "metric" / "metricName"
                  because the wire is mandated by the contract)
```

**Allowed internally**, inside any of the non-public targets —
`EdgeRumCore`, `EdgeRumCapture`, `EdgeRumCrash`, `EdgeRumOTelBridge` —
use any name that makes the code clear. The firewall is the `EdgeRum`
public module boundary only.

`@_implementationOnly import EdgeRumCore` (and friends) is the
load-bearing language-level mechanism: a consumer who writes
`import EdgeRum` cannot see the internal targets at all.

**Consumer vocabulary:**

| Instead of...        | Say...                |
|----------------------|-----------------------|
| span / trace         | event                 |
| instrumentation      | capture               |
| telemetry            | performance data      |
| emit / record a span | record an event       |
| metrics              | performance data      |
| OTLP / collector     | (never mentioned)     |
| tracer / exporter    | (never mentioned)     |

### Rule 2 — JSON only, always

All data sent to the backend must be:

- `Content-Type: application/json`
- `JSONEncoder` output of the envelope (see below) as the request body
- No compression, no protobuf, no binary framing, no gzip, no brotli

---

## EdgeTelemetryProcessor contract — read this before touching the Recorder or transport

The iOS SDK must produce payloads matching the EdgeTelemetryProcessor wire
contract. The backend collector tier resolves `tenant_id` from the API
key, so the SDK does **not** send it.

### Envelope structure

```json
{
  "type": "telemetry_batch",
  "timestamp": "2026-06-14T10:30:00.512Z",
  "location": "Nairobi/Kenya",
  "batch_size": 3,
  "events": [ /* …events… */ ]
}
```

- `type`: always the string `"telemetry_batch"`.
- `timestamp`: ISO 8601 string of the batch flush time. Includes
  fractional seconds. Never Unix ms.
- `location`: optional per-app/install string (City/Country). Set via
  `EdgeRumConfig.location` or resolved at runtime when
  `resolveLocation == true`.
- `batch_size`: integer equal to `events.count` — included for parity
  with web/Android.
- `events`: array of event and metric items.

### Required identity attributes on every event

The collector drops events missing these. `Recorder` merges them in from
the internal `ContextProvider` so every emitted event carries them:

- `app.package_name`, `app.name`, `app.version`, `app.build_number`,
  `app.environment`
- `device.id`, `device.platform` (= `"ios"`), `device.model`,
  `device.manufacturer` (= `"Apple"`), `device.os` (= `"ios"`),
  `device.platform_version`, `device.isVirtual`,
  `device.screenWidth`, `device.screenHeight`, `device.pixelRatio`,
  `device.batteryLevel`, `device.batteryCharging`
- `network.type`, `network.effectiveType` (best-effort on iOS)
- `session.id`, `session.start_time`, `session.sequence`
- `user.id` (plus optional `user.name`, `user.email`, `user.phone`)
- `sdk.version`, `sdk.platform` = `"ios-native"`

`sdk.platform = "ios-native"` is a **new value** not previously seen by
the backend. Confirmation that the backend accepts it is the first item
in `PLAN-iOS.md` § "Backend asks".

### Individual event structure

```json
{
  "type": "event",
  "eventName": "navigation",
  "timestamp": "2026-06-14T10:30:00.123Z",
  "attributes": {
    "app.name": "Shop",
    "app.version": "2.1.0",
    "app.package_name": "com.example.shop",
    "app.build_number": "412",
    "app.environment": "production",
    "device.id": "device_1717234876123_a1b2c3d4e5f60718_ios",
    "device.platform": "ios",
    "device.model": "iPhone15,3",
    "device.manufacturer": "Apple",
    "device.os": "ios",
    "device.platform_version": "17.4.1",
    "device.isVirtual": false,
    "device.screenWidth": 1290,
    "device.screenHeight": 2796,
    "device.pixelRatio": 3.0,
    "device.batteryLevel": 0.82,
    "device.batteryCharging": false,
    "network.type": "wifi",
    "network.effectiveType": "4g",
    "session.id": "session_1717234870002_ff009988aabbccdd_ios",
    "session.start_time": "2026-06-14T10:25:00.002Z",
    "session.sequence": 42,
    "user.id": "user_1717100000000_deadbeefcafef00d",
    "sdk.version": "1.0.0",
    "sdk.platform": "ios-native",
    "...eventSpecificAttributes": "..."
  }
}
```

**Wire contract pinned facts:**

| Field                     | Value                            | Notes                                                  |
|---------------------------|----------------------------------|--------------------------------------------------------|
| Outer batch `type`        | `"telemetry_batch"`              | Never the old `"batch"` value                          |
| Per-event `type`          | `"event"` (or `"metric"`)        | Discriminator                                          |
| `eventName`               | see mapping table below          | Backend routes by this; unknown names are dropped      |
| `timestamp`               | ISO 8601 string with fractional  | `ISO8601DateFormatter` with `withFractionalSeconds`    |
| `attributes`              | flat key-value object            | Primitives only, no nesting, no arrays of objects      |
| `app.package_name`        | in `attributes`                  | NOT `app.package`                                      |
| `session.start_time`      | in `attributes`                  | NOT `session.startTime`                                |
| `device.platform_version` | in `attributes`                  | NOT `device.osVersion`                                 |
| Auth header               | `X-API-Key`                      | Value MUST start with `"edge_"`                        |
| Path                      | `POST /collector/telemetry`      | Same path as Android/web                               |

### ID formats

```
device.id:  "device_{epochMs}_{16 hex chars}_ios"
            e.g. "device_1717234876123_a1b2c3d4e5f60718_ios"

session.id: "session_{epochMs}_{16 hex chars}_ios"
            e.g. "session_1717234870002_ff009988aabbccdd_ios"

user.id:    "user_{epochMs}_{16 hex chars}"
            e.g. "user_1717100000000_deadbeefcafef00d"
            (SDK-owned anonymous ID. `EdgeRum.identify()` attaches a
             host-app user identifier as additional attributes but
             does NOT change this generated user.id.)
```

The 16 hex chars are 64 bits of entropy from `SecRandomCopyBytes`
(8 random bytes formatted `%02x`). **Do not use `UUID()`** — its hex
section is 128 bits and breaks the existing format. Persisted IDs that
don't match the format regex on launch are regenerated transparently.

---

## eventName values

The backend dispatches each event by `eventName`. The iOS SDK emits this
fixed set; the static allowlist lives in
`Sources/EdgeRumCore/Recorder.swift` (`Recorder.allowedEventNames`).
Anything not on the list is rejected at `Recorder.recordEvent` ingress
and logged when `debug == true`.

| Signal                                       | `eventName` value                                | Where emitted                                                                 |
|----------------------------------------------|--------------------------------------------------|-------------------------------------------------------------------------------|
| UIKit screen entry                           | `navigation`                                     | `EdgeRumCapture/UIViewControllerCapture.swift` (`viewDidAppear` swizzle)      |
| UIKit screen exit / dwell                    | `screen.duration`                                | same file (`viewWillDisappear` pair)                                          |
| SwiftUI screen entry                         | `navigation` (with `navigation.kind = "swiftui"`)| `EdgeRum/SwiftUI/ViewModifiers.swift` (public `.edgeRumScreen` modifier) and  |
|                                              |                                                  | `UIHostingController` auto-detection in the UIKit swizzle                     |
| HTTP request                                 | `http.request`                                   | `EdgeRumCapture/HTTPCapture.swift` (URLProtocol + delegate swizzle)           |
| Resource timing                              | (`metric`, `metricName` = `"resource_timing"`)   | same file (`URLSessionTaskMetrics`)                                           |
| App launch → first frame                     | `page_load`                                      | `EdgeRumCapture/PageLoadCapture.swift`                                        |
| Tap / interaction                            | `user.interaction`                               | `EdgeRumCapture/InteractionCapture.swift` (`UIWindow.sendEvent` swizzle)      |
| Swift/NSError reported by host               | `app.crash` with `cause = "AppError"`            | `EdgeRum.captureError(_:context:)`                                            |
| NSException                                  | `app.crash` (cause=NativeCrash, runtime=native)  | `EdgeRumCrash/PLCrashIntegration.swift` (replayed on next launch)             |
| Mach signal (SIGSEGV/SIGABRT/SIGBUS/SIGILL)  | `app.crash` (cause=NativeCrash, runtime=native)  | same file                                                                     |
| Main-thread hang                             | `app.crash` (cause=Hang, runtime=native)         | `EdgeRumCrash/HangDetector.swift` (`CFRunLoopObserver` watchdog)              |
| Frame render time                            | (`metric`, `metricName` = `"frame_render_time"`) | `EdgeRumCapture/FrameSampler.swift` (`CADisplayLink`)                         |
| Memory usage                                 | (`metric`, `metricName` = `"memory_usage"`)      | `EdgeRumCapture/MemorySampler.swift` (`mach_task_basic_info` + pressure src)  |
| Long task                                    | (`metric`, `metricName` = `"long_task"`)         | `EdgeRumCapture/RunLoopObserverCapture.swift`                                 |
| Session begins                               | `session.started`                                | `EdgeRum.start()` + `UIApplication.didBecomeActiveNotification`               |
| Session ends                                 | `session.finalized`                              | `UIApplication.willResignActiveNotification` (immediate flush)                |
| `EdgeRum.identify()`                         | `user.profile.update`                            | `Sources/EdgeRum/EdgeRum.swift`                                               |
| `EdgeRum.track()`                            | `custom_event`                                   | same                                                                          |
| `EdgeRum.time().end()`                       | (`metric`, custom `metricName`)                  | `Sources/EdgeRum/RumTimer.swift`                                              |
| Foreground / background                      | `app_lifecycle`                                  | `EdgeRumCapture/LifecycleCapture.swift`                                       |
| Connectivity change                          | `network_change`                                 | `EdgeRumCapture/NetworkPathCapture.swift` (`NWPathMonitor`)                   |

> **Not emitted on iOS:** `LCP`, `FCP`, `CLS`, `INP`, `TTFB`. iOS has
> no native analogue to Web Vitals. Confirmation that the backend
> tolerates iOS batches with no Web Vital metrics is in
> `PLAN-iOS.md` § "Backend asks" item 3.
>
> **Not emitted on iOS:** any `eventName` outside this table. The
> backend silently drops unknowns.

---

## Payload examples

A complete 4-event reference batch (`navigation`, `screen.duration`,
`http.request`, `metric:frame_render_time`) lives in
`docs/payload-example.jsonc`. All other event shapes — `app.crash`,
`user.profile.update`, `custom_event`, `app_lifecycle`, `page_load`,
`network_change`, `session.started`, `session.finalized`, and the
`metric` items from `EdgeRum.time()`, `memory_usage`, `long_task`,
`resource_timing` — follow the same envelope and identity-attribute
rules. `docs/payload-schema.json` is the authoritative attribute list.

---

## Recorder + transport implementation notes

Because every event carries the full context (app, device, session,
user, network) as flat attributes, the internal `Recorder` must:

1. Hold a `ContextProvider` that snapshots app/device/network/session/
   user attributes into an in-memory `AttributeBag`. Updated on init
   and on any change (`identify()`, `NWPathMonitor` transition,
   session rotation, battery notifications).
2. On each `recordEvent` / `recordMetric` call, merge:
   `contextBag.merging(eventBag) { _, new in new }` (event attributes
   win on conflict).
3. Build the outer envelope at flush time:
   ```
   { "type": "telemetry_batch",
     "timestamp": <ISO 8601 of flush time>,
     "location"?: <from config or resolved>,
     "batch_size": events.count,
     "events": [...] }
   ```
4. Never nest objects inside `attributes`. All values must be one of
   `String`, `Int`, `Double`, `Bool`. The `AttributeValue` enum
   enforces this at the type level — see
   `Sources/EdgeRum/AttributeValue.swift`. Flatten any nested data with
   dot-notation keys at the capture layer, not in the `Recorder`.

**Flattening example:**

```swift
// Internal representation (fine to use internally)
struct DeviceInfo {
    let model: String
    let os: String
    struct Screen { let width: Int; let height: Int }
    let screen: Screen
}

// What goes into attributes (must be flat, primitives only)
[
    "device.model": .string("iPhone15,3"),
    "device.os": .string("ios"),
    "device.screenWidth": .int(1290),   // flattened, camelCase trailing token
    "device.screenHeight": .int(2796)
]
```

---

## Repository structure

Four Swift targets, only the first is public:

- `Sources/EdgeRum/` — PUBLIC umbrella. `EdgeRum.swift` (caseless enum,
  static API), `EdgeRumConfig.swift`, `UserContext.swift`,
  `AttributeValue.swift` (sealed `.string`/`.int`/`.double`/`.bool` enum),
  `RumTimer.swift`, `Environment.swift`, `SwiftUI/ViewModifiers.swift`
  (the two `.edgeRum*` modifiers).
- `Sources/EdgeRumCore/` — internal: `Recorder` (single facade),
  `EventEnvelope`, `AttributeBag`, `IdentityProvider`, `SessionManager`,
  `ContextProvider`, `DeviceContext`, `AppContext`, `NetworkContext`,
  `Sampler`, `Clock`, `Persistence/` (Keychain, UserDefaults,
  QueueFile), `Transport/` (Batch, PayloadBuilder, OfflineQueue,
  RetryPolicy, BackgroundUploader).
- `Sources/EdgeRumCapture/` — internal swizzles + samplers
  (`UIViewControllerCapture`, `HTTPCapture`, `InteractionCapture`,
  `FrameSampler`, `MemorySampler`, `RunLoopObserverCapture`,
  `LifecycleCapture`, `NetworkPathCapture`, `PageLoadCapture`).
- `Sources/EdgeRumCrash/` — internal: `PLCrashIntegration`,
  `HangDetector`, `CrashSidecar`.
- `Sources/EdgeRumOTelBridge/` — internal: `OTelToRecorderAdapter`,
  `BridgeBootstrap`.

Tests: `Tests/EdgeRumTests/` (units), `EdgeRumCaptureTests/` (swizzles),
`EdgeRumContractTests/` (wire conformance), `Tests/Fixtures/golden-batch-ios.json`.
Samples: `Samples/EdgeRum{Sample,SwiftUISample,CrashSample}App/`.
Tools: `Tools/{firewall-check,build-xcframework,verify-privacy-manifest}.sh`.
Top-level: `Package.swift`, `EdgeRum.podspec`, `PrivacyInfo.xcprivacy`,
`docs/{payload-schema.json,payload-example.jsonc,decisions.md,terminology.md}`,
`PLAN-iOS.md`, `THIRD_PARTY_LICENSES`.

**Binary dependencies** (vendored as SwiftPM `.binaryTarget` + CocoaPods
`vendored_frameworks`): `CrashReporter.xcframework` (PLCrashReporter,
pinned, notarized).

**Source dependencies**: `open-telemetry/opentelemetry-swift-core` pinned
at `from: "2.4.1"`, imported **only** by `EdgeRumOTelBridge` as
`OpenTelemetryApi` + `OpenTelemetrySdk`, marked `@_implementationOnly`
from every consumer. Invisible from `import EdgeRum`. The umbrella
`opentelemetry-swift` package is **not** a dependency — see
`PLAN-iOS.md` § 5.4.

---

## Public API surface

The entire public surface is documented in `PLAN-iOS.md` § 3. The
short form:

### `EdgeRumConfig`

```swift
public struct EdgeRumConfig {
    public var apiKey: String                     // sent as X-API-Key — must start with "edge_"
    public var endpoint: URL                      // required; no default; host app provides
    public var appName: String?                   // used as app.name in all events
    public var appVersion: String?                // used as app.version
    public var appPackage: String?                // used as app.package_name
    public var appBuild: String?                  // used as app.build_number; omitted when nil
    public var environment: Environment?          // .production, .staging, .development
    public var location: String?                  // batch envelope location, e.g. "Nairobi/Kenya"
    public var resolveLocation: Bool = false      // opt-in IP geo; calls locationProviderUrl once
                                                  // on init, caches "City/Country" for 24h in
                                                  // UserDefaults. Sends device IP to third party.
    public var locationProviderUrl: URL? = URL(string: "https://ipapi.co/json/")
    public var sampleRate: Double = 1.0           // 0.0–1.0; per-session
    public var ignoreUrls: [NSRegularExpression] = []
    public var maxQueueSize: Int = 200
    public var flushInterval: TimeInterval = 5.0
    public var batchSize: Int = 30                // max events per payload
    public var sanitizeUrl: ((URL) -> URL)? = nil
    public var captureNativeCrashes: Bool = true  // registers PLCrashReporter
    public var enableHangDetection: Bool = true   // registers CFRunLoopObserver watchdog
    public var hangTimeout: TimeInterval = 5.0
    public var captureScreens: Bool = true
    public var captureHTTP: Bool = true
    public var captureTaps: Bool = true
    public var captureRenderingPerformance: Bool = true
    public var debug: Bool = false

    public init(apiKey: String, endpoint: URL)
}
```

### `EdgeRum` static methods

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
    public static var deviceId: String { get }
    public static var isEnabled: Bool { get }

    // For host apps that want offline-queue drain via background URLSession.
    // Wire from AppDelegate / SceneDelegate's background-events callback.
    public static func handleBackgroundEvents(identifier: String,
                                              completion: @escaping () -> Void)
}
```

`AttributeValue` is a sealed enum (`.string` / `.int` / `.double` /
`.bool`) — the type system enforces "primitives only" so the wire
contract holds without runtime checks at every entrypoint.

`captureError` takes `[String: AttributeValue]?` (not `[String: Any]`)
deliberately — this is a tightening relative to the web/Android
sketches; see `PLAN-iOS.md` § 14 #1 for the parity discussion.

---

## Swift conventions

- Swift 5.10+ source / Swift 6 toolchain, iOS 14.0+, Xcode 16+.
  (`Package.swift` declares `swift-tools-version: 6.0` to match the
  upstream `opentelemetry-swift-core` 2.x dependency. Consumer apps
  may still build with Xcode 15+ and Swift 5; nothing on our public
  surface requires Swift 6 strict concurrency.)
- `// swiftlint:disable` requires a justification comment on the same line.
- No force-unwrap (`!`) and no implicitly-unwrapped optionals on stored
  properties of public types. Internal force-unwraps require a one-line
  reason comment.
- Prefer `enum` for public namespaces (`public enum EdgeRum`) so the
  type can't be instantiated.
- All public types `Sendable` where possible. `internal` types adopt
  `Sendable` as Swift 5.10 strict-concurrency rolls in (v1.1).
- No `Foundation`-free targets — we use `Date`, `URL`, `URLSession`,
  `URLProtocol`, `JSONEncoder`, etc.
- No `@_spi` on public types unless absolutely necessary.
  `@_implementationOnly import` is the firewall mechanism.
- Doc comments (`///`) on every public symbol. Doc comments must not
  contain any banned term from Rule 1.
- Attributes passed to the `Recorder` are always
  `[String: AttributeValue]` — never `[String: Any]`. Flatten at the
  capture layer; the `Recorder` never receives nested data.

---

## Testing conventions

Test target: `Tests/EdgeRumContractTests/` carries the wire conformance
tests. Every transport-touching test must use the `WireAssertions`
helper, which asserts:

- Envelope: `type == "telemetry_batch"`, `timestamp` is ISO 8601 string,
  `batch_size == events.count`.
- Per-event: `type ∈ {"event","metric"}`, `timestamp` present.
- Identity attrs present and well-formed: `session.id` has
  `"session_"` prefix, `device.id` has `"device_"` prefix,
  `sdk.platform == "ios-native"`.
- No forbidden tokens anywhere in the raw bytes:
  `traceId`, `spanId`, `resourceSpans`, `opentelemetry`.
- `attributes` values are all primitives — `String`/`Int`/`Double`/`Bool`.
- Request headers: `X-API-Key` value starts with `"edge_"`,
  `Content-Type: application/json`.

**Golden batch test:** `Tests/Fixtures/golden-batch-ios.json` is checked
into the repo. It is the byte-for-byte expected output for a fixed
fixture (frozen `Clock`, frozen `IdentityProvider`, frozen
`DeviceContext`). The contract test snapshots produced output and
diffs against the fixture. The fixture is reviewed against the Android
and web SDKs' equivalent fixtures so the platforms stay aligned modulo
platform-specific values (`device.platform`, `device.model`,
`sdk.platform`).

---

## Error handling conventions

- **`start()` input validation** — use `precondition` (not `assert`, so
  misuse fails in release too). Required checks: `apiKey` non-empty,
  `apiKey.hasPrefix("edge_")`, `endpoint.scheme == "https"` unless
  `config.debug == true`.
- **Misuse on other public methods** (e.g. `identify()` before `start()`)
  is a no-op with one `os_log` warning. Never a crash.
- **Internal errors** in background queue / transport / swizzle / capture
  paths are caught broadly and swallowed. Log via `os_log` only when
  `config.debug == true`. The SDK must never crash the host app.

---

## iOS conventions

- Minimum target: iOS 14.0. Use `@available` guards for the few
  iOS 15+ APIs we touch (e.g. `CADisplayLink.preferredFrameRateRange`)
  with a viable fallback. Do not raise the minimum to 15+ without a
  decisions.md entry.
- Swizzle install runs once, on the main thread, from
  `EdgeRum.start()`. Guarded by a `Once` token. Swizzles attach to the
  base class; never to a subclass with method overrides.
- No private API use. `firewall-check.sh` also greps for known private
  selectors (`_setSpringboardLaunchPriority:`, `_remoteViewController`,
  etc.) and fails CI if found.
- All restricted-reason APIs (file timestamp, system boot time, disk
  space, UserDefaults) are declared in `PrivacyInfo.xcprivacy` with
  the codes from `PLAN-iOS.md` § 10.4.
- No `IDFA`, no `ATTrackingManager`, no `AdSupport` import. The SDK is
  ATT-neutral; `device.id` is SDK-owned (see § "Session and ID rules").
- We do **not** call our own POST endpoint from instrumented sessions.
  Every internal request carries `X-Edge-Rum-Internal: 1` and
  `URLSessionTask.taskDescription = "edge-rum-internal"`; the HTTP
  capture layer checks both before recording.

---

## SwiftUI conventions

- Public SwiftUI integration lives at
  `Sources/EdgeRum/SwiftUI/ViewModifiers.swift`.
- The two public modifiers:

  ```swift
  extension View {
      public func edgeRumScreen(_ name: String,
                                attributes: [String: AttributeValue]? = nil)
          -> some View
      public func edgeRumTrackTap(_ name: String,
                                  attributes: [String: AttributeValue]? = nil)
          -> some View
  }
  ```

- Both emit existing `eventName`s — `navigation` /`screen.duration` and
  `user.interaction` — with a `navigation.kind = "swiftui"` (or
  `interaction.kind = "tap"`) attribute differentiator. **No new
  eventName is introduced for SwiftUI.** See `PLAN-iOS.md` § 6.2 and
  the "Backend asks" item 4.
- `UIHostingController` is detected by the UIKit swizzle and routes the
  emitted `navigation` through the same allowlisted name.

---

## Session and ID rules

```
device.id:   "device_{epochMs}_{16 hex chars}_ios"   ← stored in Keychain
session.id:  "session_{epochMs}_{16 hex chars}_ios"  ← stored in UserDefaults
user.id:     "user_{epochMs}_{16 hex chars}"         ← stored in UserDefaults
```

Generate the 16 hex chars by calling `SecRandomCopyBytes(kSecRandomDefault,
8, &bytes)` and formatting each byte as `%02x`. **Do not use `UUID()`** —
its hex section is 128 bits and breaks the format.

**Storage**

- `device.id` — Keychain, attribute
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, no access group.
  Survives reinstall only on legacy iOS or when the host app shares a
  keychain group. See `PLAN-iOS.md` § 8.2 for the rationale.
- `session.id`, `session.start_time`, `session.sequence` — UserDefaults
  under suite `com.edge.rum.session`.
- `user.id` — UserDefaults under the same suite. Not iCloud-synced.

**Session lifecycle**

- Session starts on `EdgeRum.start()` if none active, OR when the
  persisted session's last-active timestamp is older than 30 minutes.
- "Last active" updates on every `didBecomeActive` and every
  `Recorder.recordEvent` call.
- `session.sequence` increments **on every successfully sent batch**
  (transport ack). Stored alongside `session.id` in UserDefaults under
  an `NSLock`.
- `session.start_time` is captured at session creation and never updates.
- `session.finalized` is emitted on `willResignActive` and triggers an
  immediate flush. On flush failure the batch goes to the offline
  queue and the background uploader drains it.

**Crash sidecar**

`Library/Caches/edge-rum/last-session.json` mirrors the current
`session.id`/`session.start_time`/`session.sequence`/`user.*`/`device.id`
on every event. PLCrashReporter replay reads it on next launch so the
emitted `app.crash` event carries the **previous** session's identity,
not the current one.

---

## Transport rules

```
Auth:         X-API-Key: <apiKey>            (must start with "edge_")
Content-Type: application/json
Endpoint:     POST <config.endpoint>/collector/telemetry
User-Agent:   EdgeRum-iOS/<sdk.version> (<device.model>; iOS <os>)
```

Retry schedule (matches Android SDK exponential backoff):

```
Attempt 1: immediate
Attempt 2: +2s
Attempt 3: +8s
Attempt 4: +30s → push to OfflineQueue
```

- Retry on: status `0` (network error), `429` (respect `Retry-After`,
  cap at 60s), `503`. 5xx other than 503 → treat as 503.
- Never retry: other `4xx`. Drop the batch and log when `debug == true`.
- Errors and `session.finalized` flush immediately. All other events
  follow `flushInterval` (default 5.0s) or `batchSize` (default 30)
  whichever fires first.
- Background flush uses a separately-configured `URLSession` with
  `URLSessionConfiguration.background(withIdentifier:
  "com.edge.rum.upload")`. The host app must wire
  `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
  → `EdgeRum.handleBackgroundEvents(identifier:completion:)` to fully
  drain after process death. If unwired, background flushing degrades
  gracefully to next-foreground replay.

---

## Offline queue rules

- Storage: files under `Library/Caches/edge-rum/queue/<epochMs>-<seq>.json`.
  Each file is one complete envelope payload, ready to POST verbatim.
- Cap: `maxQueueSize` (default 200) events across files. Overflow drops
  the oldest file first.
- Flush: sequential. Success deletes the file. Failure leaves it.
- Triggers: `NWPathMonitor` transitions to `.satisfied`,
  `UIApplication.didBecomeActiveNotification`, `EdgeRum.enable()`.
- `EdgeRum.disable()` halts emission and stops the flush timer.
  Already-on-disk files remain on disk. Swizzles remain installed
  (we cannot safely un-swizzle mid-run).

---

## Bundle and binary size rules

- `EdgeRum` framework, slim, dynamic, arm64: target **< 1.6 MB**.
- Without `opentelemetry-swift-core` (architectural insurance — see
  `PLAN-iOS.md` § 5.3): target **< 900 KB**.
- PLCrashReporter is a separate XCFramework (~600 KB). Document the
  breakdown in the release notes for every minor.
- `opentelemetry-swift-core` is **bundled, not a peer dependency**.
  The consumer never imports it. Marked `@_implementationOnly` from
  every internal consumer.
- `Sources/EdgeRum/` must not transitively import any
  third-party module other than the internal targets. No public
  `@_exported import`.

---

## CI checks (all must pass before merge)

1. `swift build -c release` for `iphoneos` and `iphonesimulator`.
2. `swift test --enable-code-coverage`.
3. `xcodebuild -create-xcframework` smoke test produces a valid
   `.xcframework`.
4. Terminology check: `Tools/firewall-check.sh` runs
   `swift package dump-symbol-graph --target EdgeRum`, greps for the
   Rule-1 banned terms in any `public` / `open` symbol, and fails on
   match. Also greps doc comments and the README.
5. Attribute flatness check: contract tests assert no
   non-primitive value appears in any test payload's `attributes`.
6. Privacy manifest check: `Tools/verify-privacy-manifest.sh` confirms
   every restricted-reason API used in code is declared in
   `PrivacyInfo.xcprivacy`.
7. SwiftLint clean (`.swiftlint.yml` checked in).
8. Snapshot test: `golden-batch-ios.json` matches generated output.
9. Performance test: `XCTMetric.cpu` / `.memory` /
   `.applicationLaunch` budgets in `PLAN-iOS.md` § 11 hold.

---

## When in doubt checklist

1. **Public surface?** → Apply Rule 1 (terminology firewall). Verify no
   banned term appears in the Swift symbol, the doc comment, or any
   string emitted at runtime.
2. **Touches the wire?** → Apply Rule 2 (JSON only, `telemetry_batch`
   envelope, ISO 8601 strings, primitives-only attributes).
3. **Adding a new `eventName`?** → Stop. Confirm with the backend team,
   update `docs/payload-schema.json` and the table above, and add it
   to `Recorder.allowedEventNames`.
4. **Attributes nested?** → Flatten with dot-notation keys at the
   capture site. The `Recorder` only takes `AttributeValue` primitives.
5. **Timestamp field?** → ISO 8601 string with fractional seconds via
   `ISO8601DateFormatter` with `withFractionalSeconds`. Never Unix ms.
6. **Auth header?** → `X-API-Key`, never `Authorization: Bearer`.
   Value must start with `"edge_"`.
7. **Adding a public Swift symbol?** → Re-read § "Public API surface"
   and `PLAN-iOS.md` § 3. Symbol goes in `Sources/EdgeRum/`,
   `@_implementationOnly` rules still apply to anything it pulls in.
8. **Touching swizzles?** → Install once on the main thread from
   `EdgeRum.start()`. Guard with a `Once` token. Swizzle base classes.
   Never forward control to a private API.
9. **Touching crash code?** → PLCrashReporter is the only crash backend.
   Replay-on-next-launch reads the crash sidecar so the emitted
   `app.crash` carries the **previous** session's identity. Never
   the current session's.
10. **iOS version guard?** → Wrap in `if #available(iOS X, *)` with a
    documented fallback. Do not raise the minimum to 15+ without
    `docs/decisions.md`.
11. **Non-obvious choice?** → Write an entry in `docs/decisions.md`.
12. **Anything that affects the backend?** → Add it to
    `PLAN-iOS.md` § "Backend asks" so the parity discussion stays in
    one place.
