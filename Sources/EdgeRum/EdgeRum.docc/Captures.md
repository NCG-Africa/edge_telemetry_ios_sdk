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
`navigation.screen` and `navigation.previous_screen`. Screen exits emit
nothing — dwell time is derived server-side from consecutive
`navigation` events. The capture is installed on the base
`UIViewController`, so every subclass inherits it.

Container view controllers — `UINavigationController`,
`UITabBarController`, `UIPageViewController` — are skipped; the
contained controller's `viewDidAppear` is what counts. Screen names
prefer the controller's `accessibilityIdentifier` (stable across class
renames), falling back to the reflected type name.

SwiftUI screens emit the same wire shape through the
`View.edgeRumScreen(_:attributes:)` modifier, tagged with
`navigation.kind = "swiftui"`. SwiftUI screens routed through
`UIHostingController` are also detected automatically. Manual
``EdgeRum/trackScreen(_:attributes:)`` calls are tagged
`navigation.kind = "manual"`.

Opt out via ``EdgeRumConfig/captureScreens``.

## HTTP

Every outgoing `URLSession` request emits an `http.request` event and a
companion `resource_timing` metric — no per-call code required.
`URLSession.shared` and consumer-created `URLSession(configuration:
.default, delegate:, ...)` flows are both intercepted at the protocol
layer; the SDK never wraps or replaces your delegate.

What's captured: `http.method`, `http.host`, `http.path`,
`http.status_code`, `http.duration_ms`, `http.request_size`,
`http.response_size`, `http.from_cache`, and — only on failure —
`http.error_domain` (string) plus `http.error_code` (int). No full URL
or query string is sent. The companion `resource_timing` metric carries
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

Every completed UIKit tap produces a `user.interaction` event. The
capture is installed on the base `UIWindow.sendEvent(_:)` so every
subclass inherits it, and emits exactly once per `.ended` touch.

What's captured: `interaction.kind`, `interaction.target` (the
reflected class name of the resolved target view), `interaction.name`
(the `accessibilityIdentifier`; a `UIButton`'s current title only when
``EdgeRumConfig/captureButtonTitles`` is `true`), and
`interaction.name_source` (`accessibility_identifier`, `button_title`,
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
`long_task` are never held back.

- **`frame_render_time`** — a `CADisplayLink` runs only inside a
  *motion window*: a touch (began or ended) or a screen transition opens
  one, and it closes 2 s after the last such motion, 10 s at most. The
  link is paused otherwise, so static content never holds the display at
  its maximum refresh rate. Each window emits one item with
  `frame.max_ms`, `frame.p95_ms`, `frame.dropped_count` (frames skipped
  at the refresh rate the display is actually running; omitted when the
  window saw no frames), `frame.target_hz`, `frame.sample_count`, `frame.window_ms` (window
  length — normalise by it), `frame.source = "displaylink"`, and
  `value = frame.max_ms`.
- **`memory_usage`** — a `DispatchSourceTimer` polls
  `mach_task_basic_info` (RSS, virtual) and `task_vm_info`
  (`phys_footprint`) every 30 seconds, tagged with the last observed
  `memory.pressure`; in parallel a
  `DispatchSource.makeMemoryPressureSource(eventMask: .all)` emits an
  out-of-band sample tagged `memory.pressure ∈ "normal" / "warning" /
  "critical"` on every transition. The `memory.*_kb` attributes are
  in kB and are omitted when the kernel read fails; the item `value` is
  in MB.
- **`cpu_usage`** — on the same 30-second tick, whole-process CPU since
  the previous tick as `value`, in per-core percent (one busy core is
  100, so values may exceed 100).
- **`long_task`** — a `CFRunLoopObserver` measures the interval between
  `.afterWaiting` and the next `.beforeWaiting`. Any work segment ≥ 50 ms
  emits a `long_task` metric with `value` (ms),
  `long_task.threshold_ms`, and a `long_task.stack` snapshot
  (truncated to 4 KiB; `long_task.stack.truncated` counts the bytes
  removed). Frames read `image +0x<offset> <hint>`;
  `long_task.binary_images` lists the referenced images (`name`,
  `uuid`) as a JSON string so offsets can be symbolicated.

Opt out via ``EdgeRumConfig/captureRenderingPerformance``.

## Lifecycle and connectivity

`app_lifecycle` events fire on every transition between `foregrounded`,
`active`, `inactive`, `backgrounded`, and `will_terminate`. Background
transitions also force an immediate flush so the in-memory buffer is
shipped before the OS suspends the process.

`network_change` events fire on every `NWPathMonitor` transition, carrying
`network.type`, `network.effectiveType`, `network.expensive`,
`network.constrained`, and (iOS 14.2+) `network.unsatisfied_reason`.
On cellular, `network.effectiveType` is the radio generation (`2g`–`5g`,
or `unknown`), and a radio handover alone also fires `network_change`.

Opt out via ``EdgeRumConfig/captureLifecycle`` and
``EdgeRumConfig/captureNetworkChanges``.

## Page load

One `page_load` event per process. `page_load.duration_ms` runs from
the first line of ``EdgeRum/start(_:)`` to the first `CADisplayLink`
tick after the app reaches `.active`, on a monotonic clock; it is
omitted (never `0`) if it cannot be read. `launch.pre_sdk_duration_ms`
is the time from process start to that first line — everything before
the SDK could observe — so the two sum to time to first frame. On
iOS 15+ the event reports prewarmed launches via `page_load.prewarmed`,
and a prewarmed launch omits `launch.pre_sdk_duration_ms`.

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
crossed), and a best-effort `hang.stack` snapshot taken during the stall
(same `image +0x<offset> <hint>` frame format, with
`hang.binary_images`). If the app is killed mid-stall, the hang is sent
on the next launch with `hang.terminated = true` under the previous
session. With hang detection on, `long_task` stops at the hang threshold
so each stall is reported once.
Hangs are not fatal: `app.hang` follows ``EdgeRumConfig/sampleRate`` and
the normal flush, while `app.crash` is reserved for replayed native
crashes and flushes immediately.

Opt out via ``EdgeRumConfig/captureNativeCrashes`` and
``EdgeRumConfig/enableHangDetection``.
