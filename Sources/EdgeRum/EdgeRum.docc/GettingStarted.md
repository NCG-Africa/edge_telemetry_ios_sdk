# Getting started

Integrate EdgeRum in under ten minutes — install the package, call
``EdgeRum/start(_:)`` once at launch, and confirm events land in the
backend.

## Overview

Pick one of the installation channels, drop the start call into your
app's launch hook, and you're done. The capture stack arms itself
automatically; nothing else has to be wired by hand except the optional
background-flush forwarder.

## Install

EdgeRum ships through three channels — pick the one that matches the
host project.

### Swift Package Manager (recommended)

Add the package to your `Package.swift`:

```swift-skip
dependencies: [
    .package(url: "https://github.com/NCG-Africa/edge_telemetry_ios_sdk.git",
             from: "1.0.0-alpha.1")
]
```

Then add the `EdgeRum` product to your app target:

```swift-skip
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "EdgeRum", package: "edge-rum-ios")
    ]
)
```

For app extensions that need static linking, use the `EdgeRumStatic`
product instead.

### CocoaPods

```ruby
pod 'EdgeRum', '~> 1.0.0-alpha.1'
```

### XCFramework

Drop the prebuilt `EdgeRum.xcframework` from the latest GitHub Release
into your project, embed it in the app target, and you're set.

## Start the SDK

You start the SDK exactly once — at the app's earliest launch hook.
Three variants below cover the common app shells.

### UIKit — AppDelegate

```swift
import UIKit
import EdgeRum

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

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

### UIKit — SceneDelegate

```swift
import UIKit
import EdgeRum

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

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

@main
struct ShopApp: App {
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
            ContentView()
                .edgeRumScreen("Home")
        }
    }
}
```

## Verify

Switch on diagnostic logging during the integration cycle by setting
`config.debug = true`. The SDK will then log every batch flush, every
swizzle install, and any backend retry decision through `os_log` under
the `com.edge.rum` subsystem. Filter by that subsystem in Console.app to
watch events flow.

The first batch lands at the first flush tick (`flushInterval`, default
five seconds) or when the in-memory buffer reaches `batchSize`
(default 30), whichever comes first.

## What's next

- <doc:Configuration> — the rest of ``EdgeRumConfig`` and what each
  knob does.
- <doc:Captures> — the auto-captures armed by `start(_:)`.
- <doc:Privacy> — what the SDK touches, what it never touches, and how
  to satisfy App Review.
