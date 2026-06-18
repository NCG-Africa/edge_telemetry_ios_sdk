# Changelog

All notable changes to **edge-rum-ios** are recorded here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Versioning and stability commitments — including the rule that any
minimum-iOS bump is a major version — are documented in the
[README](README.md#versioning-and-stability) and
[DocC `Stability` article](Sources/EdgeRum/EdgeRum.docc/Stability.md).

---

## [Unreleased]

Nothing in this slot yet.

---

## [1.0.0-alpha.1] — 2026-06-17

First public alpha. Every feature in `PLAN-iOS.md` § F1 – F18 has
landed; the wire-contract envelope, identity model, capture stack, and
documentation surface are in place.

### Added

- **F1 — Package & build infrastructure.** `Package.swift` (dynamic +
  static products), `EdgeRum.podspec` (CocoaPods), `Tools/build-
  xcframework.sh` (XCFramework artefact), iOS 14 floor enforced by
  `Tools/check-supported-ios.sh`.
- **F2 — Public API surface.** `EdgeRum` namespace with `start`,
  `identify`, `track`, `trackScreen`, `time`, `captureError`, `enable`,
  `disable`, `sessionId`, `deviceId`, `isEnabled`,
  `handleBackgroundEvents`. `EdgeRumConfig`, `UserContext`,
  `AttributeValue` (sealed enum), `Environment`, `RumTimer`.
- **F3 — Recorder + envelope pipeline.** Single internal `Recorder`
  facade routes every public call through the JSON `telemetry_batch`
  envelope.
- **F4 — Persistent identity.** Keychain-backed `device.id`,
  UserDefaults-backed `session.id` and `user.id` in the documented
  `prefix_<epochMs>_<16 hex>_ios` format. 30-minute session inactivity
  window.
- **F5 — Transport.** `BatchTransport` over HTTPS to
  `POST /collector/telemetry`, `0/2/8/30 s` retry ladder, file-backed
  offline queue, background `URLSessionConfiguration` for post-
  suspension drain.
- **F6 — UIKit screen capture.** `viewDidAppear` /
  `viewWillDisappear` swizzle emits `navigation` events and paired
  `screen.duration` metrics.
- **F7 — SwiftUI screen capture.** `.edgeRumScreen` and
  `.edgeRumTrackTap` modifiers with the same wire shape as F6.
- **F8 — HTTP capture.** `URLProtocol` + delegate hooks emit
  `http.request` events and `resource_timing` metrics for every
  consumer `URLSession`, with the SDK's own POSTs filtered out three
  ways.
- **F9 — Tap capture.** `UIWindow.sendEvent` swizzle emits one
  `user.interaction` event per `.ended` touch; secure-entry fields are
  excluded by construction.
- **F10 — Continuous performance samplers.** `frame_render_time`
  (per-second CADisplayLink window), `memory_usage` (10 s polls +
  pressure transitions), and `long_task` (≥50 ms main-thread stalls).
- **F11 — Lifecycle + connectivity.** `app_lifecycle` events on every
  state transition; `network_change` events fed by `NWPathMonitor`.
- **F12 — Page load.** Single `page_load` event per process, from the
  earliest observable launch instant to the first `CADisplayLink` tick
  after `.active`.
- **F13 — `EdgeRum.time()` performance timer.** Idempotent
  `RumTimer.end()` / `cancel()` records a custom-metric `value` in ms.
- **F14 — PLCrashReporter integration.** Native-crash capture with
  replay-on-next-launch carrying the previous session's identity from
  the on-disk crash sidecar.
- **F15 — Hang detection.** `CFRunLoopObserver`-driven main-runloop
  watchdog emits `app.crash` with `cause = "Hang"` past the configured
  threshold.
- **F16 — Context-bag enrichment.** Thermal state, accessibility flags,
  `NWPath` extras, free storage, and locale folded into every event's
  identity attributes.
- **F17 — URLSession metrics enrichment.** TLS handshake, redirects,
  multi-transaction protocol negotiation captured on the
  `resource_timing` metric.
- **F18 — Documentation.** Final README, DocC catalog under
  `Sources/EdgeRum/EdgeRum.docc/`, three sample apps, migration
  template, doc-quality CI (`extract-readme-code.sh`,
  `check-links.sh`, `check-doc-coverage.sh`, DocC build check).

### Backend asks

Coordination items the EdgeTelemetryProcessor team must confirm before
this alpha leaves the staging environment are tracked in
[`PLAN-iOS.md` § 14](PLAN-iOS.md). The new `sdk.platform = "ios-native"`
value, the absence of Web Vital metrics, and the SwiftUI / hang event
shapes are all unchanged from the previously communicated proposals.

### Known limitations

- Background `URLSession` traffic is not instrumented (no in-process
  delegate window for `URLSessionTaskMetrics`).
- iCloud Keychain sharing is not enabled, so `device.id` rotates on
  reinstall on modern iOS unless the host app shares a keychain group.
- Performance is unverified on real hardware older than iPhone SE 2.
