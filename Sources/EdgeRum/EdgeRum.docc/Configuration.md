# Configuration

Tune the SDK's behaviour with ``EdgeRumConfig`` — sampling, buffering,
URL sanitisation, capture toggles, and diagnostic logging.

## Overview

``EdgeRumConfig`` is the single configuration entry point passed to
``EdgeRum/start(_:)``. Only ``EdgeRumConfig/apiKey`` and
``EdgeRumConfig/endpoint`` are required; every other field ships with a
documented default tuned for production use.

```swift
var config = EdgeRumConfig(
    apiKey: "edge_live_abc123",
    endpoint: URL(string: "https://collect.example.com")!
)
config.appName = "Shop"
config.appVersion = "2.1.0"
config.environment = .production
config.sampleRate = 0.5
config.flushInterval = 10.0
EdgeRum.start(config)
```

## Identity

``EdgeRumConfig/apiKey`` must start with the literal `"edge_"` prefix
and is sent as the `X-API-Key` request header. ``EdgeRumConfig/endpoint``
is the collector base URL; the SDK appends the `/collector/telemetry`
path automatically. `https://` is required unless
``EdgeRumConfig/debug`` is `true`.

``EdgeRumConfig/appName``, ``EdgeRumConfig/appVersion``,
``EdgeRumConfig/appPackage``, ``EdgeRumConfig/appBuild``, and
``EdgeRumConfig/environment`` populate the `app.*` attributes on every
event. Setting them explicitly lets the SDK report a stable identity
even before the bundle's `Info.plist` is fully consulted.

## Sampling and buffering

``EdgeRumConfig/sampleRate`` is per-session, decided once at session
start. The forced-emit set — `session.started`, `session.finalized`,
`app.crash`, `network_change` — always emits regardless.

``EdgeRumConfig/flushInterval`` (seconds) and
``EdgeRumConfig/batchSize`` (events) gate normal flushes — whichever
fires first. Errors and session-finalize events always flush
immediately.

``EdgeRumConfig/maxQueueSize`` caps the offline queue at 200 events by
default. Overflow drops the oldest file first.

## URL sanitisation

``EdgeRumConfig/ignoreUrls`` is an array of `NSRegularExpression` — any
captured HTTP request whose URL matches one of them is dropped silently.

``EdgeRumConfig/sanitizeUrl`` is a synchronous closure invoked on the
caller thread for every captured URL. Return a redacted variant — strip
query parameters, replace tokens, redact path segments. The sanitised
URL is reflected on both the `http.request` event and the companion
`resource_timing` metric so dashboards stay consistent.

## Location

``EdgeRumConfig/location`` sets the batch envelope's `location` field
to a literal `"City/Country"` string. Set ``EdgeRumConfig/resolveLocation``
to `true` to let the SDK call ``EdgeRumConfig/locationProviderUrl``
once at startup and cache the result for 24 hours in `UserDefaults`.

> Note: `resolveLocation = true` sends the device IP to a third party
> (default `https://ipapi.co/json/`). Disable it or supply your own
> provider to keep traffic on your infrastructure.

## Capture toggles

Each of the auto-captures can be turned off individually for hosts
that only want a subset of the signals:

- ``EdgeRumConfig/captureScreens`` — UIKit screen entry/exit swizzle.
- ``EdgeRumConfig/captureHTTP`` — `URLSession` capture.
- ``EdgeRumConfig/captureTaps`` — top-level tap capture.
- ``EdgeRumConfig/captureRenderingPerformance`` — frame render time,
  memory, long-task samplers.
- ``EdgeRumConfig/captureLifecycle`` — foreground / background / will-
  terminate transitions.
- ``EdgeRumConfig/captureNetworkChanges`` — `NWPathMonitor` events.
- ``EdgeRumConfig/capturePageLoad`` — single per-process page-load
  event.
- ``EdgeRumConfig/captureNativeCrashes`` — PLCrashReporter integration.
- ``EdgeRumConfig/enableHangDetection`` — main-thread runloop watchdog.

``EdgeRumConfig/hangTimeout`` sets the watchdog threshold; the default
is 5.0 seconds.

## Diagnostics

``EdgeRumConfig/debug`` switches the SDK into verbose `os_log` mode and
relaxes URL validation to accept `http://` endpoints. Leave it `false`
in production. Watch the logs by filtering Console.app to the
`com.edge.rum` subsystem.
