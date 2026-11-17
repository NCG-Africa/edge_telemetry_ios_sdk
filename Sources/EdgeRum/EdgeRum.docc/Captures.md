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

UIKit screen entries produce a `navigation` event carrying
`navigation.to_screen`, `navigation.from_screen` and `navigation.method`
(`initial` for the first screen, then `push`, `pop`, `tab` or `unknown`).
Entering a different screen closes the previous visit with a
`screen.duration` event (`screen.name`, `screen.duration_ms`,
`screen.exit_method`). The capture is installed on the base
`UIViewController`, so every subclass inherits it.

Container view controllers — `UINavigationController`,
`UITabBarController`, `UIPageViewController` — are skipped; the
contained controller's `viewDidAppear` is what counts. Screen names
prefer the controller's `accessibilityIdentifier` (stable across class
renames), falling back to the reflected type name.

SwiftUI screens emit the same wire shape through the
`View.edgeRumScreen(_:attributes:)` modifier, tagged with
`navigation.route_type = "swiftui"`. SwiftUI screens routed through
`UIHostingController` are also detected automatically. Manual
``EdgeRum/trackScreen(_:attributes:)`` calls are tagged
`navigation.route_type = "manual"`.

Opt out via ``EdgeRumConfig/captureScreens``.

## HTTP

Every outgoing `URLSession` request emits an `http.request` event and a
companion `perf.resource_timing` metric — no per-call code required.
`URLSession.shared` and consumer-created `URLSession(configuration:
.default, delegate:, ...)` flows are both intercepted at the protocol
layer; the SDK never wraps or replaces your delegate.

What's captured: `http.method`, `http.host`, `http.path`,
`http.status_code`, `http.duration_ms`, `http.request_size`,
`http.response_size`, `http.from_cache`, and — only on failure —
`http.error_domain` (string) plus `http.error_code` (int). No full URL
or query string is sent; `http.path` is templated on device — a
segment holding a digit, or 32+ characters long, becomes `{id}`. The companion `perf.resource_timing` metric carries
`resource.host`, `resource.dns_ms`, `resource.connect_ms`,
`resource.tls_ms`, `resource.ttfb_ms`, and `resource.download_ms`
derived from `URLSessionTaskMetrics`.

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

Every completed UIKit tap produces a `ui.interaction` event. The
capture is installed on the base `UIWindow.sendEvent(_:)` so every
subclass inherits it, and emits exactly once per `.ended` touch.

What's captured: `ui.type` (`tap`), `ui.view_class` (the
reflected class name of the resolved target view), `ui.target`
(the `accessibilityIdentifier`; a `UIButton`'s current title only when
``EdgeRumConfig/captureButtonTitles`` is `true`), and
`ui.name_source` (`accessibility_identifier`, `button_title`,
`host` for `edgeRumTrackTap`, or `none` when no label was sent). The
current screen rides on every event as `screen.name`.

Secure-entry text fields are never recorded — if the tap's responder
chain reaches a `UITextField` with `isSecureTextEntry == true`, the
event is silently dropped. The capture path never reads `.text` from any
view.

SwiftUI taps go through the `View.edgeRumTrackTap(_:attributes:)`
modifier and emit the same wire shape.

Opt out via ``EdgeRumConfig/captureTaps``.

## Performance samplers

Periodic sampling runs only while the app is active, Low Power Mode is
off and the thermal state is below `serious`. Gaps outside those
conditions are by design; memory-pressure transitions, hangs, crashes and
`perf.long_task` are never held back.

- **`frame.summary`** — a `CADisplayLink` runs only inside a
  *motion window*: a touch (began or ended) or a screen transition opens
  one, and it closes 2 s after the last such motion, 10 s at most. The
  link is paused otherwise, so static content never holds the display at
  its maximum refresh rate. Each window that saw frames emits one event
  with `frame.total_frames`, `frame.slow_frames` (frames skipped at the
  refresh rate the display is actually running), `frame.max_total_duration_ms`,
  `frame.p95_ms`, `display.refresh_rate`, `frame.window_duration_ms` (window
  length — normalise by it) and `frame.source = "displaylink"`.
- **`memory.usage`** — a `DispatchSourceTimer` polls
  `mach_task_basic_info` (RSS, virtual) and `task_vm_info`
  (`phys_footprint`) every 30 seconds; `memory.usage_mb` is the
  footprint in MB. In parallel a
  `DispatchSource.makeMemoryPressureSource(eventMask: .all)` sends a
  `memory.pressure` event on every transition, with
  `memory.pressure_level` `normal` or `critical` (an iOS memory warning
  is critical) and the same snapshot. The `memory.*_kb` attributes are
  in kB; a key is omitted when its kernel read fails.
- **`perf.cpu_usage`** — on the same 30-second tick, whole-process CPU since
  the previous tick as `value`, in per-core percent (one busy core is
  100, so values may exceed 100).
- **`perf.long_task`** — a `CFRunLoopObserver` measures the interval between
  `.afterWaiting` and the next `.beforeWaiting`. Any work segment ≥ 50 ms
  emits a `perf.long_task` metric with `value` (ms),
  `long_task.threshold_ms`, and a `long_task.stack` snapshot
  (truncated to 4 KiB; `long_task.stack.truncated` counts the bytes
  removed). Frames read `image +0x<offset> <hint>`;
  `long_task.binary_images` lists the referenced images (`name`,
  `uuid`) as a JSON string so offsets can be symbolicated.

Opt out via ``EdgeRumConfig/captureRenderingPerformance``.

## Lifecycle and connectivity

`app.lifecycle` events fire on every transition between `foregrounded`,
`active`, `inactive`, `backgrounded`, and `will_terminate`. Background
transitions also force an immediate flush so the in-memory buffer is
shipped before the OS suspends the process.

`network.change` events fire on every `NWPathMonitor` transition, carrying
`network.type`, `network.effective_type`, `network.expensive`,
`network.constrained`, and (iOS 14.2+) `network.unsatisfied_reason`.
On cellular, `network.effective_type` is the radio generation (`2g`–`5g`,
or `unknown`), and a radio handover alone also fires `network.change`.

Opt out via ``EdgeRumConfig/captureLifecycle`` and
``EdgeRumConfig/captureNetworkChanges``.

## Page load

One `app.start` event per process, `app.start.type = "cold"`.
`app.start.duration_ms` runs from process start to the first
`CADisplayLink` tick after the app reaches `.active`, on a monotonic
clock; it is omitted (never `0`) if it cannot be read.
`app.start.sdk_init_ms` is the part before the first line of
``EdgeRum/start(_:)``. On iOS 15+ the event reports prewarmed launches
via `app.start.prewarmed`; a prewarmed launch omits
`app.start.sdk_init_ms` and its duration starts at ``EdgeRum/start(_:)``.

Opt out via ``EdgeRumConfig/capturePageLoad``.

## Native crashes and hangs

`PLCrashReporter` captures `SIGSEGV`, `SIGABRT`, `SIGBUS`, `SIGILL`,
and uncaught `NSException`. The replay-on-next-launch path reads a
crash sidecar at `Library/Caches/edge-rum/last-session.json` so the
emitted `app.crash` carries the **previous** session's identity, not
the current one.

The hang watchdog observes `CFRunLoopObserver` activity on the main
runloop; a stall longer than ``EdgeRumConfig/hangTimeout`` (default
5.0 s, 2 s minimum) emits one `app.hang` event when it **ends**, with
the real `hang.duration_ms`, `hang.timestamp` (when the threshold was
crossed), and a best-effort `error.stacktrace` snapshot taken during the stall
(same `image +0x<offset> <hint>` frame format, with
`hang.binary_images`). If the app is killed mid-stall, the hang is sent
on the next launch with `hang.terminated = true` under the previous
session. With hang detection on, `perf.long_task` stops at the hang threshold
so each stall is reported once.
Hangs are not fatal: `app.hang` follows ``EdgeRumConfig/sampleRate`` and
the normal flush, while `app.crash` is reserved for replayed native
crashes and flushes immediately.

Opt out via ``EdgeRumConfig/captureNativeCrashes`` and
``EdgeRumConfig/enableHangDetection``.
