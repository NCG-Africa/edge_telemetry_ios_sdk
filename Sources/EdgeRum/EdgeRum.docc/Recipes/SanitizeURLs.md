# Sanitise URLs

Strip query parameters, redact path segments, and ignore noisy hosts
from captured HTTP traffic.

## Overview

EdgeRum's HTTP capture records the full URL of every outgoing
`URLSession` request. Two ``EdgeRumConfig`` hooks let you filter and
redact what lands in the data:

- ``EdgeRumConfig/sanitizeUrl`` — synchronous closure run on the
  caller's thread for every captured URL. Return the redacted variant.
- ``EdgeRumConfig/ignoreUrls`` — `NSRegularExpression` array; any URL
  matching one of these is dropped silently and never reported.

## Strip tokens from query strings

```swift
import EdgeRum

var config = EdgeRumConfig(
    apiKey: "edge_live_abc123",
    endpoint: URL(string: "https://collect.example.com")!
)
config.sanitizeUrl = { url in
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        return url
    }
    components.queryItems = components.queryItems?.map { item in
        switch item.name {
        case "auth_token", "session_token", "signature":
            return URLQueryItem(name: item.name, value: "REDACTED")
        default:
            return item
        }
    }
    return components.url ?? url
}
EdgeRum.start(config)
```

The sanitised URL is reflected on both the `http.request` event and
the companion `resource_timing` metric so dashboards stay consistent
across both signals.

## Drop traffic to a noisy host

```swift
import EdgeRum

let analyticsHost = try NSRegularExpression(
    pattern: #"^https?://noisy\.analytics\.example\.com/"#
)
var config = EdgeRumConfig(
    apiKey: "edge_live_abc123",
    endpoint: URL(string: "https://collect.example.com")!
)
config.ignoreUrls = [analyticsHost]
EdgeRum.start(config)
```

## Disabling HTTP capture entirely

If you do not want any HTTP traffic captured, set
``EdgeRumConfig/captureHTTP`` to `false`. The SDK will skip the
URLProtocol install entirely; consumer-created `URLSession`s carry on
without any delegate shim.
