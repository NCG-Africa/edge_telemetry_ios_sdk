# EdgeRum — iOS Real User Monitoring SDK

`edge-rum-ios` is the native iOS sibling of the [`edge-rum`](https://github.com/NCG-Africa/edge-rum) (web/Ionic/Capacitor) and [`edge-rum-android`](https://github.com/NCG-Africa/edge-rum-android) SDKs. It captures performance data, errors, native crashes, hangs, network requests, and user interactions on iOS apps and ships them as JSON to the EdgeTelemetryProcessor backend used by all three platforms.

> **Status.** Public API surface (F2) is in place. F3 lands the core pipeline — the internal Recorder fan-in, identity context, sampler, and JSON envelope assembly — so the SDK now produces wire-conformant batches in memory. Transport (HTTP POST), persistence, offline queue, and the capture layer (screen / HTTP / interaction / native crash) follow across F4–F18.

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

- `.edgeRumScreen` records a screen entry on appear and the dwell on disappear. Works on every `View`.
- `.edgeRumTrackTap` attaches a `.simultaneousGesture(TapGesture())` so it never swallows the host app's own gestures. **It will not fire on a SwiftUI `Button`** — buttons consume their touch before any simultaneous tap recognizer runs. Instrument `Button` actions directly as shown above.

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

## Design docs

| Doc | What it covers |
| --- | --- |
| [`PLAN-iOS.md`](PLAN-iOS.md) | The full feature plan F1 → F23, milestones, acceptance criteria, and per-task references. Authoritative for scope. |
| [`docs/data-flow.md`](docs/data-flow.md) | End-to-end data flow from capture call to backend ingest. Internal — references the internal architecture by name. |
| [`docs/decisions.md`](docs/decisions.md) | Architectural Decision Records. ADR-002 explains the F2 public API shape choices. |
| [`docs/payload-example.jsonc`](docs/payload-example.jsonc) | Reference batch payload — what the SDK actually ships on the wire. |
| [`CLAUDE.md`](CLAUDE.md) | Contributor guide; binding rules for AI-assisted development. |

## License

To be added — see the project ticket for the licensing decision.
