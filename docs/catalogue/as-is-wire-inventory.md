# As-is wire inventory — every event and attribute the iOS SDK emits today

**Source of truth:** `Sources/` at `main` @ `e72928f`. Read, not run — every row below cites the
file and line that produces it.

**Status:** the *as-is* half of `docs/catalogue/ios-data-catalogue.md`. Produced for
[[W2] Wire inventory](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/190) under map
[iOS RUM coverage](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/188).

**Row shape** follows the two registries fixed in
[[W1] Catalogue schema](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/189), minus two
columns that no amount of reading this repo can fill: **`pii`** is owned by #195 (the closed
vocabulary does not exist yet) and **`delta`** needs the Android name list, which lives outside this
repo. Both columns are added when the catalogue is written (#203); nothing here should be read as a
decision about either.

**What this document is not.** It records what *is* emitted, not what should be. Where the source
diverges from itself, the divergence is recorded as a row-level fact and collected in
[§5 Divergences and defects](#5-divergences-and-defects). No fix is proposed here.

---

## 1. Totals

| | count |
|---|---|
| Event names on the wire (`type = "event"`) | **11** reachable, of 12 allowlisted — see D1 |
| Metric names on the wire (`type = "metric"`) | **5 fixed + unbounded host-supplied** |
| Context attribute keys (ride every event) | **44** |
| Event-scoped attribute keys | **93**, two of which are open prefixes (`error.userInfo.*`, `crash.context.*`) |
| Host-supplied attribute keys | unbounded — five public entry points merge caller bags verbatim |

---

## 2. Envelope

`EventEnvelope.swift:31-64`. One batch per flush.

| field | type | notes |
|---|---|---|
| `type` | string | always the literal `"telemetry_batch"` |
| `timestamp` | string | ISO 8601 + fractional seconds, stamped at **flush**, not enqueue (`PayloadBuilder.build`) |
| `location` | string | optional `City/Country`. Omitted when nil. Populated from `EdgeRumConfig.location`, or resolved once at startup from `locationProviderUrl` (default `https://ipapi.co/json/`) when `resolveLocation == true` — **default off** (`EdgeRumConfig.swift:62-72`) |
| `batch_size` | number | `events.count` |
| `events` | array | per-item shapes below |

Per item (`EventEnvelope.swift:66-99`):

- **event** — `type: "event"`, `eventName`, `timestamp`, `attributes`.
- **metric** — `type: "metric"`, `metricName`, `value` (**omitted when nil**), `timestamp`, `attributes`.

`attributes` is a flat `[String: AttributeValue]`; `AttributeValue` has exactly four cases —
`string` / `int` / `double` / `bool` (`AttributeValue.swift:35-38`). Nesting is unrepresentable.

**Context merge.** `PayloadBuilder.build` (`PayloadBuilder.swift:39`) merges one
`ContextProvider.snapshot()` into *every* event in the batch, event attributes winning on key
conflict. The snapshot is taken in `Recorder.flush` (`Recorder.swift:416`) — so context values are
**flush-time**, not emit-time. Already recorded as clause 3 of the catalogue header contract and
handed to #192 as a possible defect rather than a documentation problem.

---

## 3. Event registry

`span` is `no` on every row: no emitter in `Sources/` writes a trace or span attribute today.
Distributed trace v3 is spec'd (`docs/specs/distributed-trace-v3-ios.md`) and unbuilt.

| name | wire type | value (unit) | trigger | span | notes |
|---|---|---|---|---|---|
| `session.started` | event | — | `Recorder.start()` (`Recorder.swift:289`); idle rotation (`:518`) | no | forced-emit (bypasses sampler). **Two attribute sets** — see D2 |
| `session.finalized` | event | — | `Recorder.stop()` (`:306`); `willResignActive` + `willTerminate` (`LifecycleCapture.swift:134`); idle rotation (`:514`) | no | forced-emit; triggers an **immediate flush** (`:350`). **Two attribute sets** — see D2 |
| `app_lifecycle` | event | — | five `UIApplication` notifications (`LifecycleCapture.swift:150-185`) | no | sampled |
| `page_load` | event | — | first `CADisplayLink` tick after `.active` (`PageLoadCapture.swift:224`) | no | **one-shot per process**; the one-shot rewinds if the Recorder is disabled |
| `navigation` | event | — | `viewDidAppear` swizzle (`UIViewControllerCapture.swift:309`); `.edgeRumScreen` `onAppear` (`ViewModifiers.swift:54`); `EdgeRum.trackScreen` (`EdgeRum.swift:340`) | no | **three emitters, three attribute sets** — see D3 |
| `http.request` | event | — | `URLSessionTaskMetrics` delegate (`HTTPCapture.swift:350`) | no | after filter → `ignoreUrls` → `sanitizeUrl` |
| `user.interaction` | event | — | `UIWindow.sendEvent` swizzle, touch `.ended` (`InteractionCapture.swift:180`); `.edgeRumTrackTap` (`ViewModifiers.swift:98`) | no | **two emitters, two attribute sets** — see D4. Never lands in `rum_ui_interactions` — see D9 |
| `network_change` | event | — | `NWPathMonitor` transition, deduped by fingerprint (`NetworkPathCapture.swift:242`) | no | forced-emit. Refreshes context even when the event itself is deduped |
| `user.profile.update` | event | — | `EdgeRum.identify()` → `Recorder.setUser` (`:395`) | no | carries only the keys the host supplied |
| `custom_event` | event | — | `EdgeRum.track(name:)` (`EdgeRum.swift:330`) | no | the host's name travels as the `event.name` **attribute**, not the event name |
| `app.crash` | event | — | `EdgeRum.captureError` (`:384`); hang watchdog (`HangDetector.swift:334`); native crash replay (`PLCrashIntegration.swift:174`) | no | forced-emit; immediate flush. **Three producers, three disjoint attribute sets** — see D5 |
| `screen.duration` | — | — | **never emitted as an event** | — | present in `Recorder.allowedEventNames` but only ever emitted as a metric — see D1 |
| `screen.duration` | metric | dwell, **seconds** | `viewWillDisappear` (`UIViewControllerCapture.swift:337`); `.edgeRumScreen` `onDisappear` (`ViewModifiers.swift:81`) | no | mixed units on one row — see D6. Never lands in `rum_screen_durations` — see D9 |
| `resource_timing` | metric | request duration, **ms** | emitted alongside `http.request` when `URLSessionTaskMetrics` yielded a timing (`HTTPCapture.swift:371`) | no | absent when metrics are unavailable. Never lands — see D9 |
| `long_task` | metric | stall, **ms** | run-loop gap ≥ threshold, default **50 ms** (`RunLoopObserverCapture.swift:132`) | no | duration exists **only** as `value` |
| `frame_render_time` | metric | worst frame of window, **ms** | **every 1 s window** while the display link runs (`FrameSampler.swift:220`) | no | unconditional — emits even on a perfectly smooth window. ~60/min foregrounded |
| `memory_usage` | metric | resident set, **kB** | every **10 s** + every memory-pressure event (`MemorySampler.swift:151`, driver `:241`) | no | |
| *host-supplied name* | metric | elapsed, **ms** | `EdgeRum.time(name).end()` (`RumTimer.swift:62`) | no | **name is unbounded** — see D7 |

---

## 4. Attribute registry

`presence` is `required` / `optional` per W1. Cardinality `bounded enum` lists its members inline —
that list is the contract.

### 4.1 Context — `on events = context` (44 keys)

Written by `ContextProvider.snapshot()` in a fixed order; namespaces are disjoint so nothing
collides (`ContextProvider.swift:70-81`).

| key | type | presence | cardinality | notes |
|---|---|---|---|---|
| `app.name` | string | optional | unbounded string | `AppContext.swift:79`; config override or `Info.plist` |
| `app.package_name` | string | optional | unbounded string | |
| `app.version` | string | optional | unbounded string | |
| `app.build_number` | string | optional | unbounded string | |
| `app.environment` | string | optional | bounded enum: `production`, `staging`, `development` | absent unless `EdgeRumConfig.environment` is set |
| `app.background_refresh` | string | optional | bounded enum: `available`, `denied`, `restricted`, `unknown` | `StorageContext.swift:95-101` |
| `device.platform` | string | required | bounded enum: `ios` | constant |
| `device.manufacturer` | string | required | bounded enum: `Apple` | constant |
| `device.os` | string | required | bounded enum: `ios` | constant; duplicates `device.platform` |
| `device.platform_version` | string | optional | unbounded string | |
| `device.model` | string | optional | unbounded string | |
| `device.isVirtual` | bool | required | — | simulator flag |
| `device.screenWidth` | int | optional | numeric | points |
| `device.screenHeight` | int | optional | numeric | points |
| `device.pixelRatio` | double | optional | numeric | |
| `device.batteryLevel` | double | optional | numeric | sampled — stale by up to the last `ContextObservers` refresh |
| `device.batteryCharging` | bool | optional | — | sampled |
| `device.locale` | string | optional | unbounded string | |
| `device.timezone` | string | optional | unbounded string | |
| `device.timezone_offset_min` | int | optional | numeric | |
| `device.id` | string | required | unbounded string | `device_<epochMs>_<16 hex>_ios`; Keychain-backed |
| `device.thermal_state` | string | optional | bounded enum: `nominal`, `fair`, `serious`, `critical` | `PowerContext.swift:63-69`; sampled |
| `device.low_power_mode` | bool | optional | — | sampled |
| `device.dynamic_type` | string | optional | bounded enum (UIKit content-size categories) | `AccessibilityContext.swift:78` |
| `device.reduce_motion` | bool | optional | — | |
| `device.bold_text` | bool | optional | — | |
| `device.voiceover` | bool | optional | — | |
| `device.increase_contrast` | bool | optional | — | |
| `device.disk_free_mb` | int | optional | numeric | sampled periodically + on lifecycle |
| `device.disk_total_mb` | int | optional | numeric | |
| `network.type` | string | required | bounded enum: `wifi`, `cellular`, `wired`, `none`, `unknown` | `NetworkContext.swift:30-35` |
| `network.effectiveType` | string | required | bounded enum: `2g`, `3g`, `4g`, `5g`, `wifi`, `unknown` | best-effort; cellular generations are **not** resolved today — `cellular` paths report `cellular` |
| `network.expensive` | bool | required | — | **shadowed by `network.is_expensive` on `network_change`** — see D8 |
| `network.constrained` | bool | required | — | same, see D8 |
| `network.interface` | string | optional | unbounded string | e.g. `en0` |
| `session.id` | string | required | unbounded string | `session_<epochMs>_<hex>_ios` |
| `session.start_time` | string | required | unbounded string | ISO 8601 |
| `session.sequence` | int | required | numeric | incremented per ACKed batch |
| `user.id` | string | required | unbounded string | SDK-owned anonymous id |
| `user.name` | string | optional | unbounded string | present after `identify()`; stored **verbatim** |
| `user.email` | string | optional | unbounded string | present after `identify()`; stored **verbatim** |
| `user.phone` | string | optional | unbounded string | present after `identify()`; stored **verbatim** |
| `sdk.version` | string | required | unbounded string | build-plugin generated |
| `sdk.platform` | string | required | bounded enum: `ios-native` | constant |

### 4.2 Event-scoped

| key | type | on events | presence | cardinality | notes |
|---|---|---|---|---|---|
| `session.rotation` | string | `session.started`, `session.finalized` | optional | bounded enum: `idle` | present **only** on the idle-rotation pair (`Recorder.swift:513-518`) |
| `lifecycle.state` | string | `app_lifecycle` | required | bounded enum: `inactive`, `backgrounded`, `foregrounded`, `active`, `will_terminate` | |
| `lifecycle.previous_state` | string | `app_lifecycle` | required | same enum **plus** `unknown` | `unknown` on the first emission after install/reset |
| `page_load.duration_ms` | int | `page_load` | required | numeric | |
| `page_load.cold_start` | bool | `page_load` | required | — | |
| `page_load.prewarmed` | bool | `page_load` | required | — | |
| `page_load.source` | string | `page_load` | required | bounded enum: `displaylink` | constant |
| `navigation.screen` | string | `navigation` | optional | unbounded string | UIKit swizzle + `.edgeRumScreen` only — **not** `EdgeRum.trackScreen` (D3) |
| `navigation.name` | string | `navigation` | optional | unbounded string | `EdgeRum.trackScreen` only (D3) |
| `navigation.kind` | string | `navigation` | optional | bounded enum: `uikit`, `swiftui` | absent from `trackScreen` |
| `navigation.type` | string | `navigation` | optional | bounded enum: `viewDidAppear` | constant; absent from `trackScreen` |
| `navigation.previous_screen` | string | `navigation` | optional | unbounded string | UIKit swizzle only, and only when a prior screen was seen |
| `screen.name` | string | `screen.duration` | required | unbounded string | |
| `screen.kind` | string | `screen.duration` | required | bounded enum: `uikit`, `swiftui` | |
| `screen.duration_ms` | int | `screen.duration` | required | numeric | |
| `value` | double | every metric | required on 5 fixed metrics | numeric | **unit varies by metric** — see D6. Lifted onto the envelope `value` by `Recorder.recordPerformance` (`Recorder.swift:355-380`) and left in the bag |
| `duration_ms` | int | host-named metrics | required | numeric | added by `RumTimer.end` |
| `http.method` | string | `http.request` | required | bounded enum (HTTP verbs) | defaults to `GET` when nil |
| `http.url` | string | `http.request` | required | unbounded string | post-`sanitizeUrl` |
| `http.host` | string | `http.request` | required | unbounded string | `""` when unresolvable |
| `http.path` | string | `http.request` | required | unbounded string | |
| `http.status_code` | int | `http.request` | required | numeric | **`0` when the response was not an `HTTPURLResponse`** (transport error) |
| `http.duration_ms` | int | `http.request` | required | numeric | wall clock, clamped ≥ 0 |
| `http.request_size` | int | `http.request` | required | numeric | |
| `http.response_size` | int | `http.request` | required | numeric | |
| `http.from_cache` | bool | `http.request` | required | — | last transaction `resourceFetchType == .localCache` |
| `http.error` | string | `http.request` | optional | unbounded string | `String(describing:)` of the transport error; absent on success |
| `http.redirect_count` | int | `http.request` | optional | numeric | whole enrichment block absent when metrics are unavailable |
| `http.tls_protocol` | string | `http.request` | optional | bounded enum: `1.0`, `1.1`, `1.2`, `1.3` | absent when unencrypted or unrecognised |
| `http.tls_cipher` | string | `http.request` | optional | bounded enum (IANA suite names) + hex fallback | |
| `http.reused_connection` | bool | `http.request` | optional | — | |
| `http.proxy_connection` | bool | `http.request` | optional | — | |
| `http.network_protocol` | string | `http.request` | optional | bounded enum (normalised ALPN) | |
| `http.request_body_bytes_before_encoding` | int | `http.request` | optional | numeric | summed across transactions |
| `http.cellular_fallback` | bool | `http.request` | optional | — | **iOS 17+ only** (`HTTPCapture.swift:415`) |
| `resource.url` | string | `resource_timing` | required | unbounded string | duplicates `http.url` |
| `resource.host` | string | `resource_timing` | required | unbounded string | duplicates `http.host` |
| `resource.dns_ms` | int | `resource_timing` | required | numeric | |
| `resource.connect_ms` | int | `resource_timing` | required | numeric | |
| `resource.tls_ms` | int | `resource_timing` | required | numeric | |
| `resource.ttfb_ms` | int | `resource_timing` | required | numeric | |
| `resource.download_ms` | int | `resource_timing` | required | numeric | |
| `resource.redirect_count` | int | `resource_timing` | required | numeric | duplicates `http.redirect_count` |
| `resource.transaction_count` | int | `resource_timing` | required | numeric | |
| `resource.fetch_start_to_response_end_ms` | int | `resource_timing` | optional | numeric | |
| `resource.protocol` | string | `resource_timing` | optional | bounded enum (normalised ALPN) | duplicates `http.network_protocol` |
| `interaction.kind` | string | `user.interaction` | required | bounded enum: `tap` | constant — only completed taps are captured |
| `interaction.target` | string | `user.interaction` | optional | unbounded string | UIKit only; `String(reflecting:)` of the resolved view type |
| `interaction.target_id` | string | `user.interaction` | optional | unbounded string | UIKit only. **`accessibilityIdentifier` OR rendered button title** — one key, two meanings (`InteractionCapture.swift:276-288`) |
| `interaction.screen` | string | `user.interaction` | optional | unbounded string | UIKit only; absent when no screen is known |
| `interaction.name` | string | `user.interaction` | optional | unbounded string | `.edgeRumTrackTap` only (D4) |
| `network.is_expensive` | bool | `network_change` | required | — | see D8 |
| `network.is_constrained` | bool | `network_change` | required | — | see D8 |
| `network.unsatisfied_reason` | string | `network_change` | optional | bounded enum: `not_available`, `cellular_denied`, `wifi_denied`, `local_network_denied`, `vpn_inactive` | absent when the path is satisfied |
| `user.external_id` | string | `user.profile.update` | optional | unbounded string | the **host's** id; distinct from SDK-owned `user.id` |
| `event.name` | string | `custom_event` | required | unbounded string | the host's chosen name |
| `cause` | string | `app.crash` | required | bounded enum: `AppError`, `Hang`, `NativeCrash` | the discriminator between the three producers |
| `runtime` | string | `app.crash` | required | bounded enum: `swift`, `native` | |
| `crash.fatal` | bool | `app.crash` | optional | — | `true` native, `false` hang, **absent for `AppError`** (D5) |
| `error.type` | string | `app.crash` (AppError) | required | unbounded string | Swift type name or `NSError` |
| `error.message` | string | `app.crash` (AppError) | required | unbounded string | `localizedDescription`, falling back to `String(describing:)` |
| `error.kind` | string | `app.crash` (AppError) | required | bounded enum: `swift`, `nserror` | |
| `error.domain` | string | `app.crash` (AppError) | required | unbounded string | synthetic type name for bridged Swift errors |
| `error.code` | int | `app.crash` (AppError) | required | numeric | `0` for bridged Swift errors |
| `error.stack` | string | `app.crash` (AppError) | optional | unbounded string | `\n`-joined, truncated whole-frame to **4096 B** |
| `error.userInfo.<key>` | any | `app.crash` (AppError) | optional | **open prefix** | explicit `NSError` only; non-primitive values dropped |
| `crash.context.<key>` | any | `app.crash` (AppError) | optional | **open prefix** | caller-supplied via `captureError(context:)` |
| `hang.duration_ms` | double | `app.crash` (Hang) | required | numeric | |
| `hang.threshold_ms` | double | `app.crash` (Hang) | required | numeric | default 5000 (`EdgeRumConfig.hangTimeout`) |
| `hang.cpu_usage` | double | `app.crash` (Hang) | optional | numeric | **the only CPU number the SDK emits anywhere** |
| `crash.timestamp` | string | `app.crash` (Hang, NativeCrash) | required | unbounded string | ISO 8601; **absent for `AppError`** |
| `crash.thread.main_stack` | string | `app.crash` (Hang) | required | unbounded string | `<hang-stack-unavailable>` placeholder when the walk fails |
| `crash.report_format_version` | string | `app.crash` (NativeCrash) | required | unbounded string | |
| `crash.signal` | string | `app.crash` (NativeCrash) | optional | unbounded string | |
| `crash.signal_code` | string | `app.crash` (NativeCrash) | optional | unbounded string | |
| `crash.exception_name` | string | `app.crash` (NativeCrash) | optional | unbounded string | only when the report carries exception info |
| `crash.exception_reason` | string | `app.crash` (NativeCrash) | optional | unbounded string | |
| `crash.os_version` | string | `app.crash` (NativeCrash) | optional | unbounded string | |
| `crash.binary_uuid` | string | `app.crash` (NativeCrash) | optional | unbounded string | faulting image, for dSYM lookup |
| `crash.binary_name` | string | `app.crash` (NativeCrash) | optional | unbounded string | last path component |
| `crash.report_json` | string | `app.crash` (NativeCrash) | required | unbounded string | **the whole report as an embedded JSON string**; registers then binary images are stripped to fit the size cap |
| `long_task.threshold_ms` | double | `long_task` | required | numeric | default 50 |
| `long_task.stack` | string | `long_task` | required | unbounded string | truncated to 4096 B |
| `frame.max_ms` | double | `frame_render_time` | required | numeric | |
| `frame.p95_ms` | double | `frame_render_time` | required | numeric | |
| `frame.dropped_count` | int | `frame_render_time` | required | numeric | |
| `frame.target_hz` | int | `frame_render_time` | required | numeric | 60 or the ProMotion maximum |
| `frame.source` | string | `frame_render_time` | required | bounded enum: `displaylink` | constant |
| `frame.sample_count` | int | `frame_render_time` | required | numeric | frames in the 1 s window |
| `memory.resident_kb` | int | `memory_usage` | required | numeric | |
| `memory.virtual_kb` | int | `memory_usage` | required | numeric | |
| `memory.footprint_kb` | int | `memory_usage` | required | numeric | |
| `memory.pressure` | string | `memory_usage` | required | bounded enum: `normal`, `warning`, `critical` | |

### 4.3 Attributes the crash replay path overrides

`PLCrashIntegration.replayPendingReport` folds the crashed session's sidecar onto the `app.crash`
bag, and event attributes beat context — so on a replayed crash these keys carry the **prior**
session's values: `session.id`, `session.start_time`, `session.sequence`, `device.id`, `user.id`,
plus any other mirrored key not already set (`user.name`, `user.email`, `user.phone`, `sdk.version`,
`sdk.platform` — `SessionSidecar.mirroredKeys`). Transient context (network, battery) is
deliberately **not** mirrored, so a replayed crash carries the *next* launch's network state.

### 4.4 Host-supplied attributes

Five entry points merge a caller bag verbatim, with SDK-owned keys applied **last** so they cannot
be overwritten: `EdgeRum.track`, `EdgeRum.trackScreen`, `.edgeRumScreen`, `.edgeRumTrackTap`,
`RumTimer.end`. Key names are unconstrained — no prefix, no allowlist, no cardinality guard.

---

## 5. Divergences and defects

Recorded as found. Each is a fact about the current wire, not a proposal.

- **D1 — `screen.duration` is a dead entry in the event allowlist.** `Recorder.allowedEventNames`
  (`Recorder.swift:48-61`) lists 12 names, but `screen.duration` is only ever emitted through
  `recordPerformance`, which does not consult the allowlist at all. So the list gates 11 reachable
  names and one unreachable one, and the four real metric names (`resource_timing`, `long_task`,
  `frame_render_time`, `memory_usage`) are absent from it and correctly so.
- **D2 — `session.started` / `session.finalized` each have two attribute sets.** The lifecycle
  emitters send an empty bag; the idle-rotation pair sends `session.rotation = "idle"`, and
  `session.finalized` additionally re-states `session.id`, `session.start_time` and
  `session.sequence` so the event carries the *prior* session's identity before the context rotates.
  A consumer cannot assume those keys are present.
- **D3 — `navigation` has three producers and two different screen-name keys.** The UIKit swizzle
  and `.edgeRumScreen` write `navigation.screen`; `EdgeRum.trackScreen` writes **`navigation.name`**
  and omits `navigation.kind` and `navigation.type` entirely. Only the UIKit swizzle ever writes
  `navigation.previous_screen`.
- **D4 — `user.interaction` has two producers with disjoint target keys.** UIKit writes
  `interaction.target` / `interaction.target_id` / `interaction.screen`; `.edgeRumTrackTap` writes
  `interaction.name` and nothing else. There is no key present on both.
- **D5 — `app.crash` has three producers with near-disjoint bags.** `crash.fatal` is absent on the
  `AppError` bag, so fatality is not uniformly answerable; `crash.timestamp` is likewise absent on
  `AppError`. `cause` is the only reliable discriminator.
- **D6 — `value` carries a different unit on every metric.** `screen.duration` → **seconds**
  (while its own `screen.duration_ms` is ms, on the same row); `resource_timing` → ms;
  `long_task` → ms; `frame_render_time` → ms; `memory_usage` → **kB**; host-named metrics → ms.
  Nothing on the wire states the unit.
- **D7 — metric names are unbounded.** `recordPerformance` has no allowlist, so
  `EdgeRum.time(name)` puts a host-controlled string in the `metricName` field. Event names are
  allowlisted; metric names are not.
- **D8 — the same network facts ship under two key spellings on one event.** Context writes
  `network.expensive` / `network.constrained`; the `network_change` event writes
  `network.is_expensive` / `network.is_constrained`. Different keys, so both appear on that event.
  `network.type` and `network.effectiveType` *do* collide by name and the event value wins.
- **D9 — three signals are emitted but never land** (pre-existing, recorded in #168, owned by
  #201): the Processor switches on `ui.interaction` while iOS emits `user.interaction`, so
  `rum_ui_interactions` stays empty; `screen.duration` and `resource_timing` are typed `metric`, and
  the Processor's metric branch returns early, so `rum_screen_durations` is never written. Listed
  here so the catalogue does not read as evidence that §4 and §11 are covered.
- **D10 — key casing is mixed within one namespace.** `device.isVirtual`, `device.screenWidth`,
  `device.screenHeight`, `device.pixelRatio`, `device.batteryLevel`, `device.batteryCharging` and
  `network.effectiveType` are camelCase; every other key in the same namespaces is snake_case.
- **D11 — `interaction.target_id` collapses two different things.** `accessibilityIdentifier` when
  present, otherwise the rendered button title — so one key is sometimes a stable test id and
  sometimes user-visible copy. Already feeding #195.
- **D12 — `device.os` duplicates `device.platform`.** Both are the constant `"ios"`.
- **D13 — `resource_timing` restates four `http.request` attributes** (`url`, `host`,
  `redirect_count`, `protocol`) under a second prefix, on a row that is always emitted alongside it.

## 6. Volume facts worth carrying forward

Not a budget — measurements are #196's job. These are the emission rates readable from source:

- `frame_render_time` fires **every 1 s window unconditionally**, whether or not any frame dropped —
  ~60 metrics/minute while foregrounded.
- `memory_usage` fires every **10 s**, plus once per memory-pressure notification.
- `user.interaction` fires once per completed touch, unfiltered by target type.
- `resource_timing` roughly doubles HTTP volume: one metric per captured request that produced
  `URLSessionTaskMetrics`, on top of the `http.request` event.
- Every one of these passes through `Recorder.enqueue` → `SessionSidecar.write`, which does a
  synchronous `JSONEncoder` + atomic file write per event on the caller's thread with no dirty check
  (`Recorder.swift:539`) — the O1 hot path.
- When a session is sampled out, **all metrics vanish**: `Sampler.shouldEmit(metricName:)` has no
  forced-emit list, unlike the event path (`Sampler.swift:58-61`).
