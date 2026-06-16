# EdgeRum — iOS Real User Monitoring SDK

`edge-rum-ios` is the native iOS sibling of the [`edge-rum`](https://github.com/NCG-Africa/edge-rum) (web/Ionic/Capacitor) and [`edge-rum-android`](https://github.com/NCG-Africa/edge-rum-android) SDKs. It captures performance data, errors, native crashes, hangs, network requests, and user interactions on iOS apps and ships them as JSON to the EdgeTelemetryProcessor backend used by all three platforms.

> **Status.** Public API surface (F2), the core pipeline (F3), persistent identity (F4), and the F5 transport layer are in place — events flow over HTTPS to the EdgeRum collector endpoint, the retry schedule survives transient failures, failed batches spill onto a file-backed offline queue, and a background `URLSession` finishes pending uploads after the host app is suspended. **F6 (UIKit) and F7 (SwiftUI) light up the first capture surfaces — every screen entry now auto-emits a `navigation` event and every paired exit emits a `screen.duration` metric, whether the screen is presented through UIKit or SwiftUI.** **F8 lands automatic HTTP capture — every outgoing `URLSession` request produces an `http.request` event and a companion `resource_timing` metric.** **F9 captures completed UIKit taps as `user.interaction` events with secure-entry fields excluded by construction.** **F10 lights up the continuous performance signals — `frame_render_time` (per-second `CADisplayLink` window), `memory_usage` (10 s mach poll plus memory-pressure transitions), and `long_task` (≥50 ms main-thread stalls) — all flowing as `metric` items on the same envelope.** Native crash capture follows across F14.

## Supported iOS

| Floor | Builds against | CI |
| --- | --- | --- |
| iOS 14.0+ | Swift 5.10 / Swift 6 toolchain, Xcode 16+ | macOS 15 runners — `swift build`, `swift test`, `pod lib lint`, `xcodebuild` for device + simulator |

The iOS floor is enforced by [`Tools/check-supported-ios.sh`](Tools/check-supported-ios.sh), which cross-checks `Package.swift`, `EdgeRum.podspec`, `PLAN-iOS.md`, and this README on every PR.

## Install

### Swift Package Manager

```swift
.package(url: "https://github.com/NCG-Africa/edge-rum-ios.git", from: "1.0.0-alpha.1")
```

Then add the `EdgeRum` product to your app target's dependencies:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "EdgeRum", package: "edge-rum-ios"),
    ]
)
```

`EdgeRumStatic` is the static-linked variant for app-extension hosts.

### CocoaPods

```ruby
pod 'EdgeRum', '~> 1.0.0-alpha.1'
```

## Quick start

```swift
import EdgeRum

// Once, at app launch (e.g. AppDelegate.didFinishLaunchingWithOptions).
var config = EdgeRumConfig(
    apiKey: "edge_live_abc123",
    endpoint: URL(string: "https://collect.example.com")!
)
config.appName = "Shop"
config.appVersion = "2.1.0"
config.environment = .production
EdgeRum.start(config)

// From anywhere in the app.
EdgeRum.track("checkout_started", attributes: [
    "cart.size": 3,
    "cart.total": 49.95,
    "user.is_member": true,
    "ab.bucket": "treatment"
])

// Capture errors thrown in your code.
do {
    try submitOrder()
} catch {
    EdgeRum.captureError(error, context: ["payment.method": "card"])
}

// Time a chunk of work.
let timer = EdgeRum.time("checkout.submit")
performCheckout {
    timer.end(attributes: ["payment.method": "card"])
}
```

### SwiftUI

```swift
import SwiftUI
import EdgeRum

struct CheckoutView: View {
    var body: some View {
        VStack {
            // For Button, instrument the action closure directly —
            // SwiftUI's Button consumes the touch before any
            // `simultaneousGesture` runs.
            Button(action: {
                EdgeRum.track("buy_button", attributes: ["product.id": "SKU-123"])
                buy()
            }) {
                Text("Buy")
            }

            // For non-Button tap-able views (cards, rows, custom
            // composites) the modifier records the tap without
            // swallowing the host app's own gestures.
            ProductCard(sku: "SKU-456")
                .edgeRumTrackTap("product_card", attributes: ["product.id": "SKU-456"])
        }
        .edgeRumScreen("Checkout", attributes: ["funnel.step": 3])
    }
}
```

The two view modifiers are unconditional at the iOS 14 floor.

- `.edgeRumScreen` records a screen entry on appear and the dwell on disappear. Works on every `View`. The disappear emit is a `screen.duration` performance metric with the same attribute schema as the UIKit emit (`screen.name`, `screen.kind`, `screen.duration_ms`, `value`) so cross-platform dashboards see one shape.
- `.edgeRumTrackTap` attaches a `.simultaneousGesture(TapGesture())` so it never swallows the host app's own gestures. **It will not fire on a SwiftUI `Button`** — buttons consume their touch before any simultaneous tap recognizer runs. Instrument `Button` actions directly as shown above.

A working sample app lives at [`Samples/EdgeRumSwiftUISampleApp/`](Samples/EdgeRumSwiftUISampleApp/) — open the `.xcodeproj` in Xcode and Run on any iOS Simulator.

## Automatic screen capture

Once `EdgeRum.start(_:)` runs, every UIKit screen entry produces a `navigation` event and every paired exit produces a `screen.duration` metric — no per-screen code required. The capture is installed on the base `UIViewController` so every subclass inherits it.

- **Container view controllers are skipped.** `UINavigationController`, `UITabBarController`, and `UIPageViewController` are recognised and never produce their own `navigation` events — the contained controller's `viewDidAppear` is what counts.
- **Screen names** prefer the controller's `accessibilityIdentifier` (stable across renames), falling back to the reflected type name.
- **SwiftUI screens** presented via `UIHostingController` are recognised automatically and tagged `navigation.kind = "swiftui"`; the hosted Content type provides the screen name. The public `.edgeRumScreen` modifier emits the same wire shape for SwiftUI screens that are not driven through a hosting controller.
- **`navigation.previous_screen`** chains across appears so transitions are easy to reconstruct downstream.
- **Opt out** by setting `EdgeRumConfig.captureScreens = false` on the config you pass to `start(_:)`.

## Automatic HTTP capture

Once `EdgeRum.start(_:)` runs, every outgoing `URLSession` request produces an `http.request` event and a companion `resource_timing` performance metric — no per-call code required. Both `URLSession.shared` and consumer-created `URLSession(configuration: .default, delegate:, ...)` flows are intercepted at the protocol layer; the SDK never wraps or replaces your delegate.

- **What's captured.** `http.method`, `http.url`, `http.host`, `http.path`, `http.status_code`, `http.duration_ms`, `http.request_size`, `http.response_size`, `http.from_cache`, and `http.error` (only on failure). The companion `resource_timing` metric carries `resource.dns_ms`, `resource.connect_ms`, `resource.tls_ms`, `resource.ttfb_ms`, and `resource.response_ms` derived from `URLSessionTaskMetrics`.
- **The SDK's own POSTs are filtered out** of the recording stream by three independent checks: an `X-Edge-Rum-Internal` request header, the `edge-rum-internal` task description marker, and a host-prefix check against the configured collector endpoint. Your dashboards never see SDK traffic.
- **`EdgeRumConfig.ignoreUrls`** drops events whose URL matches any of the supplied `NSRegularExpression`s — useful for keeping your own analytics endpoints or known-noisy URLs out of the data.
- **`EdgeRumConfig.sanitizeUrl`** runs synchronously on the caller thread for every captured URL — strip query parameters, redact path segments, replace tokens. The sanitised URL is reflected on both the `http.request` event and the `resource_timing` metric so query-string redactions stay consistent across both signals.
- **Background sessions are not instrumented.** `URLSessionConfiguration.background(withIdentifier:)` has no in-process delegate window for `URLSessionTaskMetrics`, so emitting an `http.request` without a timing companion would be misleading. The host's background uploads continue to work; they just don't appear in the capture stream.
- **Opt out** by setting `EdgeRumConfig.captureHTTP = false` on the config you pass to `start(_:)`.

## Automatic interaction capture

Once `EdgeRum.start(_:)` runs, every completed tap on a UIKit view produces a `user.interaction` event — no per-button code required. The capture is installed on the base `UIWindow.sendEvent(_:)` so every subclass inherits it, and emits exactly once per `.ended` touch (drag-aways and `.began`-only sequences are ignored).

- **What's captured.** `interaction.kind = "tap"`, `interaction.target` (reflected class name of the resolved target view), `interaction.target_id` (the `accessibilityIdentifier`, or the button's current title when the target is a `UIButton`; omitted otherwise), and `interaction.screen` (the current screen name from the F6 navigation pointer; omitted when no screen has appeared yet).
- **Target resolution** prefers a `UIControl` ancestor (button, switch, slider, segmented control), then a `UITableViewCell` / `UICollectionViewCell`, falling back to the hit view itself. Controls always win over cells so the report names the action surface, not the row container.
- **Secure text fields are never recorded.** If the tap's responder chain reaches a `UITextField` with `isSecureTextEntry == true`, the event is silently dropped. The capture path never reads `.text` from any view.
- **SwiftUI taps** use the public `.edgeRumTrackTap` modifier and emit the same `user.interaction` wire shape; nothing extra is needed for SwiftUI content rendered via `UIHostingController` because it still goes through `UIWindow.sendEvent`.
- **Opt out** by setting `EdgeRumConfig.captureTaps = false` on the config you pass to `start(_:)`.

## Continuous performance samplers

Once `EdgeRum.start(_:)` runs, three independent samplers emit `metric` items on a steady cadence — no per-call code required. All three share the wire envelope used by the rest of the SDK and respect `EdgeRum.disable()`.

- **`frame_render_time`** — a single `CADisplayLink` attached to the main runloop's `.common` modes feeds a 1-second window aggregator. Every second the aggregator emits one metric carrying `frame.max_ms`, `frame.p95_ms`, `frame.dropped_count`, `frame.target_hz` (60 on standard displays, 120 on ProMotion via `preferredFrameRateRange` on iOS 15+), `frame.source = "displaylink"`, and `value = frame.max_ms`. The display link pauses on `willResignActive` and resumes on `didBecomeActive` so backgrounded apps don't burn battery and don't report a spurious "dropped" burst on resume.
- **`memory_usage`** — a `DispatchSourceTimer` polls `mach_task_basic_info` (RSS, virtual) and `task_vm_info` (`phys_footprint`) every 10 s; in parallel a `DispatchSource.makeMemoryPressureSource(eventMask: .all)` emits an out-of-band sample tagged `memory.pressure` ∈ `"normal"` / `"warning"` / `"critical"` on every transition. All sizes are reported in kB to match the existing wire contract.
- **`long_task`** — a `CFRunLoopObserver` on the main runloop measures the interval between `.afterWaiting` and the next `.beforeWaiting`. Any work segment ≥ 50 ms emits a `long_task` metric with `value` (ms), `long_task.threshold_ms`, and a `long_task.stack` snapshot (truncated to 4 KiB). Long tasks are a *metric*, not a crash — F14's separate hang detector handles multi-second stalls and emits `app.crash` with `cause = "Hang"`.
- **Opt out** by setting `EdgeRumConfig.captureRenderingPerformance = false` on the config you pass to `start(_:)`.

## Public API

| Symbol | Purpose |
| --- | --- |
| `EdgeRum.start(_:)` | Bootstrap the SDK. Idempotent — second call with the same `apiKey` + `endpoint` is a no-op; different identity is warn-and-ignore. |
| `EdgeRum.identify(_:)` | Attach a host-app user profile to subsequent events. |
| `EdgeRum.track(_:attributes:)` | Record a custom event. |
| `EdgeRum.trackScreen(_:attributes:)` | Record a screen entry from UIKit code paths. |
| `EdgeRum.time(_:)` | Begin measuring an interval; returns a `RumTimer`. |
| `EdgeRum.captureError(_:context:)` | Report a thrown `Error`. Domain, code, and message are flattened onto the event automatically. |
| `EdgeRum.disable()` / `EdgeRum.enable()` | Pause / resume capture. The offline queue is preserved across pauses. |
| `EdgeRum.sessionId` / `EdgeRum.deviceId` / `EdgeRum.isEnabled` | Read-only state for host-app diagnostics. |
| `EdgeRum.handleBackgroundEvents(identifier:completion:)` | Forward `application(_:handleEventsForBackgroundURLSession:completionHandler:)` so background uploads can finish after process death. |
| `View.edgeRumScreen(_:attributes:)` | SwiftUI screen capture modifier. |
| `View.edgeRumTrackTap(_:attributes:)` | SwiftUI tap-tracking modifier — non-intercepting. |
| `EdgeRumConfig` | Configuration struct. Two required fields (`apiKey`, `endpoint`); every other field has a documented default. |
| `UserContext`, `Environment` | Value types passed to `identify(_:)` / `config.environment`. |
| `AttributeValue` | Sealed enum — `.string`, `.int`, `.double`, `.bool`. Enforces the JSON wire's primitive-only attribute constraint at compile time. Literal-friendly. |
| `RumTimer` | Returned by `EdgeRum.time(_:)`. Idempotent `end()` and `cancel()`. |
| `EdgeRum.sdkVersion` | SemVer string for this build, emitted as `sdk.version` on every event. |

`EdgeRumConfig` defaults documented in code: `sampleRate = 1.0`, `maxQueueSize = 200`, `flushInterval = 5.0s`, `batchSize = 30`, `hangTimeout = 5.0s`, all `capture*` toggles `true`, `debug = false`. See [`Sources/EdgeRum/EdgeRumConfig.swift`](Sources/EdgeRum/EdgeRumConfig.swift) for the full field list.

## How events flow

Every public call (`track`, `trackScreen`, `identify`, `time`, `captureError`, plus the two SwiftUI modifiers) routes through one internal Recorder. The Recorder:

1. Validates the wire `eventName` against a strict 12-name allowlist (anything else is dropped, and logged when `debug = true`).
2. Applies the per-session sample-rate decision. The forced-emit set — `session.started`, `session.finalized`, `app.crash`, `network_change` — always passes regardless of the sample rate.
3. Merges the current identity context (`app.*`, `device.*`, `session.*`, `user.*`, `network.*`, `sdk.*`) into the event's attributes; event-supplied attrs win on conflict.
4. Buffers events and flushes by whichever of these fires first: `batchSize` reached, `flushInterval` timer elapsed, or an immediate-flush event (`recordError`, `session.finalized`).
5. Hands the assembled batch envelope to the transport layer.

Sample rate, batch size, and flush interval are all configurable on `EdgeRumConfig`. See [`docs/payload-example.jsonc`](docs/payload-example.jsonc) for the exact wire shape and [`docs/decisions.md`](docs/decisions.md) for the design rationale.

## Offline & background

When the live transport can't reach the backend the SDK doesn't drop the batch:

1. The first failure schedules a retry on the **0 / 2 / 8 / 30 s** ladder (status `0`, `429`, or `503`; other 5xx responses are treated as `503`; `429`/`503` honor `Retry-After`, capped at 60 s). Non-retryable 4xx codes drop the batch.
2. After the fourth attempt fails, the encoded payload spills into `Library/Caches/edge-rum/queue/<epochMs>-<seq>.json` — one file per batch, capped at `maxQueueSize` (default 200) with oldest-file-first overflow.
3. The queue drains sequentially on three triggers: `NWPathMonitor` reporting `.satisfied`, `EdgeRum.enable()`, and (once F11 lands) `didBecomeActive`. Each success deletes the file; the first failure aborts the drain so the order is preserved.

Background uploads — POSTs that were mid-flight when the user hit the home button — are handled by a separate `URLSessionConfiguration.background(withIdentifier: "com.edge.rum.upload")`. Wire it up from your `AppDelegate`:

```swift
func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
) {
    EdgeRum.handleBackgroundEvents(identifier: identifier, completion: completionHandler)
}
```

If you skip the wire-up, background uploads still complete — they just won't notify the system, and the OS won't grant you another background window. The next foreground flush replays anything still in the offline queue.

## Identity & session model

F4 makes the three SDK-owned identifiers persistent so the backend sees stable values across launches:

| ID | Format | Storage |
| --- | --- | --- |
| `device.id` | `device_<epochMs>_<16 hex>_ios` | Keychain (service `com.edge.rum.identity`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`). UserDefaults fallback when the Keychain write fails. iOS clears Keychain on uninstall on modern installs — `device.id` rotates on reinstall in practice. |
| `session.id` | `session_<epochMs>_<16 hex>_ios` | UserDefaults suite `com.edge.rum.session` along with `session.start_time`, `session.sequence`, and `session.lastActiveAt`. |
| `user.id` | `user_<epochMs>_<16 hex>` | Same UserDefaults suite. SDK-owned anonymous id — `EdgeRum.identify(_:)` attaches `user.name`/`user.email`/`user.phone` as additional attributes but **does not** change this generated `user.id`. |

The 16 hex chars come from `SecRandomCopyBytes(8)` formatted `%02x` — not `UUID()`, whose 128-bit hex section would break the cross-platform regex the backend dispatcher uses.

A session rotates when either of the following holds at the next `recordEvent`:

- the persisted `lastActiveAt` is older than 30 minutes, **or**
- there's no persisted session at all (cold start / first launch).

Rotation emits a `session.finalized` event carrying the **prior** session's identity (so the backend can close the session out correctly), followed by `session.started` for the new id. `session.sequence` increments after each successful transport ack via `Recorder.didAckBatch()` so the backend can detect dropped batches.

A read-only mirror of the live identity is written to `Library/Caches/edge-rum/last-session.json` on every event — F14's crash backend reads it on next launch so a replayed `app.crash` carries the crashing session's id rather than the current one.

## Design docs

| Doc | What it covers |
| --- | --- |
| [`PLAN-iOS.md`](PLAN-iOS.md) | The full feature plan F1 → F23, milestones, acceptance criteria, and per-task references. Authoritative for scope. |
| [`docs/data-flow.md`](docs/data-flow.md) | End-to-end data flow from capture call to backend ingest. Internal — references the internal architecture by name. |
| [`docs/decisions.md`](docs/decisions.md) | Architectural Decision Records. ADR-002 covers F2; ADR-003 covers F3; ADR-004 covers the F4 persistent identity model. |
| [`docs/payload-example.jsonc`](docs/payload-example.jsonc) | Reference batch payload — what the SDK actually ships on the wire. |
| [`CLAUDE.md`](CLAUDE.md) | Contributor guide; binding rules for AI-assisted development. |

## License

To be added — see the project ticket for the licensing decision.
