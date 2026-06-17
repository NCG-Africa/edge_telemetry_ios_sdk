# EdgeRum — iOS Real User Monitoring SDK

[![Swift Package Manager](https://img.shields.io/badge/SwiftPM-compatible-brightgreen.svg)](https://swift.org/package-manager/)
[![CocoaPods](https://img.shields.io/badge/CocoaPods-1.0.0--alpha.1-blue.svg)](https://cocoapods.org)
[![Supported iOS](https://img.shields.io/badge/iOS-14.0%2B-blue.svg)](#supported-ios)
[![License](https://img.shields.io/badge/license-TBD-lightgrey.svg)](#contributing-and-license)
[![CI](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/actions/workflows/ci.yml/badge.svg)](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/actions/workflows/ci.yml)

`edge-rum-ios` is the native iOS Real User Monitoring SDK — performance
data, errors, native crashes, hangs, network requests, and user
interactions captured on iOS apps and shipped as JSON to the EdgeRum
collector that already serves the web and Android SDKs. The public
Swift surface is a small, EdgeRum-native vocabulary; the wire is
JSON-only — no compression or binary framing — and the SDK is
ATT-neutral, IDFA-free, and ships with a privacy manifest that
satisfies App Review out of the box.

## Supported iOS

| Floor     | Builds against                            | CI |
|-----------|-------------------------------------------|----|
| iOS 14.0+ | Swift 5.10 / Swift 6 toolchain, Xcode 16+ | macOS 15 runners — `swift build`, `swift test`, `pod lib lint`, `xcodebuild` for device + simulator, doc-quality job |

The floor is enforced by [`Tools/check-supported-ios.sh`](Tools/check-supported-ios.sh),
which cross-checks `Package.swift`, `EdgeRum.podspec`, `PLAN-iOS.md`,
and this README on every PR.

## Install

EdgeRum ships through three channels — pick the one that matches your
host project.

### Swift Package Manager

```swift-skip
.package(url: "https://github.com/NCG-Africa/edge_telemetry_ios_sdk.git",
         from: "1.0.0-alpha.1")
```

Then add the `EdgeRum` product to your app target's dependencies:

```swift-skip
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "EdgeRum", package: "edge-rum-ios")
    ]
)
```

`EdgeRumStatic` is the static-linked variant for app-extension hosts.

### CocoaPods

```ruby
pod 'EdgeRum', '~> 1.0.0-alpha.1'
```

### XCFramework

Download `EdgeRum.xcframework` from the latest GitHub Release, drop
it into your project, and embed it in the app target. Drag-and-drop
into Xcode's *Frameworks, Libraries, and Embedded Content* picker;
choose *Embed & Sign* unless you are linking from an app extension.

## 5-minute quickstart

Pick your app shell. Every block in this section compiles against the
package via `Tools/extract-readme-code.sh` and is built by CI on every PR.

### UIKit — AppDelegate

```swift
import UIKit
import EdgeRum

final class QuickstartAppDelegate: UIResponder, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        var config = EdgeRumConfig(
            apiKey: "edge_live_abc123",
            endpoint: URL(string: "https://collect.example.com")!
        )
        config.appName = "Shop"
        config.appVersion = "2.1.0"
        config.environment = .production
        EdgeRum.start(config)
        return true
    }
}
```

### UIKit — SceneDelegate

```swift
import UIKit
import EdgeRum

final class QuickstartSceneDelegate: UIResponder, UIWindowSceneDelegate {

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        var config = EdgeRumConfig(
            apiKey: "edge_live_abc123",
            endpoint: URL(string: "https://collect.example.com")!
        )
        config.appName = "Shop"
        EdgeRum.start(config)
    }
}
```

### SwiftUI

```swift
import SwiftUI
import EdgeRum

struct QuickstartShopApp: App {
    init() {
        var config = EdgeRumConfig(
            apiKey: "edge_live_abc123",
            endpoint: URL(string: "https://collect.example.com")!
        )
        config.appName = "Shop"
        EdgeRum.start(config)
    }

    var body: some Scene {
        WindowGroup {
            Text("Home").edgeRumScreen("Home")
        }
    }
}
```

## Configuration reference

`EdgeRumConfig` has two required fields — `apiKey` and `endpoint`.
Every other field has a documented default tuned for production use.

| Field                          | Type                                | Default                              | Purpose |
|--------------------------------|-------------------------------------|--------------------------------------|---------|
| `apiKey`                       | `String`                            | —                                    | Sent as `X-API-Key`. Must start with `"edge_"`. |
| `endpoint`                     | `URL`                               | —                                    | Collector base URL. SDK appends `/collector/telemetry`. `https://` unless `debug == true`. |
| `appName`                      | `String?`                           | `nil`                                | Emitted as `app.name`. |
| `appVersion`                   | `String?`                           | `nil`                                | Emitted as `app.version`. |
| `appPackage`                   | `String?`                           | `nil`                                | Emitted as `app.package_name`. |
| `appBuild`                     | `String?`                           | `nil`                                | Emitted as `app.build_number`. |
| `environment`                  | `Environment?`                      | `nil`                                | `.production` / `.staging` / `.development`. |
| `location`                     | `String?`                           | `nil`                                | Batch envelope `location`, e.g. `"Nairobi/Kenya"`. |
| `resolveLocation`              | `Bool`                              | `false`                              | Opt-in IP geo. Calls `locationProviderUrl`, caches for 24h. |
| `locationProviderUrl`          | `URL?`                              | `https://ipapi.co/json/`             | Used only when `resolveLocation == true`. |
| `sampleRate`                   | `Double`                            | `1.0`                                | Per-session sample rate. `0.0`–`1.0`. |
| `ignoreUrls`                   | `[NSRegularExpression]`             | `[]`                                 | HTTP captures matching any regex are dropped. |
| `maxQueueSize`                 | `Int`                               | `200`                                | Offline-queue cap (events). |
| `flushInterval`                | `TimeInterval`                      | `5.0`                                | Soft flush timer (seconds). |
| `batchSize`                    | `Int`                               | `30`                                 | Max events per batch payload. |
| `sanitizeUrl`                  | `(@Sendable (URL) -> URL)?`         | `nil`                                | Sync redactor for every captured URL. |
| `captureNativeCrashes`         | `Bool`                              | `true`                               | Register PLCrashReporter. |
| `enableHangDetection`          | `Bool`                              | `true`                               | Register runloop watchdog. |
| `hangTimeout`                  | `TimeInterval`                      | `5.0`                                | Hang threshold (seconds). |
| `captureScreens`               | `Bool`                              | `true`                               | UIKit screen-entry / dwell swizzle. |
| `captureHTTP`                  | `Bool`                              | `true`                               | URLSession capture. |
| `captureTaps`                  | `Bool`                              | `true`                               | Top-level tap capture. |
| `captureRenderingPerformance`  | `Bool`                              | `true`                               | Frame / memory / long-task samplers. |
| `captureLifecycle`             | `Bool`                              | `true`                               | Foreground / background transitions. |
| `captureNetworkChanges`        | `Bool`                              | `true`                               | `NWPathMonitor` events. |
| `capturePageLoad`              | `Bool`                              | `true`                               | Single `page_load` per process. |
| `debug`                        | `Bool`                              | `false`                              | Verbose `os_log` diagnostics; relaxes URL validation. |

See [`Sources/EdgeRum/EdgeRumConfig.swift`](Sources/EdgeRum/EdgeRumConfig.swift)
for the full field declarations.

## What gets captured automatically

Once `EdgeRum.start(_:)` runs, the capture stack arms itself without
any per-call code. Each one is independently togglable on the config.

- **Screens.** UIKit `viewDidAppear` emits `navigation`; the paired
  `viewWillDisappear` emits a `screen.duration` metric. Container view
  controllers are skipped. SwiftUI screens emit the same shape via
  `.edgeRumScreen(_:)` and via `UIHostingController` auto-detection.
- **HTTP.** Every `URLSession` request emits `http.request` and a
  companion `resource_timing` metric. The SDK's own POSTs are filtered
  out three ways. Background URLSession traffic is not instrumented.
- **Taps.** `UIWindow.sendEvent` swizzle emits `user.interaction` once
  per `.ended` touch. Secure text fields are never recorded.
- **Performance samplers.** Per-second frame render times, ten-second
  memory polls plus pressure transitions, and `long_task` for any
  main-thread segment ≥ 50 ms.
- **Lifecycle.** `app_lifecycle` events on every state transition;
  background transitions force an immediate flush.
- **Connectivity.** `network_change` events fed by `NWPathMonitor`.
- **Page load.** One `page_load` per process, from launch instant to
  first frame after `.active`.
- **Native crashes.** PLCrashReporter with replay on next launch — the
  emitted `app.crash` carries the **previous** session's identity.
- **Hangs.** Runloop watchdog emits `app.crash` with `cause = "Hang"`
  for any main-thread stall longer than `hangTimeout`.

## Recipes

Each recipe is one short example showing the typical call shape. The
matching DocC article under [`EdgeRum.docc/Recipes/`](Sources/EdgeRum/EdgeRum.docc/Recipes)
goes deeper.

### Identify a user

```swift
import EdgeRum

func recipeIdentify() {
    EdgeRum.identify(UserContext(
        id: "u_42",
        name: "Ada Lovelace",
        email: "ada@example.com"
    ))
}
```

### Track a custom event

```swift
import EdgeRum

func recipeTrack() {
    EdgeRum.track("checkout_started", attributes: [
        "cart.size": 3,
        "cart.total": 49.95,
        "user.is_member": true,
        "ab.bucket": "treatment"
    ])
}
```

### Time an operation

```swift
import EdgeRum

func recipeTime(perform: (@escaping () -> Void) -> Void) {
    let timer = EdgeRum.time("checkout.submit")
    perform {
        timer.end(attributes: ["payment.method": "card"])
    }
}
```

### Capture a handled error

```swift
import EdgeRum

func recipeCaptureError(_ submit: () throws -> Void) {
    do {
        try submit()
    } catch {
        EdgeRum.captureError(error, context: ["payment.method": "card"])
    }
}
```

### Track a SwiftUI screen

```swift
import SwiftUI
import EdgeRum

struct RecipeSwiftUIScreen: View {
    var body: some View {
        Text("Checkout")
            .edgeRumScreen("Checkout", attributes: ["funnel.step": 3])
    }
}
```

### Track a UIKit screen manually

```swift
import EdgeRum

func recipeManualScreen() {
    EdgeRum.trackScreen("ManualScreen", attributes: ["funnel.step": 3])
}
```

### Sanitise URLs

```swift
import EdgeRum

func recipeSanitize() {
    var config = EdgeRumConfig(
        apiKey: "edge_live_abc123",
        endpoint: URL(string: "https://collect.example.com")!
    )
    config.sanitizeUrl = { url in
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        c.queryItems = c.queryItems?.map { item in
            item.name == "auth_token"
                ? URLQueryItem(name: item.name, value: "REDACTED")
                : item
        }
        return c.url ?? url
    }
    EdgeRum.start(config)
}
```

### Ignore certain URLs

```swift
import Foundation
import EdgeRum

func recipeIgnoreUrls() throws {
    let noisy = try NSRegularExpression(
        pattern: #"^https?://noisy\.example\.com/"#
    )
    var config = EdgeRumConfig(
        apiKey: "edge_live_abc123",
        endpoint: URL(string: "https://collect.example.com")!
    )
    config.ignoreUrls = [noisy]
    EdgeRum.start(config)
}
```

### Opt out of HTTP capture

```swift
import EdgeRum

func recipeDisableHTTPCapture() {
    var config = EdgeRumConfig(
        apiKey: "edge_live_abc123",
        endpoint: URL(string: "https://collect.example.com")!
    )
    config.captureHTTP = false
    EdgeRum.start(config)
}
```

### Disable / enable at runtime

```swift
import EdgeRum

func recipeRuntimeToggle() {
    EdgeRum.disable()   // pause capture and emission
    EdgeRum.enable()    // resume; also drains the offline queue
}
```

### Wire background flush

```swift
import UIKit
import EdgeRum

final class RecipeBackgroundFlushAppDelegate: UIResponder, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        EdgeRum.handleBackgroundEvents(
            identifier: identifier,
            completion: completionHandler
        )
    }
}
```

## What gets sent

Every batch is a JSON `telemetry_batch` envelope. A complete reference
batch — `navigation`, `screen.duration`, `http.request`, and two
metrics — lives at [`docs/payload-example.jsonc`](docs/payload-example.jsonc).
The schema for every attribute is in
[`docs/payload-schema.json`](docs/payload-schema.json).

Excerpt:

```json
{
  "type": "telemetry_batch",
  "timestamp": "2026-06-14T10:30:00.512Z",
  "location": "Nairobi/Kenya",
  "batch_size": 1,
  "events": [
    {
      "type": "event",
      "eventName": "navigation",
      "timestamp": "2026-06-14T10:30:00.123Z",
      "attributes": {
        "app.name": "Shop",
        "device.platform": "ios",
        "session.id": "session_1717234870002_ff009988aabbccdd_ios",
        "sdk.platform": "ios-native",
        "navigation.screen": "CartViewController"
      }
    }
  ]
}
```

Every value in `attributes` is a JSON primitive — `string`, `int`,
`double`, or `bool`. The `AttributeValue` sealed enum enforces this
constraint at compile time, so it cannot be violated from Swift.

## Privacy and App Store

- **IDFA-free.** No `AdSupport` import, no
  `ASIdentifierManager.advertisingIdentifier` read.
- **ATT-neutral.** `ATTrackingManager.requestTrackingAuthorization` is
  never called.
- **Privacy manifest.** [`PrivacyInfo.xcprivacy`](Sources/EdgeRum/Resources/PrivacyInfo.xcprivacy)
  declares every restricted-reason API the SDK uses:
  file timestamps (`C617.1`), system boot time (`35F9.1`),
  disk space (`E174.1`), UserDefaults (`CA92.1`). See
  [PLAN-iOS.md §10.4](PLAN-iOS.md) for the policy mapping.
- **Identifiers.** All three identifiers (`device.id`, `session.id`,
  `user.id`) are SDK-owned 8-byte `SecRandomCopyBytes` values stored
  locally only. iCloud Keychain is not used; on modern iOS a Keychain
  wipe at uninstall is the norm, so `device.id` rotates on reinstall.

## Versioning and stability

- **SemVer.** Strict — major / minor / patch carry their spec meanings.
- **Public API additions** ship as minor releases.
- **Public API removals and signature changes** are major.
- **Minimum-iOS bumps are major.** A consumer on iOS 14 will never wake
  up to a minor that won't compile.
- **Wire-format-affecting changes** are major, coordinated with the
  backend.
- **Deprecation policy** — one full minor cycle of
  `@available(*, deprecated, …)` warnings before any removal.

The DocC `Stability` article goes into the policy in more depth.

## Troubleshooting

| Symptom | Most likely cause |
|---------|-------------------|
| *I don't see any events.* | Enable `config.debug = true`, watch Console.app filtered to `com.edge.rum`. Check the `X-API-Key` starts with `"edge_"` and that the endpoint is reachable. |
| *App Store rejected my upload over privacy manifests.* | Confirm Xcode merged `Sources/EdgeRum/Resources/PrivacyInfo.xcprivacy` into the app bundle. XCFramework consumers may need to copy the file in by hand. |
| *My HTTP requests aren't being captured.* | Check the URLSession isn't a background session — `URLSessionConfiguration.background(withIdentifier:)` traffic is not instrumented. |
| *A crash event arrived without the previous session id.* | Confirm the crash sidecar at `Library/Caches/edge-rum/last-session.json` is being written; the path requires standard `Caches` read/write permission. |
| *Cold start feels slow on iPhone SE 2.* | Expected; see [PLAN-iOS.md §11.5](PLAN-iOS.md) for the device-tier budget. `start()` returns synchronously; the heavy bootstrap runs off the main thread. |

## FAQ

**Why no Web Vitals (LCP / FCP / CLS / INP / TTFB)?**
iOS has no native analogue. The SDK ships the equivalent native
signals — `page_load`, `frame_render_time`, `long_task` — that the
EdgeRum dashboards understand.

**Can I use this in an extension?**
Yes. Use the `EdgeRumStatic` SwiftPM product so the SDK links
statically; the extension's `EdgeRumConfig.appPackage` should be the
extension's bundle id so events route correctly.

**Does this collect IDFA?**
No. `AdSupport` is not imported anywhere in the SDK.

**Why doesn't it require ATT?**
The SDK does not access cross-app tracking identifiers and does not
share data with third parties for the purposes that trigger ATT. The
backend collector you point `endpoint` at receives the data; nothing
else does.

**Can I forward events to a third-party backend?**
Not from this SDK. The wire format is the EdgeRum collector's contract
— the same contract the web and Android SDKs implement. A forwarder to
an unrelated backend would be a different product.

**What's the supported-iOS commitment?**
iOS 14.0 minimum until v2. Any floor bump is a major release with a
migration guide ([`docs/migration/`](docs/migration)) describing the
host-app implications.

## Migrating to a new major version

When v2 lands, a migration guide based on
[`docs/migration/TEMPLATE.md`](docs/migration/TEMPLATE.md) will live at
`docs/migration/v1-to-v2.md`. The template — and the section header
here — stay in place for muscle memory across releases.

## Contributing and license

Contributions are tracked through the GitHub issue and PR workflow.
The contributor guide for AI-assisted development is [`CLAUDE.md`](CLAUDE.md);
the architectural plan is [`PLAN-iOS.md`](PLAN-iOS.md); architecture
decision records live in [`docs/decisions.md`](docs/decisions.md).

License is TBD pending the project ticket; the section header stays
here so it lands in the released README without a structural diff.

## Design docs

| Doc | What it covers |
|-----|----------------|
| [`PLAN-iOS.md`](PLAN-iOS.md) | The full feature plan F1 → F23, milestones, acceptance criteria, per-task references. Authoritative for scope. |
| [`docs/data-flow.md`](docs/data-flow.md) | End-to-end data flow from capture call to backend ingest. Internal — references the internal architecture by name. |
| [`docs/decisions.md`](docs/decisions.md) | Architectural Decision Records (ADR-001 onward). |
| [`docs/payload-example.jsonc`](docs/payload-example.jsonc) | Reference batch payload — what the SDK actually ships on the wire. |
| [`CHANGELOG.md`](CHANGELOG.md) | Release notes. |
| [`Sources/EdgeRum/EdgeRum.docc/`](Sources/EdgeRum/EdgeRum.docc) | DocC catalog — API reference plus the same recipes as above in Xcode-native form. |
