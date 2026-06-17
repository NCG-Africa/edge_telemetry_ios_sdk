# What gets captured automatically

Everything ``EdgeRum/start(_:)`` arms without per-call code — screens,
taps, HTTP, frame render times, memory, hangs, native crashes,
lifecycle, connectivity, and the single page-load event.

## Overview

EdgeRum's captures cover the signals the EdgeRum dashboards depend on
out of the box. Each one is independently togglable on
``EdgeRumConfig``; every one of them is installed exactly once on the
main thread when ``EdgeRum/start(_:)`` runs.

## Navigation

UIKit screen entries produce a `navigation` event; paired exits produce
a `screen.duration` performance metric. The capture is installed on the
base `UIViewController`, so every subclass inherits it.

Container view controllers — `UINavigationController`,
`UITabBarController`, `UIPageViewController` — are skipped; the
contained controller's `viewDidAppear` is what counts. Screen names
prefer the controller's `accessibilityIdentifier` (stable across class
renames), falling back to the reflected type name.

SwiftUI screens emit the same wire shape through the
`View.edgeRumScreen(_:attributes:)` modifier, tagged with
`navigation.kind = "swiftui"`. SwiftUI screens routed through
`UIHostingController` are also detected automatically.

Opt out via ``EdgeRumConfig/captureScreens``.

## HTTP

Every outgoing `URLSession` request emits an `http.request` event and a
companion `resource_timing` metric — no per-call code required.
`URLSession.shared` and consumer-created `URLSession(configuration:
.default, delegate:, ...)` flows are both intercepted at the protocol
layer; the SDK never wraps or replaces your delegate.

What's captured: `http.method`, `http.url`, `http.host`, `http.path`,
`http.status_code`, `http.duration_ms`, `http.request_size`,
`http.response_size`, `http.from_cache`, and `http.error` (only on
failure). The companion `resource_timing` metric carries
`resource.dns_ms`, `resource.connect_ms`, `resource.tls_ms`,
`resource.ttfb_ms`, and `resource.response_ms` derived from
`URLSessionTaskMetrics`.

Background URLSession traffic is **not** instrumented — the OS provides
no in-process delegate window for `URLSessionTaskMetrics`, so emitting
an `http.request` without a timing companion would be misleading.

The SDK's own POSTs are filtered out three ways: an
`X-Edge-Rum-Internal` header, a task description marker, and a host-
prefix check against the configured collector endpoint.

Opt out via ``EdgeRumConfig/captureHTTP``. Use
``EdgeRumConfig/ignoreUrls`` and ``EdgeRumConfig/sanitizeUrl`` to
filter or redact what is captured.

## Tap interactions

Every completed UIKit tap produces a `user.interaction` event. The
capture is installed on the base `UIWindow.sendEvent(_:)` so every
subclass inherits it, and emits exactly once per `.ended` touch.

What's captured: `interaction.kind`, `interaction.target` (the
reflected class name of the resolved target view), `interaction.target_id`
(the `accessibilityIdentifier`, or for `UIButton` the current title),
and `interaction.screen` (the current screen name from the navigation
pointer; omitted when no screen has appeared yet).

Secure-entry text fields are never recorded — if the tap's responder
chain reaches a `UITextField` with `isSecureTextEntry == true`, the
event is silently dropped. The capture path never reads `.text` from any
view.

SwiftUI taps go through the `View.edgeRumTrackTap(_:attributes:)`
modifier and emit the same wire shape.

Opt out via ``EdgeRumConfig/captureTaps``.

## Performance samplers

Three independent samplers emit `metric` items on a steady cadence:

- **`frame_render_time`** — a `CADisplayLink` attached to the main
  runloop's `.common` modes feeds a one-second window aggregator. Each
  window emits `frame.max_ms`, `frame.p95_ms`, `frame.dropped_count`,
  `frame.target_hz`, `frame.source = "displaylink"`, and
  `value = frame.max_ms`. The display link pauses on `willResignActive`
  and resumes on `didBecomeActive`.
- **`memory_usage`** — a `DispatchSourceTimer` polls
  `mach_task_basic_info` (RSS, virtual) and `task_vm_info`
  (`phys_footprint`) every ten seconds; in parallel a
  `DispatchSource.makeMemoryPressureSource(eventMask: .all)` emits an
  out-of-band sample tagged `memory.pressure ∈ "normal" / "warning" /
  "critical"` on every transition. All sizes in kB.
- **`long_task`** — a `CFRunLoopObserver` measures the interval between
  `.afterWaiting` and the next `.beforeWaiting`. Any work segment ≥ 50 ms
  emits a `long_task` metric with `value` (ms),
  `long_task.threshold_ms`, and a `long_task.stack` snapshot
  (truncated to 4 KiB).

Opt out via ``EdgeRumConfig/captureRenderingPerformance``.

## Lifecycle and connectivity

`app_lifecycle` events fire on every transition between `foregrounded`,
`active`, `inactive`, `backgrounded`, and `will_terminate`. Background
transitions also force an immediate flush so the in-memory buffer is
shipped before the OS suspends the process.

`network_change` events fire on every `NWPathMonitor` transition, carrying
`network.type`, `network.effectiveType`, `network.is_expensive`,
`network.is_constrained`, and (iOS 14.2+) `network.unsatisfied_reason`.

Opt out via ``EdgeRumConfig/captureLifecycle`` and
``EdgeRumConfig/captureNetworkChanges``.

## Page load

One `page_load` event per process — measured from the SDK's earliest
observable launch instant to the first `CADisplayLink` tick after the
app reaches `.active`. On iOS 15+ the event reports prewarmed launches
via `page_load.prewarmed`.

Opt out via ``EdgeRumConfig/capturePageLoad``.

## Native crashes and hangs

`PLCrashReporter` captures `SIGSEGV`, `SIGABRT`, `SIGBUS`, `SIGILL`,
and uncaught `NSException`. The replay-on-next-launch path reads a
crash sidecar at `Library/Caches/edge-rum/last-session.json` so the
emitted `app.crash` carries the **previous** session's identity, not
the current one.

The hang watchdog observes `CFRunLoopObserver` activity on the main
runloop; any work segment longer than ``EdgeRumConfig/hangTimeout``
(default 5.0 s) emits an `app.crash` with `cause = "Hang"`,
`runtime = "native"`, and a best-effort stack snapshot. Hangs are not
fatal — they sit alongside the `long_task` metric for the steady-state
samplers and the fatal `app.crash` events for PLCR.

Opt out via ``EdgeRumConfig/captureNativeCrashes`` and
``EdgeRumConfig/enableHangDetection``.
