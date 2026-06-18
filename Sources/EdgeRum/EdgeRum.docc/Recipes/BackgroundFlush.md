# Wire background flush

Forward the system's background-URLSession callback so EdgeRum can
finish pending uploads after the host app suspends.

## Overview

EdgeRum batches events and ships them on a separately-configured
background `URLSessionConfiguration`. When iOS suspends the host app
mid-upload, the OS re-launches the app in the background to finish the
transfer and routes the completion through
`application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
The host has to forward that callback to the SDK — there is no way for
the SDK to intercept it from a framework target.

This is the **one** wire-up step beyond ``EdgeRum/start(_:)`` for hosts
that want bulletproof delivery.

## UIKit AppDelegate

```swift
import UIKit
import EdgeRum

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

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

## SceneDelegate / SwiftUI

The system invokes the background-events callback on `UIApplicationDelegate`
even in SwiftUI / scene-based apps. The pattern is the same: declare an
`AppDelegate` adaptor (SwiftUI: `@UIApplicationDelegateAdaptor`) and
forward from there.

```swift
import SwiftUI
import EdgeRum

@main
struct ShopApp: App {
    @UIApplicationDelegateAdaptor(BackgroundFlushAdaptor.self) private var adaptor

    init() {
        var config = EdgeRumConfig(
            apiKey: "edge_live_abc123",
            endpoint: URL(string: "https://collect.example.com")!
        )
        EdgeRum.start(config)
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

final class BackgroundFlushAdaptor: NSObject, UIApplicationDelegate {
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

## What happens if you skip it

Without the forwarder, background uploads still complete — the system
just doesn't get the ack, so it stops granting the host app extra
background windows. The next foreground flush replays anything that
landed in the offline queue, so no events are lost; the delivery
latency simply degrades to "next foreground" instead of "real time".
