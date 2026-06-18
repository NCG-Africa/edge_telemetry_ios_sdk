# ``EdgeRum``

@Metadata {
    @DisplayName("EdgeRum")
}

Native Real User Monitoring for iOS — performance data, errors, native
crashes, hangs, network requests, and user interactions shipped as JSON
to the EdgeRum backend used by the web and Android SDKs.

## Overview

`EdgeRum` is the iOS sibling of the web and Android EdgeRum SDKs. One
`start(_:)` call from the host app's launch path turns on the full
capture stack — screens, taps, HTTP, frame render times, memory, hangs,
native crashes, lifecycle, connectivity, page load — and ships everything
as JSON to a single collector endpoint. The public Swift surface uses
only EdgeRum-native vocabulary, no compression or binary framing is
used on the wire, and no IDFA or ATT is touched.

> Performance budget: `start(_:)` returns synchronously; the heavy
> bootstrap is dispatched off the main thread. The first POST happens
> at the first flush tick, never inside `start(_:)`.

```swift
import EdgeRum

EdgeRum.start(EdgeRumConfig(
    apiKey: "edge_live_abc123",
    endpoint: URL(string: "https://collect.example.com")!
))
EdgeRum.track("checkout_started", attributes: [
    "cart.size": 3,
    "cart.total": 49.95
])
```

The 5-minute integration walkthrough lives in <doc:GettingStarted>;
recipes for the common host-app patterns are listed below.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:Configuration>
- <doc:Captures>

### Core API

- ``EdgeRum/start(_:)``
- ``EdgeRum/identify(_:)``
- ``EdgeRum/track(_:attributes:)``
- ``EdgeRum/trackScreen(_:attributes:)``
- ``EdgeRum/time(_:)``
- ``EdgeRum/captureError(_:context:)``

### Lifecycle

- ``EdgeRum/disable()``
- ``EdgeRum/enable()``
- ``EdgeRum/handleBackgroundEvents(identifier:completion:)``

### Read-only state

- ``EdgeRum/sessionId``
- ``EdgeRum/deviceId``
- ``EdgeRum/isEnabled``
- ``EdgeRum/sdkVersion``

### Configuration types

- ``EdgeRumConfig``
- ``Environment``
- ``UserContext``
- ``RumTimer``

### SwiftUI

- ``SwiftUICore/View/edgeRumScreen(_:attributes:)``
- ``SwiftUICore/View/edgeRumTrackTap(_:attributes:)``

### Recipes

- <doc:IdentifyUser>
- <doc:TrackCustomEvent>
- <doc:TimeOperation>
- <doc:CaptureError>
- <doc:SanitizeURLs>
- <doc:BackgroundFlush>

### Privacy and stability

- <doc:Privacy>
- <doc:Stability>
