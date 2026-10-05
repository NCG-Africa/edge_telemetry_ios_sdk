# Changelog

All notable changes to **edge-rum-ios** are recorded here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Versioning and stability commitments — including the rule that any
minimum-iOS bump is a major version — are documented in the
[README](README.md#versioning-and-stability) and
[DocC `Stability` article](Sources/EdgeRum/EdgeRum.docc/Stability.md).

---

## [1.4.0-alpha.2](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/compare/v1.3.0-alpha.2...v1.4.0-alpha.2) (2026-10-05)


### Features

* **F35:** radio generation — RUM coverage tranche 10 ([#241](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/241)) ([96ddfce](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/commit/96ddfceb92df4dda6354fec4412533e36fbaad04))

## [1.3.0-alpha.2](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/compare/v1.2.0-alpha.2...v1.3.0-alpha.2) (2026-10-05)


### Features

* **F29:** breaking batch — RUM coverage tranche 4 ([#234](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/234)) ([5bf60b9](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/commit/5bf60b93c2a98397c0e43d172048c69eb53156fc))
* **F30:** sampler cut — RUM coverage tranche 5 ([#235](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/235)) ([4002028](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/commit/4002028bc68c6a9ed9dce45390631475107aed90))
* **F31:** breadcrumbs — RUM coverage tranche 6 ([#236](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/236)) ([672781d](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/commit/672781df0c7a4e9cdd89426a9b9721bf369fc88a))
* **F32:** SDK health — RUM coverage tranche 7 ([#237](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/237)) ([94e5aef](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/commit/94e5aefb4ac00555bcf4e63d8ba0c005bdf9af1e))
* **F33:** error evidence + two-phase hang — RUM coverage tranche 8 ([#238](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/238)) ([d737b29](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/commit/d737b2944e6a1ac7bfbb5131732a8bc45f362a10))
* **F34:** launch — RUM coverage tranche 9 ([#239](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/239)) ([b2717d8](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/commit/b2717d8f2061f57a672653bd4bc60266f199dac4))

## [1.2.0-alpha.2](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/compare/v1.1.0-alpha.2...v1.2.0-alpha.2) (2026-10-05)


### Features

* **F27:** privacy — clearUser, resetIdentity, identity off sidecar, button_title opt-in ([#231](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/231)) ([887c4ef](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/commit/887c4efd50a74c006d0939f9fbe465119e1ffec7))
* **F28:** riders + screen attribution — RUM coverage tranche 3 ([#233](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/233)) ([3bccfc0](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/commit/3bccfc020a94af6a70068e772cc01ddb9dc5b63c)), closes [#215](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/215)

## [1.1.0-alpha.2](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/compare/1.0.0-alpha.2...v1.1.0-alpha.2) (2026-10-05)


### Features

* **F25:** hot path — O1 sidecar inversion, sdk.thread_time_ms, consent guard ([#212](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/212)) ([#228](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/228)) ([7f9102b](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/commit/7f9102b3022bb6dcb896e43abeae86222772b848))
* **F26:** doc-truth — flushInterval timer, event-count queue cap, hang.cpu_usage ([#230](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/230)) ([fadbdbf](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/commit/fadbdbf159e590734fad3e0bf1504272dac0c39b))

## [Unreleased]

Nothing in this slot yet.

---

## [1.0.0-alpha.2] — 2026-06-24

Distribution fixes plus the testing & CI feature. No public API change,
no wire-format change.

### Added

- **F19 — Testing & CI.** Golden-batch snapshot test, crash UI test,
  three-slot iOS Simulator device matrix (`min` / `mid` / `new`),
  advisory performance budgets, and an `EdgeRumCore` line-coverage gate
  at ≥ 80 % (`Tools/check-edge-rum-core-coverage.sh`).

### Fixed

- **SwiftPM distribution.** `CrashReporter.xcframework` is now a
  `.binaryTarget` pointing at a GitHub release asset, so external
  consumers resolve the package without first running
  `Tools/fetch-plcrashreporter.sh`.
- **CocoaPods distribution.** The podspec installs: subspecs pinned to
  Swift 5.10, `static_framework`, `Internal-Crash` depends on the
  upstream `PLCrashReporter` pod, and `EdgeRumVersion.swift` is
  regenerated from `VERSION` via `prepare_command`.
- **CI.** Concurrent-install tests stabilized.

### Known limitations

- `PrivacyInfo.xcprivacy` is still the F1 stub — the restricted-reason
  declarations (`C617.1`, `35F9.1`, `E174.1`, `CA92.1`) land with F20.
  Host apps must declare those reasons themselves until then.
- The `EdgeRumOTelBridge` target is not part of the CocoaPods
  distribution — upstream does not publish the OpenTelemetry pods.
- Carried over from alpha.1: background `URLSession` traffic is not
  instrumented; `device.id` rotates on reinstall; performance is
  unverified on hardware older than iPhone SE 2.

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
