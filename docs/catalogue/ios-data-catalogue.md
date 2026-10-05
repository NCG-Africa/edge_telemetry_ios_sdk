# iOS data catalogue — every event and attribute `edge-rum-ios` emits

**Status:** the backend hand-off, and the terminal deliverable of map
[iOS RUM coverage][M188] ([W15 Write the catalogue and roadmap][W15]). It holds the
**as-is** wire (`main` @ `e72928f`, `1.0.0-alpha.2`, from [W2 Wire inventory][W2]) plus every
field the map's tickets decided to add, rename, delete or split, in the row shapes fixed by
[W1 Catalogue schema][W1] and amended by [W10 Context riders][W10].

**Plan-only.** Nothing below the as-is line is built. Each change names the tranche that lands it,
numbered as ranked by [W14 Rank the tranches][W14] (§1.3). The tranche order lives in the
roadmap, [`docs/specs/rum-coverage-roadmap.md`](../specs/rum-coverage-roadmap.md): the roadmap says
*when* a row changes, this document says *what* it is.

**Where a ticket and a later ticket disagree, this document wins.** Several ticket premises were
corrected by later tickets, and a few decisions were left with an unspelled value. The roadmap is
the spec for tranche placement and for the rulings in its §10 *Conflicts resolved by this spec*;
this catalogue follows it, and where the two ever disagree **the roadmap wins**. Every conflict is
listed with its resolution in §13 (keyed to the roadmap's §10 rows); open items are in §14. Trace v3 is not
reopened: `docs/specs/distributed-trace-v3-ios.md` stays authoritative for every trace attribute,
and rows that carry one cite its section.

---

## 0. Header contract

1. **iOS names natively; the Processor adapts per platform.** Outside the trace v3 attributes
   (frozen to Android's contract) and the cross-platform required-identity set, iOS does not bend
   its vocabulary to Android's or web's.
2. **The cost is stated, not discovered: three platform-specific ingestion paths instead of one
   shared vocabulary.** The Processor carries an iOS path, an Android path and a web path. The
   `delta` column on every row is the evidence for that cost.
3. **Read-time depends on `scope`.**
   - `context` attributes carry their value at **batch flush**, not at event emission. All events
     in one batch share one `ContextProvider.snapshot()`, taken in `Recorder.flush`
     (`Recorder.swift:416`) and merged by `PayloadBuilder.build` (`PayloadBuilder.swift:39`).
     Battery, thermal and storage values are additionally up to 5 minutes stale (refresh timer,
     `ContextObservers.swift:77`).
   - `rider` attributes are **stamped at enqueue** into the event's own attributes, read from a
     lock-free latest-wins box ([W3 O1 / volatile sidecar][W3], named by
     [W5 Action lifecycle][W5], given this column by [W10][W10]). Event attributes beat context on
     merge, so a rider is the value at the moment the event happened.
   - `event` attributes are set by the emitter at emission.
   - **Exception — replayed crash and replayed hang:** these are enqueued on the *next* launch, so
     their riders come from the sidecar's best-effort **volatile zone** (written coalesced on
     change), and their identity from its exact identity zone. They describe the process that
     died, not the one reporting it. Transient context (network, battery) on a replayed event is
     the reporting launch's.
4. **Where a ticket and a later ticket disagree, this document wins.** (§13.)
5. **Exception wins** ([W11 Error taxonomy][W11]). On `app.crash`, `crash.signal` /
   `crash.signal_code` and `crash.exception_name` / `crash.exception_reason` are both optional and
   **co-occur in the common case** — an uncaught Objective-C exception raises `SIGABRT`. When both
   are present the exception is the proximate cause; the signal is how the runtime expressed it.
   The SDK ships no `crash.kind`; this rule is how the Processor derives one.
6. **`unknown` never means `oom`** ([W11][W11]). `previous_session.end = unknown` means the SDK
   observed neither a clean termination nor a crash report. A user force-quit from the app switcher
   is indistinguishable from a foreground OOM and far more common. OOM is a backend inference
   joining `unknown` against `memory_usage` samples — never a field the SDK emits.
7. **A metric's unit is frozen with its name** ([W16 Metric wire row][W16]). Changing a unit means
   a new metric name, never a silent change under the old one. Units are pinned per name in §6,
   not sent on the wire.
8. **Degradation markers** ([W8 SDK health][W8]). Two suffixes, both integer counts, never
   booleans: `.dropped` (items no longer on the wire) and `.truncated` (amount removed, in the unit
   of the cap). **Omitted when zero** — this catalogue declares which markers exist on which events,
   so a declared marker's absence means zero, not "not instrumented".
9. **Omit, never falsify** ([W8][W8]). A value the SDK could not read is **absent**, never `0` or a
   substitute. Rows marked `~Tn` with "omit" fix sites that falsify today.
10. **Absent by design.** Keys are omitted rather than sent empty. Periodic samples
    (`frame_render_time`, `memory_usage` timer tick, `cpu_usage`) are absent while the sampling gate
    is closed — app not active, Low Power Mode, or thermal state `serious`+
    ([W12 Sampling policy][W12]); `device.low_power_mode` and `device.thermal_state` on surrounding
    events disambiguate the gap.
11. **Session sampling governs everything except four forced-emit names** (`session.started`,
    `session.finalized`, `app.crash`, `network_change`; `Sampler.swift:23-28`). A sampled-out
    session emits no metrics at all. Actions, hangs, handled errors, launch and SDK health follow
    session sampling by decision, not by accident (§8).
12. **`user.interaction` answers what the user touched; `action.*` answers what the user was trying
    to do.** They join on `action.id` when both are present ([W5][W5]).

---

## 1. How to read the rows

### 1.1 Columns

**Attribute registry** — `key | type | on events | scope | presence | cardinality | pii | delta | notes`

| column | meaning |
|---|---|
| key | the wire key |
| type | JSON type as encoded: `string`, `number (int)`, `number (double)`, `bool` |
| on events | event / metric names, or `context` (rides every event) or `all` (rider on every event and metric) |
| scope | `context` (flush-time snapshot), `rider` (stamped at enqueue), `event` (set by the emitter) — clause 3 |
| presence | `required` (always present when the event fires, in the target state) or `optional`. Where as-is presence differs, the note says so |
| cardinality | `bounded enum` (members inline — that list is the contract), `unbounded string`, or `numeric` |
| pii | one of the four classes in §3 |
| delta | `shared` (in-repo evidence that Android sends the same key with the same meaning — the collector's required-identity set in `CLAUDE.md`, or the trace v3 contract per [#168][I168]), `iOS-only` (no in-repo evidence of an Android twin, or a known divergence), or `renamed-from <Android name>`. The Android name list lives outside this repo ([W2][W2]), so `iOS-only` is the conservative default: the Processor routes it on the iOS path. The backend team should downgrade rows to `shared` where Android already matches. `legacy-spelled` marks a name frozen despite breaking the forward style rule ([W13 Rename batch][W13]) |
| notes | read-time caveats, absence meaning, and the **change tag** |

**Event registry** — `name | wire type | value (unit) | trigger | span | delta | notes`

| column | meaning |
|---|---|
| wire type | `event` or `metric` (`Event.swift:25-26`); the Processor branches on this |
| value (unit) | the metric scalar and its unit; `—` for events |
| span | `yes (v3 §n)` cites the trace v3 section that defines the event's span role; all trace keys land with T11 |

### 1.2 Change tags

Every row that differs from the as-is wire starts its notes with one tag:

| tag | meaning |
|---|---|
| **+Tn** | added by tranche n |
| **−Tn** | deleted by tranche n (row stays listed) |
| **→Tn** | renamed by tranche n; the old row is listed as deleted, the new row as added with "renamed from" |
| **~Tn** | same name and unit, but the value, trigger, presence or cardinality changes — a value correction, shipped with its feature tranche plus a release-note line ([W14][W14] rule) |

Untagged rows are unchanged from as-is.

### 1.3 Tranches (from [W14][W14])

| # | short name | epic | contents relevant to the wire |
|---|---|---|---|
| T0 | hot path | F25 [#212][E212] | O1 sidecar inversion, `sdk.thread_time_ms`, `_enabled` guard in `Recorder.enqueue` |
| T1 | doc-truth | F26 [#213][E213] | arm `flushInterval`, `maxQueueSize` counts events, whole-process CPU reader + `hang.cpu_usage` wired, threading docs, delete dead `Recorder.queue`, retire the carrier TODO |
| T2 | privacy | F27 [#214][E214] | `clearUser()`, `resetIdentity()`, identity keys off the sidecar, `button_title` default-off + `interaction.name_source`, `PrivacyContractTests` |
| T3 | riders | F28 [#215][E215] | volatile box, `device.orientation`, `app.state`, `device.family`, `screen.name` rider |
| T4 | breaking batch | F29 [#216][E216] | every delete, rename, event-name split and unit change; one migration note, `1.0.0-alpha.N` |
| T5 | sampler cut | F30 [#217][E217] | motion-window frames, memory 30 s + last-observed pressure, `cpu_usage` (reusing T1's reader), one sampling gate |
| T6 | breadcrumbs | F31 [#218][E218] | ring, `breadcrumbs.json`, `breadcrumbs` + `breadcrumb.dropped`, `captureBreadcrumbs` |
| T7 | SDK health | F32 [#219][E219] | envelope counters, high-water marks, capability failures, `_buffer` cap |
| T8 | error evidence | F33 [#220][E220] | `error_type`, `crash.mach_exception`, `previous_session.*`, `device.boot_time`, two-phase hang, disjoint `long_task`, observed `frame.dropped_count` |
| T9 | launch | F34 [#221][E221] | `launch.pre_sdk_duration_ms`, anchor move, `sdk.start_duration_ms`, `sdk.start_replayed_crash`, clamp → omit |
| T10 | radio | F35 [#222][E222] | `network.effectiveType` resolves `2g`–`5g` |
| T11 | tracing | F24 [#169][I169] | every trace v3 attribute |
| T12 | actions | F36 [#223][E223] | `action.started` / `action.ended`, `action.*` |
| T13 | host-gated | F37 [#224][E224] | `screen_ready`, `launch_interactive` (`markScreenReady()`, `markInteractive()`) |
| — | next breaking batch | — | deferred: `resource.host` / `resource.redirect_count` / `resource.protocol` deletion after T11 |
| — | symbolication epic | unranked | upload tooling + symbol store, backend-dependent, unranked; its SDK half is inside T4 |

---

## 2. Envelope

`EventEnvelope.swift:31-64`. One envelope per flush, `POST <endpoint>/collector/telemetry`,
`Content-Type: application/json`, `X-API-Key` starting `edge_`. JSON only — no compression.

### 2.1 Batch fields

| field | type | presence | pii | notes |
|---|---|---|---|---|
| `type` | string | required | none | always `"telemetry_batch"` |
| `timestamp` | string | required | none | ISO 8601 with fractional seconds, stamped at **flush** |
| `location` | string | optional | content | `City/Country`. **~T4 breaking batch:** sourced from `EdgeRumConfig.location` only — `resolveLocation` and `locationProviderUrl` are deleted ([W7 PII classes][W7]); as-is they are dead config, referenced nowhere in `Sources/`, so no device IP has ever reached `ipapi.co`. Migration: set `config.location` yourself |
| `batch_size` | number (int) | required | none | `events.count` |
| `events` | array | required | — | items below |

**Per item** (`EventEnvelope.swift:66-99`):

| field | on | type | notes |
|---|---|---|---|
| `type` | all | string | `"event"` or `"metric"` |
| `eventName` | event | string | allowlisted (`Recorder.allowedEventNames`): 12 as-is (11 reachable, D1) → 13 after T4 (+`app.error`, +`app.hang`, −`screen.duration`) → 15 after T12 (+`action.started`, +`action.ended`) |
| `metricName` | metric | string | as-is **ungated** (D7). **~T4 breaking batch:** allowlisted — `resource_timing`, `long_task`, `frame_render_time`, `memory_usage`, `cpu_usage`, `custom_timer`; +`screen_ready` and `launch_interactive` at T13 (8 names). Off-list names are rejected at ingress and counted as a drop |
| `value` | metric | number (double) | **omitted when nil**. Unit per name, §6 |
| `timestamp` | all | string | ISO 8601 with fractional seconds, stamped at emission |
| `attributes` | all | object | flat `[String: AttributeValue]`, four scalar cases only (`AttributeValue.swift:35-38`); nesting is unrepresentable. Structured payloads travel as JSON **strings** (`crash.report_json`, `breadcrumbs`, `*.binary_images`) |

### 2.2 SDK health counters — envelope-level ([W8][W8], [W9 Launch][W9])

**Cumulative totals since scope start, never deltas**, so any one report that lands is correct and
loss cannot corrupt the number. Emitted on the envelope once per upload, stamped with the session
they describe. They **follow session sampling** (an unsampled session issues no request to report
that it did nothing) — but because `app.crash` is forced-emit, crashing unsampled sessions upload
and carry counters: the broken tail is covered for free. **Wire-only**: no host-facing accessor.
All integers except `sdk.capabilities_failed` and `sdk.start_replayed_crash`. `sdk.queue_depth_max` and
`sdk.storage_bytes_max` are omitted when `offline_queue` failed (omit, never falsify).

| key | type | scope (W8) | presence | pii | delta | notes |
|---|---|---|---|---|---|---|
| `sdk.thread_time_ms` | number (int) | session | required | none | iOS-only | **+T0 hot path.** Cumulative wall-time inside SDK entry points on the caller's thread — the attributable replacement for `sdk_cpu_usage`. O1's before/after acceptance instrument. Near-total SDK cost because the whole ingress path runs on the caller's thread (§12 C1) |
| `sdk.events_generated` | number (int) | session | required | none | iOS-only | **+T7 SDK health.** Gap detection: compare against events received ([W18 Session boundary][W18] — no per-event ordinal) |
| `sdk.events_dropped.sampled` | number (int) | session | optional | none | iOS-only | **+T7.** Sampler discards (`Recorder.swift:337-340`). Omitted when zero |
| `sdk.events_dropped.unknown_name` | number (int) | session | optional | none | iOS-only | **+T7.** Event- and metric-allowlist rejections. Omitted when zero |
| `sdk.events_uploaded` | number (int) | process | required | none | iOS-only | **+T7.** Process-scoped: the queue outlives the process, so uploads are not attributed to a session. Resets on process death — a device that crashes constantly reports low totals repeatedly |
| `sdk.batches_uploaded` | number (int) | process | required | none | iOS-only | **+T7** |
| `sdk.upload_failures` | number (int) | process | optional | none | iOS-only | **+T7.** Omitted when zero |
| `sdk.events_dropped.queue_overflow` | number (int) | process | optional | none | iOS-only | **+T7.** Counts **events**, not files — one file overflow is ~30 events. Includes T1's event-count trims |
| `sdk.events_dropped.encode_failure` | number (int) | process | optional | none | iOS-only | **+T7.** `HTTPTransportSink.swift:102-116` |
| `sdk.events_dropped.non_retryable` | number (int) | process | optional | none | iOS-only | **+T7.** Non-retryable 4xx (`:165-173`) |
| `sdk.events_dropped.enqueue_failure` | number (int) | process | optional | none | iOS-only | **+T7.** Offline enqueue returning `nil`, discarded today at `HTTPTransportSink.swift:149` — an undetected total loss in `1.0.0-alpha.2` |
| `sdk.queue_depth_max` | number (int) | process | required | none | iOS-only | **+T7.** High-water mark (monotonic), not a gauge — answers "did it come close to the cap?" |
| `sdk.storage_bytes_max` | number (int) | process | required | none | iOS-only | **+T7.** High-water mark of on-disk footprint; needs a size walk `OfflineQueue.orderedFiles()` does not do today |
| `sdk.capabilities_failed` | string | process | optional | none | iOS-only | **+T7.** Comma-joined, one-shot: the whole subsystem is blind for the process, so it rides every envelope of the process (ADR-023). Bounded members: `interaction_swizzle`, `http_swizzle`, `crash_reporter`, `hang_observer`, `offline_queue`, `keychain`. `keychain` also carries `deviceIdFromFallback` ([W22 Doc-truth][W22] #6) — `device.id` durability degraded. Absent when nothing failed |
| `sdk.start_duration_ms` | number (int) | session | required | none | iOS-only | **+T9 launch.** Duration of the `EdgeRum.start()` call only — not process-start-to-ready (C4's mistake one level down). Monotonic; omitted if unreadable. Set at the end of `start()`, so the crash-replay envelope flushed *inside* `start()` lacks both T9 keys; every later envelope of the process carries them, rotation included (ADR-025) |
| `sdk.start_replayed_crash` | bool | session | required | none | iOS-only | **+T9 launch.** Separates the bimodal start-duration population: crash-replay launches do disk, parse and network work no other launch does |

**Unit of cost:** context keys cost one copy per *event* in the batch (merged into each), riders
one per event, envelope counters one per *batch*.

---

## 3. PII classes ([W7][W7] §1–§2)

**The class describes the wire; it does not instruct the SDK.** The SDK's privacy guarantee is
what it declines to collect (§7), not what it scrubs after collecting.

### 3.1 The closed vocabulary — four classes

| class | means | examples |
|---|---|---|
| `none` | no personal data possible by construction — numbers, enums, and strings whose **value is fixed at compile time** | `http.duration_ms`, `lifecycle.state`, `interaction.target` (a reflected type name), `interaction.name_source`, `*.binary_images` |
| `pseudonymous` | SDK-minted random value, linkable across events within its scope, not to a person without a host-side join | `device.id`, `session.id`, `user.id`, `action.id`, trace ids |
| `identity` | names a person directly; only ever arrives via a host call | `user.name`, `user.email`, `user.phone`, `user.external_id` — **exactly these four; that is an invariant** (asserted by `PrivacyContractTests`, T2) |
| `content` | free text whose **value is chosen at runtime**, captured implicitly from the running app — may contain anything | `error.message`, `error.stack`, `crash.report_json`, `crash.exception_reason`, `long_task.stack`, `screen.name`, `navigation.screen`, `event.name`, `timer.name`, host `track` attributes, `interaction.name` (button-title branch), `http.path`, `breadcrumbs` |

**Boundary rule: compile-time vs runtime value, not SDK-vs-host origin.** It is the only version
that is mechanically checkable — point at the code that produces the value and answer it — and it
puts `screen.name` and `event.name` on the same side. An origin rule gets `interaction.target`
wrong one way (SDK-derived, reflected, but compile-time in value) and `crash.report_json` wrong the
other.

**`content` is the largest class.** The Processor needs to hear that before it indexes
`screen.name` — which after T3 rides every event — as a grouping dimension.

**`credential` is not a class.** A class with no members is a claim. Credentials belong to §7.

### 3.2 Class → handling

| class | SDK behaviour | downstream obligation (advisory) |
|---|---|---|
| `none` | send as-is | free to index, group, filter |
| `pseudonymous` | send as-is | joinable; delete on erasure request |
| `identity` | send as-is | restricted access; never a grouping dimension; host's retention policy governs |
| `content` | send as-is | never indexed, never a filter; shortest retention |

The downstream column is advisory: this catalogue specifies what a class *means*; the backend team
decides what their store does.

### 3.3 Structural strips and identity handling

- **Structural, never filtered at emit.** Anything sourced implicitly is capped at `content` and
  must be off-by-default or structurally stripped. Hence: `http.url` / `resource.url` deleted (query
  strings drop structurally, T4); free-text `http.error` deleted for typed `http.error_domain` + `http.error_code` (T4); `button_title`
  default-off (T2). `sanitizeUrl` survives for path segments only the host knows are sensitive.
- **Identity passes through untransformed.** No hashing, no truncation. Calling `identify()` is
  the host's assertion of consent.
- **`EdgeRum.clearUser()`** (T2) — the non-merging path. As-is `identify()` merges with
  nil-keeps-old semantics, so it cannot express "a different person": a logged-out user's email
  rides every event until process death.
- **`EdgeRum.resetIdentity()`** (T2) — erasure hook; regenerates `device.id` and `user.id`.
- **Sidecar** — T2 drops `user.name`/`user.email`/`user.phone` from `SessionSidecar.mirroredKeys`;
  `user.id` stays (it joins the crash to the session).
- **Consent lever: `EdgeRum.disable()`** halts capture and emission and preserves the on-disk queue.
  It uninstalls the hang detector and `enable()` does not re-arm it, so consent granted late loses
  hang detection for that process.
  > **Dated correction (2026-10-05, `1.0.0-alpha.2`):** `disable()` is **partially inoperative**.
  > `_enabled` is never checked in `Recorder.recordEvent` / `recordPerformance` / `enqueue` /
  > `flush`, so `EdgeRum.track`, `captureError`, `RumTimer.end` and the three SwiftUI emitters
  > (`ViewModifiers.swift:42-56,66-83,89-100`) bypass it. Fixed by one guard in `Recorder.enqueue`
  > in **T0 hot path**. Until then this section's guarantee holds for automatic capture only.

### 3.4 Breadcrumb label

The breadcrumb row's `l` field is `content`, inheriting its sources (screen names, tap labels,
`http.path`, `event.name`). There is no breadcrumb-specific privacy switch; `captureBreadcrumbs`
turns the feature off (§5.12).

---

## 4. Event registry

### 4.1 Events (`type = "event"`)

| name | wire type | value (unit) | trigger | span | delta | notes |
|---|---|---|---|---|---|---|
| `session.started` | event | — | `Recorder.start()` with no live session (`Recorder.swift:289`); lazy rotation in `SessionManager.touch()` when idle ≥ 30 min (`:518`) — **~T4 breaking batch:** also at the **4 h** maximum-duration cap | no | iOS-only | Forced-emit. Two attribute sets (D2): plain start has no event attributes; rotation carries `session.rotation`. **+T8 error evidence:** carries `previous_session.*` + `device.boot_time` |
| `session.finalized` | event | — | as-is: `Recorder.stop()` (`:306`), **every** `willResignActive` and `willTerminate` (`LifecycleCapture.swift:134`), idle rotation (`:514`). **~T4 breaking batch:** rotation only (`idle` or `max_duration`); resign / terminate / `stop()` call `flush(reason: .immediate)` directly and emit nothing | no | iOS-only | Forced-emit; forces an immediate flush. **As-is it marks a flush, not a session end** (C3): Control Centre, a call, an app-switcher peek or a Face ID prompt each emit one, and nothing rotates, so one `session.id` carries many. After T4: one per ended session, **detected lazily** at the first event after the gap (possibly the next launch). A session never resumed gets **none** — a missing finalized is normal, not a crash or OOM signal. `timestamp` is detection time; the end is `session.end_time` |
| `app_lifecycle` | event | — | five `UIApplication` notifications (`LifecycleCapture.swift:150-185`) | yes (v3 §4.4) — root set on `foregrounded` **only when it mints**, T11 | iOS-only | Sampled. The transition (delta) form; `app.state` (+T3 rider) is the absolute form. A `foregrounded` event without trace keys means the peek was absorbed by a surviving root |
| `page_load` | event | — | first `CADisplayLink` tick while `.active` (`PageLoadCapture.swift:224`) | yes (v3 §4.1) — launch root set, T11 | iOS-only | **One-shot per process** — a resume never produces one. Sampled; a 10% sample of a duration distribution is statistically fine ([W9][W9]), so it is not forced. Time to first frame = `launch.pre_sdk_duration_ms + page_load.duration_ms` exactly; no third attribute |
| `navigation` | event | — | `viewDidAppear` swizzle (`UIViewControllerCapture.swift:309`); `.edgeRumScreen` `onAppear` (`ViewModifiers.swift:54`); `EdgeRum.trackScreen` (`EdgeRum.swift:340`) | yes (v3 §4.3) — root set when it mints, else child span, T11 | iOS-only | Three producers. As-is three attribute sets (D3); **~T4 breaking batch:** one shape — `navigation.screen` + `navigation.kind` on all three. The screen box is written **before** emit, so the `screen.name` rider equals the screen entered. SwiftUI hosts without `.edgeRumScreen` get the hosting-root name (coarse, never null). Dwell is synthesized by the Processor from consecutive `navigation` events ([#144][I144]) |
| `http.request` | event | — | `URLSessionTaskMetrics` delegate (`HTTPCapture.swift:350`); **+T11:** also `stopLoading()` with `URLError(.cancelled)` (v3 §11.4) | yes (v3 §11) — full child span + `traceparent.outcome`, T11 | iOS-only | Filter → `ignoreUrls` → `sanitizeUrl`. **Network failures live here** (`http.error` as-is; `http.error_domain` + `http.error_code` from T4; plus `http.status_code`) — `network_error` / `timeout` / `server_error` are never duplicated into `app.error`, which would double-count every failure. Durations inherit an SDK-induced latency profile (O3: a fresh ephemeral `URLSession` per intercepted request; out of scope) |
| `user.interaction` | event | — | `UIWindow.sendEvent` swizzle, touch `.ended` (`InteractionCapture.swift:180`); `.edgeRumTrackTap` (`ViewModifiers.swift:98`) | yes (v3 §4.2) — root set + `interaction.name_source`, T11; **suppressed entirely** on a secure-entry tap | iOS-only (Android: `ui.interaction`) | Two producers. As-is disjoint keys (D4); **~T4:** one label key, `interaction.name`. Name kept: the Processor's `ui.interaction` switch is the Processor's defect (§10 P1); `ui.*` stays unclaimed on iOS. No auto-promotion of taps to actions |
| `network_change` | event | — | `NWPathMonitor` transition, deduped by fingerprint (`NetworkPathCapture.swift:242`); **+T10 radio:** also `CTServiceRadioAccessTechnologyDidChangeNotification` (fingerprint already includes `effectiveType`) | no | iOS-only | Forced-emit. One name covers available / lost / changed: `network.type = none` plus `network.unsatisfied_reason` distinguish them. **An unpaired `network.type = none` means the app was killed or suspended while offline — normal, not a defect.** Offline duration is not emitted (§8) |
| `user.profile.update` | event | — | `EdgeRum.identify()` → `Recorder.setUser` (`Recorder.swift:395`) | no | iOS-only | Carries only the identity keys the host supplied |
| `custom_event` | event | — | `EdgeRum.track(_:attributes:)` (`EdgeRum.swift:330`) | no | iOS-only | Legacy-spelled, kept ([W13][W13]). The host's name travels as `event.name`, because unknown `eventName`s are rejected by the allowlist and dropped by the Processor |
| `app.crash` | event | — | as-is: three producers — `captureError` (`EdgeRum.swift:384`), hang watchdog (`HangDetector.swift:334`), native crash replay (`PLCrashIntegration.swift:174`). **~T4 breaking batch:** PLCrashReporter replay **only**, on the next launch | yes (v3 §12) — join keys only (`trace.id`, `rum.action.id`, `trace.root_expired`), T11 | iOS-only | **Forced-emit, forces a flush — reserved for the process dying.** As-is `cause` discriminates three disjoint bags (D5); after T4 the name does. Identity from the sidecar (previous session); riders from the volatile zone; network/battery from the reporting launch. Exception wins (§0 clause 5) |
| `app.error` | event | — | **+T4 breaking batch:** `EdgeRum.captureError(_:context:)`; **+T8:** `captureError(_:type:context:)` | no — v3 §12 annotates crash and hang only (§14 open item) | iOS-only | **Sampled, no forced flush.** As-is these ride `app.crash` with `cause = AppError` and get crash privileges: sampler bypass plus a network flush on the caller's thread, unbounded in frequency. Correlation (`screen.name`, `action.id`) via riders |
| `app.hang` | event | — | **+T4 breaking batch:** `HangDetector`, emitted at threshold crossing (as-is behaviour, renamed). **~T8 error evidence:** two-phase — live emit at **stall end** with the real duration, or next-launch replay of a persisted pending-hang record with `hang.terminated = true` | yes (v3 §12) — join keys only, follows the hang annotation off `app.crash`, T11 | iOS-only | **Sampled, no forced flush** — a hang is a rate question on a live process. Ladder (§6.2): `long_task` [50 ms, `hangTimeout`) → `app.hang` [`hangTimeout`, ∞), with `hangTimeout` clamped to the watchdog's 2 s floor (ADR-024). Replayed hangs carry the previous session's identity via the sidecar, as `app.crash` does |
| `action.started` | event | — | **+T12 actions:** `EdgeRum.startAction(_:)` | no | iOS-only | Follows session sampling (forcing would create actions whose `action.id` joins to nothing). The only record that survives a process death mid-action |
| `action.ended` | event | — | **+T12 actions:** `complete()` / `fail(reason:)` on the handle; `abandoned` at exactly three deterministic points — session rotation with the action open, next launch for actions open at process death, 10 min ceiling | no | iOS-only | One event and one outcome enum instead of the checklist's three names. The SDK never emits `abandoned` speculatively while the action could still complete. Duration = `action.ended.timestamp − action.started.timestamp` (analytics-side) |
| `screen.duration` *(event allowlist entry)* | — | — | never emitted as an event (D1) | — | — | **−T4 breaking batch:** removed from `Recorder.allowedEventNames` |

### 4.2 Metrics (`type = "metric"`)

| name | wire type | value (unit) | trigger | span | delta | notes |
|---|---|---|---|---|---|---|
| `screen.duration` | metric | dwell, **seconds** | `viewWillDisappear` (`UIViewControllerCapture.swift:337`); `.edgeRumScreen` `onDisappear` (`ViewModifiers.swift:81`) | yes (v3 §11.1), moot | iOS-only | **−T4 breaking batch** ([#144][I144], via [W13][W13]). Still emitted at `1.0.0-alpha.2`. Mixed units on one row (D6). The Processor synthesizes dwell from `navigation`. The `viewWillDisappear` swizzle survives for `screen_ready`'s abandon row |
| `resource_timing` | metric | request duration, **ms** | emitted beside `http.request` when `URLSessionTaskMetrics` yielded a timing (`HTTPCapture.swift:371`) | yes (v3 §11.3) — join keys only, **same `span.id` as its own `http.request`**, never `traceparent.outcome`, T11 | iOS-only | Roughly doubles HTTP volume. Stays `type: metric` ([W13][W13]); the Processor must promote metrics (§10 P2) |
| `long_task` | metric | stall, **ms** | run-loop gap ≥ threshold, default 50 ms (`RunLoopObserverCapture.swift:132`); **~T8:** dropped when `enableHangDetection && duration ≥ hangTimeout` (disjoint rungs — that stall is an `app.hang`); the ceiling is the watchdog's effective threshold, `hangTimeout` clamped to its 2 s floor (ADR-024) | no (v3 §12 excludes it) | iOS-only | The duration exists only as `value`, and that is the contract ([W16][W16]) — no new key |
| `frame_render_time` | metric | worst frame of the window, **ms** | as-is: every 1 s window while the display link runs, unconditionally (~3,600 / foreground hour). **~T5 sampler cut:** one per **motion window** — armed by touch begin/end and screen transitions, closes ~2 s after the last, hard cap 10 s; display link paused otherwise; gated | no | iOS-only | ~100–300 / foreground hour after T5 (estimate; O1's measurement carries it). Un-touched animations go unmeasured — accepted cost |
| `memory_usage` | metric | resident set, **kB → MB at T4** | every 10 s (`MemorySampler.swift:241`) **~T5:** every **30 s**, gated; plus every memory-pressure event (ungated) | no | iOS-only | **~T4 breaking batch:** unit kB → MB ([#145][I145]; see §13 X1 on the frozen-unit rule). Sole authority for memory — memory is not context ([W10][W10]); join on `session.id` + timestamp |
| `cpu_usage` | metric | whole-process CPU, **percent** (per-core sum, may exceed 100) | **+T5 sampler cut:** on the memory tick, gated | no | iOS-only | Reuses T1's reader (`task_info(TASK_THREAD_TIMES_INFO)` plus dead-thread times, delta over wall time); built here if T1 has not shipped. Whole process only — the SDK's own share is not honestly measurable ([W8][W8]). Each sample is self-contained; loss drops a point and corrupts nothing |
| `custom_timer` | metric | elapsed, **ms** | **+T4 breaking batch:** `EdgeRum.time(_:).end()` (`RumTimer.swift:62`) | no | iOS-only | Replaces host-named metrics; the host's name moves to `timer.name`. Public API unchanged |
| `screen_ready` | metric | appear → ready, **ms**; on `abandoned`, appear → leave (a censored value) | **+T13 host-gated:** `EdgeRum.markScreenReady()` consuming the pending appear token; or disappear of a learned screen with the token unconsumed | no | iOS-only | Anchor is the `navigation` timestamp (appear). No name parameter — the screen comes from the box, so host and SDK names cannot disagree; a mark after the box changed or the token was consumed is a no-op. Host-adoption-gated: unmarked screens produce nothing. Hole on record: a screen's first appear in each process, before its first mark, cannot be judged |
| `launch_interactive` | metric | `launchStart` → host-marked interactive, **ms** | **+T13 host-gated:** `EdgeRum.markInteractive()` — once per process, first call wins | no | iOS-only | Same anchor as `page_load.duration_ms`, so `launch.pre_sdk_duration_ms + launch_interactive` is process-to-interactive. A metric because `page_load` has already left. Absent when the host never calls it; a second call is a no-op. Roadmap §10 row 13 |
| *host-supplied name* | metric | elapsed, **ms** | `EdgeRum.time(name).end()` | no | iOS-only | **−T4 breaking batch** → `custom_timer`. As-is the `metricName` is an unbounded host string (D7) |

**Totals.** As-is: 11 reachable event names (12 allowlisted) + 5 fixed metric names + an unbounded
host metric namespace. After every tranche: **15** event names and **8** metric names, both
allowlisted; no unbounded name space remains.

---

## 5. Attribute registry

Attributes are defined exactly once; event rows never restate them.

### 5.1 Context — `scope = context` (45 keys)

Written by `ContextProvider.snapshot()`; namespaces are disjoint (`ContextProvider.swift:70-81`).
Merged into every event at flush; event and rider values win on key conflict.

| key | type | on events | scope | presence | cardinality | pii | delta | notes |
|---|---|---|---|---|---|---|---|---|
| `app.name` | string | context | context | optional | unbounded string | none | shared | Config override or `Info.plist` (`AppContext.swift:79`) |
| `app.package_name` | string | context | context | optional | unbounded string | none | shared | Not `app.package` |
| `app.version` | string | context | context | optional | unbounded string | none | shared | |
| `app.build_number` | string | context | context | optional | unbounded string | none | shared | Omitted when nil |
| `app.environment` | string | context | context | optional | bounded enum: `production`, `staging`, `development` | none | shared | Absent unless `EdgeRumConfig.environment` is set |
| `app.background_refresh` | string | context | context | optional | bounded enum: `available`, `denied`, `restricted`, `unknown` | none | iOS-only | `StorageContext.swift:95-101` |
| `device.platform` | string | context | context | required | bounded enum: `ios` | none | shared | Constant |
| `device.manufacturer` | string | context | context | required | bounded enum: `Apple` | none | shared | Constant |
| `device.os` | string | context | context | required | bounded enum: `ios` | none | shared, legacy-spelled | Constant duplicate of `device.platform` (D12); frozen — part of the collector's required-identity gate ([W13][W13]) |
| `device.platform_version` | string | context | context | optional | unbounded string | none | shared | Not `device.osVersion` |
| `device.model` | string | context | context | optional | unbounded string | none | shared | Simulator reports `Simulator` / `SIMULATOR_MODEL_IDENTIFIER`; iPad-on-Mac and Catalyst report a `Mac*` identifier (`DeviceContext.swift:203-213`) — use `device.family` |
| `device.family` | string | context | context | required | bounded enum: `phone`, `pad`, `mac`, `unknown` | none | iOS-only | **+T3 riders.** `userInterfaceIdiom`, one read at snapshot. Not derivable from `device.model` in three cases (simulator, iPad app on Apple Silicon, Catalyst). Members fixed here (§13 X6) |
| `device.isVirtual` | bool | context | context | required | — | none | shared, legacy-spelled | Simulator flag. CamelCase frozen (D10) |
| `device.screenWidth` | number (int) | context | context | optional | numeric | none | shared, legacy-spelled | **Pixels**, from `UIScreen.main.nativeBounds` (`DeviceContext.swift:231`) — orientation-independent. (The W2 inventory said points; corrected.) |
| `device.screenHeight` | number (int) | context | context | optional | numeric | none | shared, legacy-spelled | As above |
| `device.pixelRatio` | number (double) | context | context | optional | numeric | none | shared, legacy-spelled | |
| `device.batteryLevel` | number (double) | context | context | optional | numeric | none | shared, legacy-spelled | Sampled; flush-time and up to 5 min stale |
| `device.batteryCharging` | bool | context | context | optional | — | none | shared, legacy-spelled | Sampled; as above |
| `device.locale` | string | context | context | optional | unbounded string | none | iOS-only | |
| `device.timezone` | string | context | context | optional | unbounded string | none | iOS-only | |
| `device.timezone_offset_min` | number (int) | context | context | optional | numeric | none | iOS-only | |
| `device.id` | string | context | context | required | unbounded string | pseudonymous | shared | `device_<epochMs>_<16 hex>_ios`; Keychain-backed. SDK-owned — not IDFA, not IDFV (§7). On a replayed crash/hang: the crashed session's value. Regenerated by `resetIdentity()` (T2) |
| `device.thermal_state` | string | context | context | optional | bounded enum: `nominal`, `fair`, `serious`, `critical` | none | iOS-only | `PowerContext.swift:63-69`; sampled. `serious`+ closes the sampling gate (T5) |
| `device.low_power_mode` | bool | context | context | optional | — | none | iOS-only | Sampled. `true` closes the sampling gate (T5) |
| `device.dynamic_type` | string | context | context | optional | bounded enum: UIKit content-size categories | none | iOS-only | `AccessibilityContext.swift:78` |
| `device.reduce_motion` | bool | context | context | optional | — | none | iOS-only | |
| `device.bold_text` | bool | context | context | optional | — | none | iOS-only | |
| `device.voiceover` | bool | context | context | optional | — | none | iOS-only | |
| `device.increase_contrast` | bool | context | context | optional | — | none | iOS-only | |
| `device.disk_free_mb` | number (int) | context | context | optional | numeric | none | iOS-only | Refreshed every 5 min + on lifecycle |
| `device.disk_total_mb` | number (int) | context | context | optional | numeric | none | iOS-only | |
| `network.type` | string | context, `network_change` | context | required | bounded enum: `wifi`, `cellular`, `wired`, `none`, `unknown` | none | shared | `NetworkContext.swift:30-35`. On `network_change` the event's emit-time value wins |
| `network.effectiveType` | string | context, `network_change` | context | required | bounded enum (**~T10**): `2g`, `3g`, `4g`, `5g`, `wifi`, `wired`, `unknown` — was `wifi`, `cellular`, `wired`, `unknown` | none | shared key, legacy-spelled — **measurement differs**: iOS reports radio access technology, web reports throughput | **~T10 radio.** Before T10 it could never produce its documented enum (C1: `cellular` was written and is not a member). From T10 (`NetworkContext.generation(radio:)`): `CTTelephonyNetworkInfo.serviceCurrentRadioAccessTechnology[dataServiceIdentifier]`, consulted only when `NWPath` is cellular — `GPRS`/`Edge`/`CDMA1x` → `2g`; `WCDMA`/`HSDPA`/`HSUPA`/`CDMAEVDORev0/A/B`/`eHRPD` → `3g`; `LTE` → `4g`; `NRNSA`/`NR` → `5g`; anything else or nil → `unknown`, never `cellular`. **`4g` on iOS means "LTE radio", not "fast"** — do not pool with web's distribution |
| `network.expensive` | bool | context, `network_change` | context | required | — | none | iOS-only | **~T4 breaking batch:** `network_change` writes this key (renamed from `network.is_expensive`) with its emit-time value, overriding the flush-time context value. As-is both spellings appear on that event (D8) |
| `network.constrained` | bool | context, `network_change` | context | required | — | none | iOS-only | **~T4 breaking batch:** as above, renamed from `network.is_constrained` |
| `network.interface` | string | context | context | optional | unbounded string | none | iOS-only | e.g. `en0` |
| `session.id` | string | context | context | required | unbounded string | pseudonymous | shared | `session_<epochMs>_<16 hex>_ios`. Restated on rotation `session.finalized` so it carries the *ended* session (D2) |
| `session.start_time` | string | context | context | required | unbounded string | none | shared | ISO 8601; captured at creation, never updates |
| `session.sequence` | number (int) | context | context | required | numeric | none | shared | **A transport counter**, incremented per ACKed batch (`SessionContext.swift:106-116`) — not an event ordinal and cannot detect gaps; kept for web/Android parity ([W18][W18]). Gap detection is `sdk.events_generated` |
| `user.id` | string | context | context | required | unbounded string | pseudonymous | shared | `user_<epochMs>_<16 hex>` — **no `_ios` suffix**. SDK-owned anonymous id, unchanged by `identify()`; regenerated by `resetIdentity()` (T2) |
| `user.name` | string | context, `user.profile.update` | context | optional | unbounded string | identity | shared | Present after `identify()`, verbatim. **~T2 privacy:** cleared by `clearUser()`; off the sidecar, so absent on replayed crashes |
| `user.email` | string | context, `user.profile.update` | context | optional | unbounded string | identity | shared | As above |
| `user.phone` | string | context, `user.profile.update` | context | optional | unbounded string | identity | shared | As above |
| `sdk.version` | string | context | context | required | unbounded string | none | shared | Build-plugin generated |
| `sdk.platform` | string | context | context | required | bounded enum: `ios-native` | none | shared key, iOS value | Constant; a value new to the backend |

### 5.2 Riders — `scope = rider`

Stamped at enqueue from the lock-free latest-wins box (T3 builds it; [W5][W5], [W6][W6],
[W10][W10] and [W17 Screen attribution][W17] are its consumers). Each rider also rides the sidecar's
**volatile zone** — coalesced, best-effort, written on change — so a replayed crash or hang carries
the value at death. A crash inside the coalescing window lands without it.

| key | type | on events | scope | presence | cardinality | pii | delta | notes |
|---|---|---|---|---|---|---|---|---|
| `screen.name` | string | all | rider | optional | unbounded string, **128 B cap** | content | iOS-only | **+T3 riders.** The screen showing when the event fired, written by all three entry points (UIKit `viewDidAppear`, `.edgeRumScreen`, `trackScreen`). Absent, never empty, until the first screen appears. SwiftUI without `.edgeRumScreen`: hosting-root name. **One-level restore** on dismiss (`.pageSheet` / `.sheet` do not re-fire the presenter's appear); sheet-on-sheet goes stale. On `navigation`, equals the screen entered. Until T4 deletes `screen.duration`, that metric's own event value (the screen whose dwell it is) overrides the rider. Not a `screen.duration` signal (§10) |
| `screen.name.truncated` | number (int) | all | rider | optional | numeric | none | iOS-only | **+T3 riders.** Bytes removed by the 128 B cap. Omitted when zero. Reflected generic names (`ModifiedContent<NavigationStack<…>>`) are the case that needs it |
| `device.orientation` | string | all | rider | optional | bounded enum: `portrait`, `landscape` | none | iOS-only | **+T3 riders.** **Interface** orientation, not `UIDevice` hardware orientation (§7). Upside-down and both landscapes collapse — layout-identical |
| `app.state` | string | all | rider | optional | bounded enum: `active`, `inactive`, `background` | none | iOS-only | **+T3 riders.** `UIApplication.State`'s three — deliberately not `app_lifecycle`'s transition names. `inactive` = visible but not receiving touches (call banner, app switcher, Control Centre). On a replayed crash: foreground vs background death |
| `action.id` | string | all | rider | optional | unbounded string | pseudonymous | iOS-only | **+T12 actions.** The **top** of the open-action stack; absent when no action is open. Distinct from `rum.action.id` (a trace-root id). On `action.started` / `action.ended` the event's own action id wins. `action_<epochMs>_<16 hex>`. Rides the volatile zone, so a replayed crash carries the action open at death; the whole open stack is persisted separately (`open-actions.json`, ADR-027) and closed next launch as `abandoned` / `process_death` |

### 5.3 `session.started` / `session.finalized`

| key | type | on events | scope | presence | cardinality | pii | delta | notes |
|---|---|---|---|---|---|---|---|---|
| `session.rotation` | string | `session.started`, `session.finalized` | event | optional on `started`; **required on `finalized` after T4** | bounded enum: `idle`; **~T4:** + `max_duration` | none | iOS-only | As-is present only on the idle-rotation pair (`Recorder.swift:513-518`) |
| `session.end_time` | string | `session.finalized` | event | required | unbounded string | none | iOS-only | **+T4 breaking batch.** ISO 8601 = the ended session's `lastActiveAt`. Because detection is lazy, `timestamp − session.start_time` is wrong by the whole idle gap; duration = `end_time − start_time`, analytics-side |
| `previous_session.id` | string | `session.started` | event | optional | unbounded string | pseudonymous | iOS-only | **+T8 error evidence.** Absent on first launch after install. The previous **process**'s session: a relaunch inside the 30 min idle window resumes that session, so it can equal this event's own `session.id`. Persisted at lifecycle transitions only, so O1's "`enqueue` never touches the sidecar" stands |
| `previous_session.end` | string | `session.started` | event | optional | bounded enum: `clean`, `crash`, `unknown` | none | iOS-only | **+T8.** `unknown` never means `oom` (§0 clause 6) |
| `previous_session.app_state` | string | `session.started` | event | optional | bounded enum: `foreground`, `background` | none | iOS-only | **+T8.** At the last observed transition. Background terminations are routine and must not read as failures |
| `previous_session.app_version` | string | `session.started` | event | optional | unbounded string | none | iOS-only | **+T8.** Upgrade exclusion |
| `previous_session.os_version` | string | `session.started` | event | optional | unbounded string | none | iOS-only | **+T8.** Upgrade exclusion |
| `device.boot_time` | string | `session.started` | event | optional | unbounded string | none | iOS-only | **+T8.** ISO 8601, one `sysctl KERN_BOOTTIME` read at launch — reboot exclusion. Required-reason API: declare in `PrivacyInfo.xcprivacy` |

### 5.4 `app_lifecycle` and `page_load`

| key | type | on events | scope | presence | cardinality | pii | delta | notes |
|---|---|---|---|---|---|---|---|---|
| `lifecycle.state` | string | `app_lifecycle` | event | required | bounded enum: `inactive`, `backgrounded`, `foregrounded`, `active`, `will_terminate` | none | iOS-only | Transition names, not states (`app.state` is the state) |
| `lifecycle.previous_state` | string | `app_lifecycle` | event | required | same enum plus `unknown` | none | iOS-only | `unknown` on the first emission after install/reset |
| `page_load.duration_ms` | number (int) | `page_load` | event | **optional after T9** (required as-is) | numeric | none | iOS-only | **SDK-start-anchored:** excludes pre-main and all host work before `EdgeRum.start()`. **~T9 launch:** anchor moves to the first line of `start()` (as-is it sits at step 10 of 24, `EdgeRum.swift:189`), so the SDK's whole start cost is a prefix of it; monotonic clock; the `max(0, …)` clamp (`PageLoadCapture.swift:299-304`) becomes **omit** — absent on a clock jump instead of a falsified `0`. Not renamed (roadmap §10 rows 9–10) |
| `page_load.cold_start` | bool | `page_load` | event | required | — | none | iOS-only | **−T4 breaking batch.** It is `!prewarmed` (`PageLoadCapture.swift:293-294`) — a warm launch reports `true` (C5). Warm vs cold is not observable in-process (§8) |
| `page_load.prewarmed` | bool | `page_load` | event | required | — | none | iOS-only | Also says which anchor trace v3 §4.1 used |
| `page_load.source` | string | `page_load` | event | required | bounded enum: `displaylink` | none | iOS-only | Constant |
| `launch.pre_sdk_duration_ms` | number (int) | `page_load` | event | optional | numeric | none | iOS-only | **+T9 launch.** `kinfo_proc.p_starttime` → `launchStart`: dyld, pre-main, static initialisers and host work before the SDK — the dark window. **Absent when `prewarmed`** (the window is zero by construction and meaningless by content), when `sysctl` fails, or when the wall clock ran backwards. Wall-clock (`p_starttime` has no monotonic twin), read at first frame — ADR-025. T9 introduces the one `KERN_PROC_PID` `sysctl` (`PageLoadCapture.processStartTime()`); trace v3's launch root reuses it |

### 5.5 `navigation` and `screen.duration`

| key | type | on events | scope | presence | cardinality | pii | delta | notes |
|---|---|---|---|---|---|---|---|---|
| `navigation.screen` | string | `navigation` | event | **required after T4** (optional as-is) | unbounded string | content | iOS-only | The navigation's **subject**. As-is written by UIKit and `.edgeRumScreen` only. **~T4 breaking batch:** written by all three producers (absorbs `navigation.name`) |
| `navigation.name` | string | `navigation` | event | optional | unbounded string | content | iOS-only | **→T4 breaking batch:** renamed to `navigation.screen`. As-is `EdgeRum.trackScreen` only (D3) |
| `navigation.kind` | string | `navigation` | event | **required after T4** | bounded enum: `uikit`, `swiftui`; **~T4:** + `manual` | none | iOS-only | As-is absent from `trackScreen`; T4 sets `manual` there |
| `navigation.type` | string | `navigation` | event | optional | bounded enum: `viewDidAppear` | none | iOS-only | **−T4 breaking batch.** Constant, and false on SwiftUI |
| `navigation.previous_screen` | string | `navigation` | event | optional | unbounded string | content | iOS-only | The from-edge. UIKit swizzle only, and only when a prior screen was seen |
| `screen.name` *(as `screen.duration`'s subject)* | string | `screen.duration` | event | required | unbounded string | content | iOS-only | **−T4** as an event attribute (deleted with the metric). The key is reused by the T3 rider (§5.2) |
| `screen.kind` | string | `screen.duration` | event | required | bounded enum: `uikit`, `swiftui` | none | iOS-only | **−T4 breaking batch**, with the metric |
| `screen.duration_ms` | number (int) | `screen.duration` | event | required | numeric | none | iOS-only | **−T4 breaking batch**, with the metric |

### 5.6 `http.request` and `resource_timing`

| key | type | on events | scope | presence | cardinality | pii | delta | notes |
|---|---|---|---|---|---|---|---|---|
| `http.method` | string | `http.request` | event | required | bounded enum (HTTP verbs) | none | iOS-only | Defaults to `GET` when nil |
| `http.url` | string | `http.request` | event | required | unbounded string | content | iOS-only | **−T4 breaking batch.** Full `absoluteString` including query and userinfo (tokens, emails, reset links), redundant with `http.host` + `http.path` computed three lines apart (`HTTPCapture.swift:334-338`). The query drops structurally |
| `http.host` | string | `http.request` | event | required | unbounded string | none | iOS-only | `""` when unresolvable. Hosts are endpoint configuration; a host encoding user data in subdomains must use `sanitizeUrl` |
| `http.path` | string | `http.request` | event | required | unbounded string | content | iOS-only | Post-`sanitizeUrl`. Query-free by construction, but path segments carry ids |
| `http.status_code` | number (int) | `http.request` | event | required | numeric | none | iOS-only | **`0` when the response was not an `HTTPURLResponse`** (transport error) |
| `http.duration_ms` | number (int) | `http.request` | event | required | numeric | none | iOS-only | Wall clock, clamped ≥ 0. O3 caveat applies |
| `http.request_size` | number (int) | `http.request` | event | required | numeric | none | iOS-only | `httpBody` is read for `.count` only (`HTTPCapture.swift:504`) |
| `http.response_size` | number (int) | `http.request` | event | required | numeric | none | iOS-only | |
| `http.from_cache` | bool | `http.request` | event | required | — | none | iOS-only | Last transaction `resourceFetchType == .localCache` |
| `http.error` | string | `http.request` | event | optional | unbounded string | content | iOS-only | **−T4 breaking batch.** As-is `String(describing: error)` (`HTTPCapture.swift:346`), which embeds the failing URL with its query. Replaced by `http.error_domain` + `http.error_code` (roadmap §10 row 12). Absent on success |
| `http.error_domain` | string | `http.request` | event | optional | unbounded string | none | iOS-only | **+T4 breaking batch.** The transport error's `NSError` domain (e.g. `NSURLErrorDomain`). Absent on success. With `http.error_code`, this is where `network_error` / `timeout` / `server_error` live. No bounded kind above it; the backend classifies ([W11][W11]) |
| `http.error_code` | number (int) | `http.request` | event | optional | numeric | none | iOS-only | **+T4 breaking batch.** The transport error's code (e.g. `-1001`). Typed, so no consumer re-parses an int out of a string. Absent on success |
| `http.redirect_count` | number (int) | `http.request` | event | optional | numeric | none | iOS-only | The whole enrichment block is absent when metrics are unavailable |
| `http.tls_protocol` | string | `http.request` | event | optional | bounded enum: `1.0`, `1.1`, `1.2`, `1.3` | none | iOS-only | Absent when unencrypted or unrecognised |
| `http.tls_cipher` | string | `http.request` | event | optional | bounded enum (IANA suite names) + `0x%04x` hex fallback | none | iOS-only | |
| `http.reused_connection` | bool | `http.request` | event | optional | — | none | iOS-only | Reads `false` essentially always (O3) |
| `http.proxy_connection` | bool | `http.request` | event | optional | — | none | iOS-only | |
| `http.network_protocol` | string | `http.request` | event | optional | bounded enum (normalised ALPN) | none | iOS-only | |
| `http.request_body_bytes_before_encoding` | number (int) | `http.request` | event | optional | numeric | none | iOS-only | Summed across transactions |
| `http.cellular_fallback` | bool | `http.request` | event | optional | — | none | iOS-only | iOS 17+ only (`HTTPCapture.swift:415`) |
| `traceparent.outcome` | string | `http.request` | event | required after T11 | bounded enum: `skipped_off_allowlist`, `adopted`, `injected_attributed`, `injected_unwired`, `injected_expired`, `injected_unattributed` | none | shared (`injected_expired` populated by iOS only) | **+T11 tracing** (v3 §10). Never on `resource_timing`. The only production signal for trace v3's coverage ceilings (§10 P11) |
| `resource.url` | string | `resource_timing` | event | required | unbounded string | content | iOS-only | **−T4 breaking batch.** Duplicates `http.url` (D13), with its query |
| `resource.host` | string | `resource_timing` | event | required | unbounded string | none | iOS-only | Duplicates `http.host` (D13). Its only link to the request until T11's `span.id`; **deletion deferred to the next breaking batch after T11** |
| `resource.dns_ms` | number (int) | `resource_timing` | event | required | numeric | none | iOS-only | |
| `resource.connect_ms` | number (int) | `resource_timing` | event | required | numeric | none | iOS-only | |
| `resource.tls_ms` | number (int) | `resource_timing` | event | required | numeric | none | iOS-only | |
| `resource.ttfb_ms` | number (int) | `resource_timing` | event | required | numeric | none | iOS-only | |
| `resource.download_ms` | number (int) | `resource_timing` | event | required | numeric | none | iOS-only | Renamed from `resource.response_ms` by ADR-013; `docs/payload-example.jsonc` still shows the old key |
| `resource.redirect_count` | number (int) | `resource_timing` | event | required | numeric | none | iOS-only | Duplicates `http.redirect_count` (D13); deletion deferred as `resource.host` |
| `resource.transaction_count` | number (int) | `resource_timing` | event | required | numeric | none | iOS-only | |
| `resource.fetch_start_to_response_end_ms` | number (int) | `resource_timing` | event | optional | numeric | none | iOS-only | |
| `resource.protocol` | string | `resource_timing` | event | optional | bounded enum (normalised ALPN) | none | iOS-only | Duplicates `http.network_protocol` (D13); deletion deferred as `resource.host` |

### 5.7 `user.interaction`

| key | type | on events | scope | presence | cardinality | pii | delta | notes |
|---|---|---|---|---|---|---|---|---|
| `interaction.kind` | string | `user.interaction` | event | required | bounded enum: `tap` | none | iOS-only | Only completed taps are captured. A tap on or inside a secure-entry field is dropped entirely; `.text` is never read (`InteractionCapture.swift:203-230`) |
| `interaction.target` | string | `user.interaction` | event | optional | unbounded string | none | iOS-only | UIKit only; `String(reflecting:)` of the resolved view type — compile-time value |
| `interaction.target_id` | string | `user.interaction` | event | optional | unbounded string | content | iOS-only | UIKit only. As-is `accessibilityIdentifier` **or** rendered button title — one key, two meanings (D11). **~T2 privacy:** the button-title branch is default-off, so the key is **frequently absent** (§10 P6). **→T4 breaking batch:** renamed to `interaction.name` |
| `interaction.name` | string | `user.interaction` | event | optional | unbounded string | content | iOS-only | As-is `.edgeRumTrackTap` only (D4). **~T4 breaking batch:** the one label key across both producers (absorbs `interaction.target_id`). Absent when `interaction.name_source = none`. Class `content` because the button-title and host branches are runtime values; filter on `interaction.name_source` |
| `interaction.name_source` | string | `user.interaction` | event | required once T2 lands | bounded enum: `accessibility_identifier`, `button_title`, `none`; **~T4:** + `host` | none | iOS-only (Android analogue: `ui.name_source`) | **+T2 privacy** (trace v3 §11.2 spelling, cleared with the backend). `accessibility_identifier` is developer-authored; `button_title` is rendered UI text (opt-in flag from T2); `host` (T4) marks `.edgeRumTrackTap`'s host-supplied name; `none` = nothing resolved, label omitted. See roadmap §10 row 2 |
| `interaction.screen` | string | `user.interaction` | event | optional | unbounded string | content | iOS-only | **−T4 breaking batch.** Replaced by the `screen.name` rider (T3), which also covers SwiftUI and manual screens. Overlaps the rider between T3 and T4 |

### 5.8 `network_change`

| key | type | on events | scope | presence | cardinality | pii | delta | notes |
|---|---|---|---|---|---|---|---|---|
| `network.is_expensive` | bool | `network_change` | event | required | — | none | iOS-only | **→T4 breaking batch:** renamed to `network.expensive` (D8) |
| `network.is_constrained` | bool | `network_change` | event | required | — | none | iOS-only | **→T4 breaking batch:** renamed to `network.constrained` (D8) |
| `network.unsatisfied_reason` | string | `network_change` | event | optional | bounded enum: `not_available`, `cellular_denied`, `wifi_denied`, `local_network_denied`, `vpn_inactive` | none | iOS-only | Absent when the path is satisfied |

`network_change` also overrides `network.type`, `network.effectiveType` and (after T4)
`network.expensive` / `network.constrained` with emit-time values (§5.1).

### 5.9 `user.profile.update`, `custom_event`, `custom_timer`

| key | type | on events | scope | presence | cardinality | pii | delta | notes |
|---|---|---|---|---|---|---|---|---|
| `user.external_id` | string | `user.profile.update` | event | optional | unbounded string | identity | iOS-only | The **host's** id (`Recorder.swift:394`); distinct from SDK-owned `user.id`. One of the four identity keys |
| `event.name` | string | `custom_event` | event | required | unbounded string | content | iOS-only | The host's chosen name |
| `timer.name` | string | `custom_timer` | event | required | unbounded string | content | iOS-only | **+T4 breaking batch.** The host's `EdgeRum.time(_:)` name, moved off `metricName` |
| `duration_ms` | number (int) | host-named metrics → `custom_timer` | event | required | numeric | none | iOS-only | Added by `RumTimer.end`. Restates `value` in ms; not ruled on by any ticket, kept |

### 5.10 Error and crash family

As-is all of these ride `app.crash`, partitioned by `cause`. After T4 they ride three names.

| key | type | on events | scope | presence | cardinality | pii | delta | notes |
|---|---|---|---|---|---|---|---|---|
| `cause` | string | `app.crash` | event | required | bounded enum: `AppError`, `Hang`, `NativeCrash` | none | iOS-only | **−T4 breaking batch.** Fully redundant once `app.error` / `app.hang` / `app.crash` are names |
| `runtime` | string | `app.crash`; after T4 `app.error`, `app.crash`, `app.hang` | event | required | bounded enum: `swift`, `native` | none | iOS-only | `swift` on `AppError`, `native` otherwise — constant per name after T4. No ticket deleted it; kept |
| `crash.fatal` | bool | `app.crash` | event | optional | — | none | iOS-only | **−T4 breaking batch.** `true` native, `false` hang, absent on `AppError` (D5); constant `true` on `app.crash` after the split |
| `error.type` | string | `app.crash` (AppError) | event | required | unbounded string | none | iOS-only | **→T4 breaking batch:** renamed to `error.class` |
| `error.class` | string | `app.error` | event | required | unbounded string | none | iOS-only | **+T4 (renamed from `error.type`).** Swift type name via `String(describing:)` (`AppErrorBuilder.swift:57`) or `NSError` — "which type threw" |
| `error_type` | string | `app.error` | event | optional | unbounded string, capped at 128 UTF-8 bytes | content | iOS-only | **+T8 error evidence.** Host-supplied via `captureError(_:type:context:)` — "what kind of failure". Free by design; the SDK classifies nothing. **Conventional values** (documented, not enforced): `decoding_error`, `authentication_error`, `validation_error`, `database_error`. **Not** in this vocabulary: `network_error`, `timeout`, `server_error` — those are `http.request` + `http.error_domain` / `http.error_code`, and duplicating them double-counts every network failure |
| `error.message` | string | `app.error` | event | required | unbounded string | content | iOS-only | `localizedDescription`, falling back to `String(describing:)`. Sent unscrubbed — the class is the mitigation |
| `error.kind` | string | `app.error` | event | required | bounded enum: `swift`, `nserror` | none | iOS-only | |
| `error.domain` | string | `app.error` | event | required | unbounded string | none | iOS-only | Synthetic type name for bridged Swift errors |
| `error.code` | number (int) | `app.error` | event | required | numeric | none | iOS-only | `0` for bridged Swift errors |
| `error.stack` | string | `app.error` | event | optional | unbounded string | content | iOS-only | `\n`-joined, truncated whole-frame to 4096 B. **~T4 breaking batch:** frames become `image +0x<image-relative offset> <hint-symbol>` — as-is `dladdr` strings carry absolute ASLR addresses with no image base or UUID, unsymbolicatable by anyone |
| `error.stack.truncated` | number (int) | `app.error` | event | optional | numeric | none | iOS-only | **+T4 breaking batch.** Bytes removed (`AppErrorBuilder.swift:96-106`). Omitted when zero |
| `error.binary_images` | string | `app.error` | event | optional | unbounded string | none | iOS-only | **+T4 breaking batch.** JSON string `[{"name":…,"uuid":…}]` of the **referenced** images only, deduplicated — the symbolication key for `error.stack` |
| `error.userInfo.<key>` | any scalar | `app.error` | event | optional | **open prefix** | content | iOS-only | Explicit `NSError` only; non-primitive values dropped |
| `crash.context.<key>` | any scalar | `app.error` | event | optional | **open prefix** | content | iOS-only | Caller-supplied via `captureError(context:)`, prefixed by the SDK (so not hit by T4's reserved-namespace drop). `crash.` prefix on a non-crash event is legacy, kept |
| `crash.timestamp` | string | `app.crash` (as-is: `app.crash` Hang + NativeCrash) | event | required | unbounded string | none | iOS-only | ISO 8601. Absent on the `AppError` path (D5). On the hang path **→T4 breaking batch:** renamed `hang.timestamp` (roadmap §10 row 11) |
| `hang.timestamp` | string | `app.hang` | event | required | unbounded string | none | iOS-only | **+T4 breaking batch (renamed from `crash.timestamp` on the hang path).** ISO 8601 threshold-crossing time; after T8 the event's own `timestamp` is stall end |
| `crash.report_format_version` | string | `app.crash` | event | required | unbounded string | none | iOS-only | |
| `crash.signal` | string | `app.crash` | event | optional | unbounded string | none | iOS-only | Present ⇒ signal. Co-occurs with exception keys; exception wins |
| `crash.signal_code` | string | `app.crash` | event | optional | unbounded string | none | iOS-only | |
| `crash.exception_name` | string | `app.crash` | event | optional | unbounded string | none | iOS-only | Present ⇒ Objective-C exception, the proximate cause |
| `crash.exception_reason` | string | `app.crash` | event | optional | unbounded string | content | iOS-only | |
| `crash.mach_exception` | string | `app.crash` | event | optional | unbounded string | none | iOS-only | **+T8 error evidence.** Flattened from `report.machExceptionInfo` (`CrashReportEncoder.swift:165-171`), read today only into the nested report. `EXC_BAD_ACCESS` vs `EXC_CRASH` is what signals cannot say |
| `crash.os_version` | string | `app.crash` | event | optional | unbounded string | none | iOS-only | |
| `crash.binary_uuid` | string | `app.crash` | event | optional | unbounded string | none | iOS-only | **Symbolication key** — the faulting image's Mach-O UUID |
| `crash.binary_name` | string | `app.crash` | event | optional | unbounded string | none | iOS-only | **Symbolication key** — last path component |
| `crash.report_json` | string | `app.crash` | event | required | unbounded string | content | iOS-only | The whole PLCrashReporter-derived report as an embedded JSON string. `binary_images[].{uuid, base_address}` inside it are **symbolication keys** (offset = address − `base_address`). Its internal `…N more…` thread-truncation markers stay. **~T4 breaking batch:** the size-cap fallback drops **unreferenced** images first, then referenced ones (as-is it empties `binary_images` wholesale, `CrashReportEncoder.swift:115-124`) |
| `crash.binary_images.dropped` | number (int) | `app.crash` | event | optional | numeric | none | iOS-only | **+T4 breaking batch.** Images removed by the size-cap fallback (C10). Omitted when zero |
| `crash.registers.dropped` | number (int) | `app.crash` | event | optional | numeric | none | iOS-only | **+T4 breaking batch.** Threads whose registers were stripped. Omitted when zero |
| `hang.duration_ms` | number (double) | `app.hang` (as-is: `app.crash` Hang) | event | required | numeric | none | iOS-only | **~T8 error evidence:** the **real** stall length (or time to death on a replayed hang). As-is it is ≈ `hangTimeout` (+ ≤ 250 ms tick slop) for every hang — a 6 s stall and a 60 s freeze are byte-identical |
| `hang.threshold_ms` | number (double) | `app.hang` | event | required | numeric | none | iOS-only | Default 5000 (`EdgeRumConfig.hangTimeout`, floor 2 s) |
| `hang.terminated` | bool | `app.hang` | event | optional | — | none | iOS-only | **+T8 error evidence.** Present (`true`) only on next-launch replay of a stall the process died in (e.g. watchdog `0x8badf00d`). The only hang category the SDK asserts |
| `hang.cpu_usage` | number (double) | `app.hang` | event | optional | numeric | none | iOS-only | **~T1 doc-truth:** populated from the whole-process CPU reader built in T1 (reused by T5's `cpu_usage`). Unit **per-core percent, may exceed 100** — the same unit as `cpu_usage`; the encoder's never-true "0.0–1.0" doc comment is amended (roadmap §10 row 3). Separates busy-loop hangs from blocked ones. **As-is it has never appeared on the wire** (`cpuProvider` is the constant `{ nil }` in every production build, `HangDetector.swift:87,133`), so the unit fix breaks nothing |
| `crash.thread.main_stack` | string | `app.crash` Hang (as-is) | event | required | unbounded string | content | iOS-only | **→T4 breaking batch:** renamed `hang.stack` (roadmap §10 row 11) |
| `hang.stack` | string | `app.hang` | event | required | unbounded string | content | iOS-only | **+T4 breaking batch (renamed from `crash.thread.main_stack`).** Main-thread stack at detection; `<hang-stack-unavailable>` placeholder when the walk fails. Offset frame format, as `error.stack` |
| `hang.stack.truncated` | number (int) | `app.hang` | event | optional | numeric | none | iOS-only | **+T4 breaking batch.** Frames removed by `CrashStackTruncator` — replaces its in-string `…N more…` marker on this key. Omitted when zero (§13 X3) |
| `hang.binary_images` | string | `app.hang` | event | optional | unbounded string | none | iOS-only | **+T4 breaking batch.** Referenced-images JSON, as `error.binary_images` |
| `trace.root_expired` | bool | `app.crash`, `app.hang` | event | optional | — | none | iOS-only | **+T11 tracing** (v3 §12.2). Present only when `true`: the last root had aged out and the causal claim is the backend's to judge |

`trace.id` and `rum.action.id` also ride `app.crash` and `app.hang` as join keys (v3 §12; §5.13).
`span.id` and `parent.span.id` are absent — a crash is not a child span.

### 5.11 Performance metrics

| key | type | on events | scope | presence | cardinality | pii | delta | notes |
|---|---|---|---|---|---|---|---|---|
| `value` *(attribute)* | number (double) | every metric | event | required on fixed metrics | numeric | none | iOS-only | **−T4 breaking batch** ([#146][I146]): the duplicated copy of the envelope `value` is stripped from `attributes`. The envelope `value` stays |
| `long_task.threshold_ms` | number (double) | `long_task` | event | required | numeric | none | iOS-only | Default 50 |
| `long_task.stack` | string | `long_task` | event | required | unbounded string | content | iOS-only | Truncated to 4096 B (`RunLoopObserverCapture.swift:57,97`). **~T4 breaking batch:** offset frame format |
| `long_task.stack.truncated` | number (int) | `long_task` | event | optional | numeric | none | iOS-only | **+T4 breaking batch.** Bytes removed. Omitted when zero |
| `long_task.binary_images` | string | `long_task` | event | optional | unbounded string | none | iOS-only | **+T4 breaking batch.** Referenced-images JSON |
| `frame.max_ms` | number (double) | `frame_render_time` | event | required | numeric | none | iOS-only | |
| `frame.p95_ms` | number (double) | `frame_render_time` | event | required | numeric | none | iOS-only | |
| `frame.dropped_count` | number (int) | `frame_render_time` | event | **optional after T8** | numeric | none | iOS-only | As-is **inferred** as `targetHz × window − observed` (C9): throttled windows report frames the user never missed, and an empty window reports the full expected count. **~T8 error evidence:** observed — per callback `round((timestamp − prevTimestamp) / (targetTimestamp − timestamp)) − 1`, against the refresh interval actually running; empty window → **omitted** |
| `frame.target_hz` | number (int) | `frame_render_time` | event | required | numeric | none | iOS-only | 60 or the ProMotion maximum. The Processor classifies slow/frozen against it (§10 P9) |
| `frame.source` | string | `frame_render_time` | event | required | bounded enum: `displaylink` | none | iOS-only | Constant |
| `frame.sample_count` | number (int) | `frame_render_time` | event | required | numeric | none | iOS-only | Frames in the window |
| `frame.window_ms` | number (int) | `frame_render_time` | event | required | numeric | none | iOS-only | **+T5 sampler cut.** Motion-window length (≤ 10 000), for normalisation now that windows vary |
| `memory.resident_kb` | number (int) | `memory_usage` | event | **optional after T5** | numeric | none | iOS-only | **~T5 sampler cut:** absent when `task_info` fails — as-is it emits `0` (`MemorySampler.swift:185-191`), a kernel failure reading as a zero-byte process. Key keeps its kB unit; only the metric `value` moves to MB |
| `memory.virtual_kb` | number (int) | `memory_usage` | event | **optional after T5** | numeric | none | iOS-only | As above |
| `memory.footprint_kb` | number (int) | `memory_usage` | event | **optional after T5** | numeric | none | iOS-only | **~T5:** absent when unreadable — as-is it silently substitutes the resident value (`MemorySampler.swift:207-212`) |
| `memory.pressure` | string | `memory_usage` | event | required | bounded enum: `normal`, `warning`, `critical` | none | iOS-only | **~T5 sampler cut:** the timer tick carries the **last observed** level. As-is it stamps `normal` unconditionally (`MemorySampler.swift:243`), so a sustained warning reads `normal` 10 s later |
| `screen.ready_outcome` | string | `screen_ready` | event | required | bounded enum: `ready`, `abandoned` | none | iOS-only | **+T13 host-gated.** `abandoned` = a screen marked at least once this process disappeared with its token pending; `value` is then time-to-leave (censored) |

### 5.12 Breadcrumbs ([W6 Breadcrumb model][W6])

A breadcrumb is a demoted event, not a new signal; the ring exists to **defeat the sampler** (at
`sampleRate = 0.1`, nine crash reports in ten arrive with no journey today).

| key | type | on events | scope | presence | cardinality | pii | delta | notes |
|---|---|---|---|---|---|---|---|---|
| `breadcrumbs` | string | `app.crash`, `app.hang`, `app.error` | event | optional | unbounded string (≤ 100 rows, ~10 KB) | content | iOS-only | **+T6 breadcrumbs.** JSON array of objects as a string, oldest first. Replayed `app.crash` attaches the **prior** session's ring from `breadcrumbs.json` (deleted after replay; attached only when its `session.id` matches the sidecar's). Live `app.hang` / `app.error` attach the current ring **at most once per session**. Ring cleared on session rotation |
| `breadcrumb.dropped` | number (int) | `app.crash`, `app.hang`, `app.error` | event | optional | numeric | none | iOS-only | **+T6.** Rows lost to the 1 s coalescing window, ring eviction, the 128 B label cap or a `session.id` mismatch — one counted number from the file's monotonic sequence. Omitted when zero |

**Row format inside `breadcrumbs`:**

| field | type | meaning | pii |
|---|---|---|---|
| `t` | int | absolute epoch ms | none |
| `n` | string | event name — any recorded **event** (never a metric) not on the forced-emit list | none |
| `l` | string? | one discriminating label, ≤ 128 B | content |
| `s` | int? | status — `http.status_code` only | none |

**`l` projection (target state after T4):** `app_lifecycle` → `lifecycle.state`; `navigation` →
`navigation.screen`; `http.request` → `http.method` + `" "` + `http.path` (never `http.url`), `s` =
`http.status_code`; `user.interaction` → `interaction.name` ?? `interaction.target`; `custom_event`
→ `event.name`; every other eligible name → no `l`. Before T4 the D3/D4 fallback chains apply
(`navigation.screen ?? navigation.name`; `interaction.target_id ?? interaction.target ??
interaction.name`). Eligible names after all tranches: `app_lifecycle`, `page_load`, `navigation`,
`http.request`, `user.interaction`, `user.profile.update`, `custom_event`, `app.error`, `app.hang`,
`action.started`, `action.ended`.

**Fixed constants, not configurable:** ring 100 rows, `l` cap 128 B, coalescing window 1 s. The only
switch is `captureBreadcrumbs` (whole feature on/off, default on — roadmap §10 row 6). File:
`Library/Caches/edge-rum/breadcrumbs.json`, carrying its own `session.id`.

### 5.13 Distributed trace v3 — `+T11 tracing` (`docs/specs/distributed-trace-v3-ios.md`)

All names frozen to Android's contract ("wire-identical, mechanism free"). **Root set** =
`trace.id`, `span.id`, `rum.action.id`, `trace.root_type`, `span.start_time`. **Child span** = root
set's ids plus own `span.id`, `parent.span.id`, `span.duration_ms`. **Join keys** = `trace.id`,
`rum.action.id` (+ `span.id` on `resource_timing`).

| key | type | on events | scope | presence | cardinality | pii | delta | notes |
|---|---|---|---|---|---|---|---|---|
| `trace.id` | string | `http.request`, `resource_timing`, `navigation`, `user.interaction`, `page_load`, `app_lifecycle` (minting `foregrounded` only), `app.crash`, `app.hang` | event | optional | unbounded string (32 lowercase hex) | pseudonymous | shared | **+T11** (v3 §1). Never all-zero |
| `span.id` | string | span-carrying events, `resource_timing` | event | optional | unbounded string (16 lowercase hex) | pseudonymous | shared | **+T11.** On a root equals `rum.action.id`; on `resource_timing` the **same** id as its `http.request` (v3 §11.3) |
| `parent.span.id` | string | child spans (`http.request`, non-minting `navigation`) | event | optional | unbounded string (16 lowercase hex) | pseudonymous | shared | **+T11.** Absent on roots, adopted spans, `app.crash` and `app.hang` |
| `rum.action.id` | string | all span-carrying events, `resource_timing`, `app.crash`, `app.hang` | event | optional | unbounded string (16 lowercase hex) | pseudonymous | shared | **+T11.** The trace **root's** `span.id`, denormalized — **not a user action** (that is `action.id`, T12). Name kept for Android parity ([W13][W13]) |
| `trace.root_type` | string | span-carrying events | event | optional | bounded enum: `launch`, `interaction`, `navigation`, `resume`, `request` | none | shared (`resume` iOS-only member) | **+T11.** `request` accepted by the store, never minted by iOS. Trace v3 owns the word `resume`; no other iOS key reuses it |
| `span.start_time` | string | span-carrying events | event | optional | unbounded string | none | shared | **+T11.** **ISO 8601 ms UTC string — never a number** (v3 §15.1; a number NULLs silently server-side) |
| `span.duration_ms` | number (double) | child spans | event | optional | numeric | none | shared | **+T11.** Roots carry none |

Plus `traceparent.outcome` (§5.6) and `trace.root_expired` (§5.10). Outbound header: W3C
`traceparent` `00-<trace.id>-<span.id>-<01|00>` (sampled flag); no `tracestate`.

### 5.14 Action lifecycle — `+T12 actions` ([W5][W5])

| key | type | on events | scope | presence | cardinality | pii | delta | notes |
|---|---|---|---|---|---|---|---|---|
| `action.name` | string | `action.started`, `action.ended` | event | required | unbounded string, **per-session cap: 50 distinct values** | content | iOS-only | **+T12.** Overflow is bucketed to `_other` (`startAction("checkout-\(orderId)")` is the bug this closes) |
| `action.name.dropped` | number (int) | `action.started`, `action.ended` | event | optional | numeric | none | iOS-only | **+T12.** Distinct names discarded into `_other` this session (not occurrences). Omitted when zero |
| `action.parent_id` | string | `action.started`, `action.ended` | event | optional | unbounded string | pseudonymous | iOS-only | **+T12.** Set when the action started while another was open — reconstructs nesting server-side. Droppable if the tranche needs trimming |
| `action.outcome` | string | `action.ended` | event | required | bounded enum: `completed`, `failed`, `abandoned` | none | iOS-only | **+T12** |
| `action.abandon_reason` | string | `action.ended` | event | optional | bounded enum: `rotation`, `process_death`, `timeout` | none | iOS-only | **+T12.** Present only when `outcome = abandoned`. `rotation` = session rotation with the action open; `process_death` = reconstructed next launch from the volatile zone (granularity capped by what [W11][W11] can distinguish — i.e. none); `timeout` = 600 s (wall clock) leak guard, not inference. Spelling per the roadmap's tranche 12 |
| `action.background_count` | number (int) | `action.ended` | event | optional | numeric | none | iOS-only | **+T12.** Backgrounding is recorded, not judged — the OTP hop stays a completion. Transitions into `app.state = background` while the action was open; `0` when none |
| `action.background_duration_ms` | number (int) | `action.ended` | event | optional | numeric | none | iOS-only | **+T12.** Summed over those hops on a monotonic clock that runs through sleep. On `process_death`, a hop still open at death is not counted |
| `action.error_message` | string | `action.ended` | event | optional | unbounded string | content | iOS-only | **+T12.** From `fail(reason:)` — where a pasted server response containing an email lands |

`action.id` is the rider in §5.2; on the two action events it names the action itself.

### 5.15 Host-supplied attributes

| key | type | on events | scope | presence | cardinality | pii | delta | notes |
|---|---|---|---|---|---|---|---|---|
| *host key* | any scalar | `custom_event` (`track`), `navigation` (`trackScreen`, `.edgeRumScreen`), `user.interaction` (`.edgeRumTrackTap`), host metrics → `custom_timer` (`RumTimer.end`) | event | optional | **open** | content | iOS-only | Merged verbatim; SDK-owned keys applied last so they cannot be overwritten. The SDK asserts nothing about the contents. **~T4 breaking batch:** keys beginning with an SDK prefix — `app.` `device.` `network.` `session.` `user.` `sdk.` `navigation.` `interaction.` `http.` `resource.` `crash.` `error.` `hang.` `action.` `trace.` `span.` `rum.` `screen.` (and the rest of the reserved set) — are **dropped at the public entry**, counted, and logged in `debug`. As-is `track("user.email", …)` shadows an SDK key |
| `host_attributes.dropped` | number (int) | every event and metric with host keys (above) | event | optional | numeric | none | iOS-only | **+T4 breaking batch.** Host keys removed by the reserved-prefix rule on this event (§0 clause 8 marker). Omitted when zero. Spelling ruled by the T4 epic (ADR-020); an envelope total may follow in T7 |

### 5.16 Crash and hang replay override set

On a replayed `app.crash` (and, from T8, a replayed `app.hang`), event attributes from the sidecar
beat context, so these carry the **crashed** session's values:

| zone | keys | contract |
|---|---|---|
| identity (exact) | `session.id`, `session.start_time`, `session.sequence`, `device.id`, `user.id`, `sdk.version`, `sdk.platform`; **+T8** `app.version`, `device.platform_version` (so a replay reports the version that died); as-is also `user.name`, `user.email`, `user.phone` — **removed at T2** | correct the instant the mutating call returns (written at configure, `setUser`, rotations, batch ACK — **~T0** stops the per-event write) |
| volatile (best-effort) | `screen.name`, `device.orientation`, `app.state` (T3); open-action stack top (T12); last trace root → `trace.id`, `rum.action.id`, `trace.root_expired` (T11) | latest-wins, coalesced on change; a crash inside the drain window lands without them |
| marker (T8) | `session.clean_exit` — set at `willTerminate`; read into `previous_session.end`, never carried on a replayed event | file-only |
| not mirrored | all other context — `network.*`, battery, thermal, storage | the **reporting** launch's values; do not read a replayed crash's `network.type` as the network at crash time |

---

## 6. Metric units ([W16][W16])

### 6.1 Per-name units — the contract the Processor trusts

| metricName | `value` is | unit | from | note |
|---|---|---|---|---|
| `screen.duration` | dwell | **seconds** | as-is | **−T4**; its own `screen.duration_ms` was ms on the same row (D6) |
| `resource_timing` | request duration | ms | as-is | |
| `long_task` | stall | ms | as-is | |
| `frame_render_time` | worst frame in window | ms | as-is | |
| `memory_usage` | resident set | **kB → MB** | T4 | [#145][I145]; the one grandfathered unit change (§13 X1) |
| `cpu_usage` | whole-process CPU | percent (per-core sum, may exceed 100) | T5 | |
| `custom_timer` | elapsed | ms | T4 | replaces host-named metrics (ms) |
| `screen_ready` | appear → ready (or → leave, censored) | ms | T13 | |
| `launch_interactive` | `launchStart` → host-marked interactive | ms | T13 | roadmap §10 row 13 |

From T4: **three units** remain — ms, MB, percent. A `value.unit` attribute was rejected (bytes on
every metric to restate what the name fixes); unit-suffixed keys instead of `value` were rejected
(breaks the Processor's only read path).

### 6.2 UI-thread ladder ([W19 Frame and hang vocabulary][W19])

`frame_render_time` (per motion window, observed drops) → `long_task` [50 ms, `hangTimeout`) →
`app.hang` [`hangTimeout`, ∞) ± `hang.terminated`. Each stall lands on exactly one rung (with hang
detection off, `long_task` keeps the full range). **Classification is the backend's** — the SDK
ships raw durations only. Suggested Processor defaults (not SDK behaviour): frames slow > 2× frame
budget, frozen > 700 ms; hangs 2–5 s / 5–10 s / > 10 s / terminated.

### 6.3 Volume (foreground hour, rough — [W12][W12])

| | as-is | after T5 |
|---|---|---|
| `frame_render_time` | ~3,600 | ~100–300 |
| `memory_usage` | ~360 | ~120 |
| `cpu_usage` | — | ~120 |
| **total periodic** | **~3,960** | **~350–550** |

Riders (T3) are the first per-*event* wire cost: `device.orientation` + `app.state` (short enums)
and `screen.name` (~15–60 B, capped 128 B) on every event.

---

## 7. Never collected ([W7][W7] §3, [W9][W9], [W10][W10])

Absence is the other half of the contract. **`PrivacyContractTests` (T2)** greps `Sources/` for
`ASIdentifierManager`, `advertisingIdentifier`, `identifierForVendor`, `allHTTPHeaderFields`,
`IOPlatformSerialNumber`, `ATTrackingManager` and fails on a hit, and asserts `identity` is exactly
four keys.

| never collected | why / guard |
|---|---|
| IDFA (`ASIdentifierManager`) | ATT-neutral SDK; grep-guarded |
| IDFV (`identifierForVendor`) | `device.id` is SDK-minted instead; grep-guarded |
| ATT prompt (`ATTrackingManager`) | grep-guarded |
| IMEI, serial number (`IOPlatformSerialNumber`), MAC address | persistent hardware identifiers; serial grep-guarded |
| Keychain contents | the SDK reads only its own `device.id` item |
| Request and response **headers**, **cookies** | never captured at any configuration — no allowlist, denylist or transform; grep-guarded (`allHTTPHeaderFields`) |
| Request and response **bodies** | never read; `httpBody` is used for `.count` only |
| Device IP to a third party | `resolveLocation` / `locationProviderUrl` deleted at T4 (dead config as-is — never actually sent) |
| Carrier name | `CTCarrier` deprecated iOS 16, returns `"--"` from 16.4 — would ship a constant |
| Hardware device orientation (`UIDevice.orientation`) | reports `faceUp`/`faceDown` flat and landscape for a portrait-locked app — describes the device, not the screen |
| Pre-main time | unobtainable without SDK code running during dyld — measuring launch by slowing it |
| Rendered field text | `.text` never read; secure-entry taps dropped entirely |

---

## 8. Declined signals — registry of absences

Each was considered by a ticket and declined; the reason is the record.

| signal | declined by | reason |
|---|---|---|
| OOM termination (`oom` flag / rate) | [W11][W11] | force-quit from the app switcher is indistinguishable from foreground OOM and more common; SDK ships evidence (`previous_session.*`), backend infers |
| `crash.kind` | [W11][W11] | derivable from key presence; a baked-in precedence is worse than a query (exception wins, §0) |
| Bounded `error_type` enum / SDK error classification | [W11][W11] | the SDK cannot classify a host `Error`; every new type would cost a release |
| Network errors as `app.error` | [W11][W11] | double-counts every failure already on `http.request` |
| Forced-emit hangs | [W11][W11] | a hang is a rate question; forcing every hang to catch the terminal one is a bad trade |
| `render_complete` / host-free screen readiness | [W23 Screen readiness][W23] | measured from appear it is ~one vsync on every screen — a constant |
| Screen readiness from the idle heuristic; TTI from main-thread quiet | [W9][W9], [W23][W23] | "nothing computing" is equally true of a spinner |
| Time to first frame as its own attribute | [W9][W9] | exactly the sum of two shipped durations |
| `launch.type` (cold / warm / resume) | [W9][W9] | `page_load` is a per-process one-shot — the key would be a constant `cold` |
| `page_load.cold_start` | [W9][W9] | `!prewarmed` beside `prewarmed` (deleted T4) |
| Warm-launch detection | [W9][W9] | not observable from inside the process |
| Resume latency | [W9][W9] | a resume keeps its hierarchy (a frame or two); the slow part is the request burst, better represented as a `resume` trace root |
| Pre-main time | [W9][W9] | §7 |
| Phase breakdown of `EdgeRum.start()` | [W9][W9] | localise once in Instruments; same refusal as the overhead receipt |
| `sdk_cpu_usage` | [W8][W8] | no honest per-subsystem attribution on iOS; replaced by `sdk.thread_time_ms` |
| `sdk_memory_usage` | [W8][W8] | cap the buffers instead of measuring them |
| `events_queued` | [W8][W8] | derivable: generated − uploaded − dropped |
| `queue_size` / `storage_size` gauges | [W8][W8] | gauges are what loss corrupts; converted to high-water marks |
| `serialization_time` | [W8][W8] | absorbed into `sdk.thread_time_ms` |
| Periodic `sdk.health` event | [W8][W8] | telemetry volume measuring telemetry volume; blind when the queue is full |
| Runtime exposure of SDK counters to the host | [W8][W8] | invites the per-app overhead receipt that cannot be defended |
| Session rollups on `session.finalized` (`crash_count`, `error_count`, `screen_count`, `action_count`) | [W8][W8], [W18][W18] | finalized is absent for never-resumed and crashed sessions; analytics-layer counts plus `sdk.events_dropped.*` give a bounded lower bound |
| `session.duration` attribute | [W18][W18] | derived from `session.end_time − session.start_time` |
| Per-event ordinal | [W18][W18] | gap count comes from `sdk.events_generated` |
| Backgrounding threshold as a session end | [W18][W18] | idle already covers it; the 4 h cap bounds the rest |
| Offline duration on `network_change` | [W21 Radio and offline][W21] | pairing by `device.id` gives the same number; a persisted "offline since" overstates across process death |
| Carrier name | [W10][W10] | §7 |
| Hardware orientation | [W10][W10] | §7 |
| Memory as context | [W10][W10] | a second, staler number; `memory_usage` is authoritative |
| `ui.*` namespace on iOS | [W10][W10], [W13][W13] | would make the Processor's `ui.interaction` defect ambiguous |
| `user.interaction` → `ui.interaction` rename | [W13][W13] | the Processor's defect, not iOS's (§10 P1) |
| Style renames of legacy names (D10 camelCase, D12 `device.os`, `page_load`, `custom_event`, `app_lifecycle`, `network_change`) | [W13][W13] | break routing or the collector's identity gate for no information |
| `frame.slow_count` / `frozen_count`, on-device hang tiers, any threshold knob | [W19][W19] | thresholds in a binary freeze per release; backend classifies |
| `value.unit` attribute; unit-suffixed metric keys | [W16][W16] | §6.1 |
| `custom.<name>` metric prefix; open metric names | [W16][W16] | still unbounded |
| Four action event names (`action_started` / `_completed` / `_failed` / `_abandoned`) | [W5][W5] | two names + an outcome enum |
| Speculative abandonment (backgrounding, screen exit) | [W5][W5] | every trigger has a come-back mode; corrupts the completion rate |
| Auto-promotion of taps to actions | [W5][W5] | the checklist's explicit point |
| Forced-emit actions | [W5][W5] | riders would join to nothing |
| Header / body redaction engine (allowlist, denylist, transform) | [W7][W7] | never-capture is stronger and free |
| Hashing or truncating identity | [W7][W7] | host asserted consent by calling `identify()` |
| Breadcrumb privacy kill-switch | [W7][W7] | `l` inherits its sources' class; `captureBreadcrumbs` is the feature switch |
| Breadcrumbs for metrics; checkpoint-only or append-log persistence; mmap ring (deferred, named upgrade) | [W6][W6] | metrics evict the ring in 100 s; checkpoint loses foreground crashes; mmap needs fixed-width slots |
| NavigationStack / sheet introspection for SwiftUI screen names | [W17][W17] | fragile across iOS releases; hosting-root name instead |
| On-device symbolication as truth; arch field on images | [W20 Symbolication][W20] | addresses + UUIDs off-device; a UUID identifies one slice |
| Shared sampler scheduler | [W12][W12] | one gate predicate instead |
| `navigation.method`, `navigation.to_screen` / `from_screen`, `http.success`, `frame.dropped`, `memory.pressure_level` (map #140 targets) | this document | §13 X1 |

---

## 9. Migration and rename table ([W13][W13] + every T4 item)

One breaking tranche, **T4**, shipping as `1.0.0-alpha.N`. Note at
`docs/migration/1.0.0-alpha.2-to-alpha.N.md` from `docs/migration/TEMPLATE.md`; **wire format
impact: yes**; rollout order **Processor first**, then the iOS alpha. The Processor delta (§10) is
handed over when **T0** starts, so the backend gets the lead time. GA `1.0.0` starts from this
vocabulary. **Rule:** rename only to fix iOS's own incoherence, never to match the Processor; new
event names are dotted, new keys snake_case, legacy spellings frozen.

### 9.1 Renames

| old | new | on | why | breaks |
|---|---|---|---|---|
| `navigation.name` | `navigation.screen` + `navigation.kind = "manual"` | `navigation` (`trackScreen`) | D3: one screen key across three producers | queries on `navigation.name` |
| `interaction.target_id` | `interaction.name` (+ `interaction.name_source`, T2) | `user.interaction` (UIKit) | D4/D11: one label key across both producers | queries on `interaction.target_id` |
| `network.is_expensive` / `network.is_constrained` | `network.expensive` / `network.constrained` | `network_change` | D8: one spelling per fact; emit-time value now overrides context | queries on the `is_` pair |
| `error.type` | `error.class` | `app.error` | frees the name for host `error_type` | queries on `error.type` |
| `crash.timestamp` | `hang.timestamp` | `app.hang` only | a `crash.*` key on a non-crash event, created by the split (roadmap §10 row 11) | queries on `crash.timestamp` for hangs |
| `crash.thread.main_stack` | `hang.stack` | `app.hang` only | aligns with `long_task.stack`, `error.stack`, `hang.binary_images` (roadmap §10 row 11) | queries on `crash.thread.main_stack` |
| `app.crash` (`cause = AppError`) | `app.error` | — | one name cannot carry two flush policies | routing on `cause` |
| `app.crash` (`cause = Hang`) | `app.hang` | — | a hang is not a crash | routing on `cause` |
| host `metricName` | `custom_timer` + `timer.name` | `EdgeRum.time()` | D7: bounded name space | host timer names move to an attribute |
| `memory_usage` `value` kB | MB | `memory_usage` | [#145][I145] | value scale ×1/1024 |

### 9.2 Deletions

| deleted | reason |
|---|---|
| `cause` | redundant with the three names |
| `http.error` (free text) | replaced by typed `http.error_domain` + `http.error_code`; the free text embedded URLs with queries |
| `crash.fatal` | constant `true` on `app.crash` |
| `navigation.type` | constant `viewDidAppear`, false on SwiftUI |
| `http.url`, `resource.url` | redundant; carry query strings (privacy) |
| `page_load.cold_start` | `!prewarmed` |
| `interaction.screen` | replaced by the `screen.name` rider (T3) |
| `screen.duration` metric + `screen.kind`, `screen.duration_ms` | [#144][I144]; Processor synthesizes dwell |
| `screen.duration` in `Recorder.allowedEventNames` | dead entry (D1) |
| `value` copy in metric `attributes` | [#146][I146] |
| config `resolveLocation`, `locationProviderUrl` | dead config; migration: *set `config.location` yourself* |
| `user.name`/`user.email`/`user.phone` from `SessionSidecar.mirroredKeys` | not a wire change at T4's level — **ships in T2**; replayed crashes stop carrying them |

### 9.3 Value and shape changes in T4

| change | migration-note line |
|---|---|
| `http.error` → `http.error_domain` (string) + `http.error_code` (int) | free-form error descriptions removed; queries on `http.error` break |
| Stack frames on `error.stack`, `long_task.stack`, `hang.stack` → `image +0x<offset> <hint>` + `<prefix>.binary_images` | parsers keyed on absolute addresses break |
| `crash.report_json` fallback drops unreferenced images first; `crash.binary_images.dropped`, `crash.registers.dropped`, `*.stack.truncated` added | — |
| `session.finalized` only on rotation; `session.end_time`; `session.rotation = max_duration`; 4 h cap | finalized count drops to one per session; pairing started→finalized becomes valid |
| Reserved SDK prefixes dropped from host attribute bags | host keys like `user.email` no longer shadow SDK keys |
| `network.effectiveType` value set | ships in T10, not T4 — value-set fix (`cellular` leaves, `2g`–`5g` arrive) |

### 9.4 Value corrections outside T4 (release-note lines, same names and units)

| tranche | correction |
|---|---|
| T1 | `hang.cpu_usage` appears for the first time (per-core percent); quiet sessions flush on `flushInterval`; offline backlog ceiling drops from ~6,000 to 200 events |
| T5 | `frame_render_time` per motion window + `frame.window_ms`; `memory.pressure` last-observed; memory 30 s; `memory.*_kb` omit on failure |
| T8 | `hang.duration_ms` becomes the real length; `app.hang` emits at stall end; `long_task` capped below `hangTimeout`; `frame.dropped_count` observed and omitted on empty windows |
| T9 | `page_load.duration_ms` anchor moves earlier (values grow by the SDK's pre-anchor start cost); absent instead of `0` on clock jumps |
| T10 | `network.effectiveType` resolves cellular generations |

### 9.5 Public API changes (all source-compatible)

| tranche | API |
|---|---|
| T2 | `EdgeRum.clearUser()`, `EdgeRum.resetIdentity()`; config flag opting into button-title capture |
| T6 | `EdgeRumConfig.captureBreadcrumbs` (default `true`) |
| T8 | `EdgeRum.captureError(_:type:context:)` — defaulted `type:` |
| T12 | `EdgeRum.startAction(_:)` → handle with `complete()`, `fail(reason:)`, `cancel()` (`RumTimer`'s `settled`-lock idempotency) |
| T13 | `EdgeRum.markScreenReady()` (no name) → `screen_ready`; `EdgeRum.markInteractive()` → `launch_interactive` |
| T4 | `EdgeRumConfig.resolveLocation`, `locationProviderUrl` **removed** (the one source break) |

---

## 10. Processor deltas

Written up in this repo and handed to the driver to file — **no cross-repo writes**. Sources:
[W7][W7] §12, [W13][W13], [W16][W16], [W17][W17], [W18][W18], [W11][W11], [W19][W19],
[W20][W20], [W21][W21], [W6][W6], [W8][W8], [W12][W12], [#168][I168].

| # | delta | tranche |
|---|---|---|
| P1 | Switch on **`user.interaction`** for `rum_ui_interactions` (today it falls to `default:` because the switch keys `ui.interaction`); iOS attribute prefix is `interaction.*`, not `ui.*` | now |
| P2 | **Promote `type: metric` items** instead of returning before the event switch. Correction to D9: metrics *do* land in `rum_telemetry_events.attributes` (trace extraction runs at `service.go:305`, before the metric branch at `:310`); what is lost is promotion to specialised tables | now |
| P3 | Accept renamed keys: `navigation.screen` (all producers), `interaction.name` + `interaction.name_source` (including the iOS-only `host` member), `network.expensive` / `network.constrained` on `network_change`, `error.class`, `hang.timestamp` / `hang.stack` on `app.hang` | T4 |
| P4 | Route errors on **event name** (`app.error` / `app.crash` / `app.hang`), not `cause` | T4 |
| P5 | `http.url` and `resource.url` removed — use `http.host` + `http.path` and `resource.host` + timing keys; free-text `http.error` replaced by `http.error_domain` + `http.error_code` | T4 |
| P6 | **Not a schema change:** `interaction.target_id` (then `interaction.name`) becomes **frequently absent** once `button_title` is default-off (T2). It will look like a regression on dashboards; it is the privacy default | T2 |
| P7 | `user.name` / `user.email` / `user.phone` no longer present on replayed crash events; `user.id` unchanged | T2 |
| P8 | Host timers arrive as `metricName = custom_timer` with `timer.name`; units are per name (§6.1), `memory_usage` in MB; the `value` copy leaves `attributes` | T4 |
| P9 | Classify frames and hangs server-side (§6.2 suggested bands); `hang.terminated` is the only SDK-asserted category; `frame.target_hz` is the frame budget | T8 |
| P10 | `screen.name` appears on **every** event and metric — it is a rider, **not** a `screen.duration` signal; class `content`, never a grouping dimension by default | T3 |
| P11 | `traceparent.outcome`: promote to a column, or publish the bag query (`attributes->>'traceparent.outcome'`); the contract's §6.5 acceptance test does not compile against the shipped schema. Non-blocking ([#168][I168] §2) | T11 |
| P12 | Preserve: `rum_action_envelopes` groups on `rum_action_id` **alone** — an iOS trace can straddle a session rotation; an envelope is never final ([#168][I168] §4) | T11 |
| P13 | Accept iOS-only trace values: `trace.root_type = resume`, `trace.root_expired`, `injected_expired` (already cleared) | T11 |
| P14 | `session.finalized` = one per ended session, lazily detected; use `session.end_time`; a missing finalized is normal | T4 |
| P15 | OOM is a query: join `previous_session.end = unknown` (excluding `previous_session.app_state = background`, version/OS changes and reboots via `device.boot_time`) against `memory_usage` | T8 |
| P16 | Parse `breadcrumbs` (one JSON-string attribute) on crash/hang/error | T6 |
| P17 | Envelope gains SDK health counters (§2.2); take the **max per scope**, never sum; process-scoped counters reset on process death | T7 (T0 for `sdk.thread_time_ms`, T9 for start) |
| P18 | Symbolication (backend-owned, recommended at **ingest**): dSYMs keyed by Mach-O UUID from the host's archive step; lookup `(uuid, image-relative offset)` → function, file:line; for native crashes offset = address − `base_address` from `crash.report_json`; retain by UUID at least as long as the oldest emitting app version; a missing dSYM degrades to the on-device hint, never an error. Upload tooling + store are a separate backend-dependent epic | T4 (SDK half) |
| P19 | `network.effectiveType` on iOS is **radio access technology**, not web's throughput estimate — do not pool the distributions | T10 |
| P20 | Gaps in periodic metrics while `device.low_power_mode = true` or `device.thermal_state ∈ {serious, critical}` or the app is inactive are by design | T5 |
| P21 | `content`-class keys carry a shortest-retention, never-group obligation (§3.2) | T2 |
| P22 | `sdk.platform = "ios-native"` is a value the backend has not seen before (`PLAN-iOS.md` § Backend asks) | now |
| P23 | `hang.cpu_usage` appears for the first time, per-core percent (may exceed 100) — the same unit as `cpu_usage`; offline backlog ceiling drops from ~6,000 to 200 events and quiet sessions flush on `flushInterval` | T1 |
| P24 | Two new host-gated metric names, `screen_ready` and `launch_interactive` (ms, unpromoted, in the bag); censored `screen.ready_outcome = abandoned` rows must not be averaged with `ready` rows | T13 |

---

## 11. React Native bridge delta

Out of scope to build; recorded so `edge_telemetry_react_native` can expose the new host APIs
(handed to the driver, not filed): `clearUser()`, `resetIdentity()` (T2); `captureError` `type:`
(T8); `startAction` handle (T12); `markScreenReady()`, `markInteractive()` (T13); the
`captureBreadcrumbs` and button-title config flags (T6, T2); removal of `resolveLocation` /
`locationProviderUrl` (T4). No bridge needs the riders, counters or crash keys — they are automatic.

---

## 12. Dated corrections

Behaviour of `1.0.0-alpha.2` (`e72928f`) that shipped documentation, an earlier ticket or the W2
inventory states differently. Recorded 2026-10-05 ([W22][W22] and the tickets named).

| # | claim | actual (alpha.2) | resolution |
|---|---|---|---|
| C1 | `Recorder.swift:16-17`, `HangDetector.swift:28-29`: `recordEvent` hops to a utility queue | `Recorder.queue` (`:92`, `:131`) is never used; the ingress path runs on the caller's thread (main for taps and `viewDidAppear`) under `NSLock` | docs amended, dead queue deleted — **T1** |
| C2 | `RecorderConfig.swift:22,36,49`, `TransportSink.swift:16`: 5 s `flushInterval` | no timer is ever armed; flush only at `batchSize` (30), `session.finalized`, `app.crash`, shutdown — a quiet session holds up to 29 events and loses them at process death | timer armed — **T1** |
| C3 | `OfflineQueue.swift:7`, `CLAUDE.md`: `maxQueueSize` = 200 **events** | trims on **file** count (`:202-209`) — ceiling ~6,000 events, one overflow loses ~30, unrecorded | count events (in the filename) — **T1** |
| C4 | `HangEventEncoder.swift:13,46`: `hang.cpu_usage` populated | `cpuProvider` is `{ nil }` in production; **never on the wire**; no CPU read anywhere in `Sources/` | wired to the whole-process CPU reader — **T1** |
| C5 | `Recorder.swift:304-305`; `disable()` as the consent lever | `_enabled` never checked in the Recorder; `track`, `captureError`, `RumTimer.end`, SwiftUI emitters bypass it | one guard in `Recorder.enqueue` — **T0** |
| C6 | `IdentityProvider.swift:32-35`: `deviceIdFromFallback` logged | discarded (`Recorder.swift:141-148`, `:183-197`) | `keychain` capability failure + debug log — **T7** |
| C7 | `NetworkContext.swift:15-20,96`: "F8 refines `effectiveType` from `CTTelephonyNetworkInfo`" | a comment; `cellular` is emitted, outside the documented enum | radio resolution ships **T10**; the carrier half of the TODO is retired (§7) |
| C8 | `EdgeRum.swift:186-188`, `PageLoadCapture.swift:7-8,74`: `touchLaunchStart()` runs first in `start()`; `_launchStart` is a `static let` | eight steps precede it; it is a `static var` (`PageLoadCapture.swift:71`) | anchor moved to `start()`'s first line — **T9** |
| C9 | `Privacy.md`: all three ids end `_ios` | `user.id` has no `_ios` suffix | doc corrected (W7 corrections pass) |
| C10 | `Privacy.md`: "URL sanitisation hooks let consumers redact further" | true, but the query string goes away structurally at T4 | doc corrected |
| C11 | `Configuration.md`: `resolveLocation` is a live IP-to-third-party path | dead config, referenced nowhere | config deleted — **T4** |
| C12 | `CLAUDE.md` event table / `Configuration.md`: `session.finalized` on `willResignActive` = session end | it is a flush marker; nothing rotates | semantics fixed — **T4**; docs amended |
| C13 | `CLAUDE.md`, `docs/payload-example.jsonc`: `screen.duration` not emitted; `navigation.to_screen` / `from_screen` / `method`; `http.success`; `frame.dropped`; `resource.response_ms` | `screen.duration` **is** emitted; none of the other keys exist (map #140 targets never built; `resource.download_ms` is live) | §13 X1; docs to be amended to this catalogue |
| C14 | `docs/specs/distributed-trace-v3-ios.md` §12.1 "zero new I/O" and §13 O1 "not fixed" | true at alpha.2, false once T0 removes the per-event sidecar write | trace root rides the volatile latest-wins box (W3); spec paragraph amended with the roadmap |
| C15 | W2 inventory: `network.effectiveType` enum `2g,3g,4g,5g,wifi,unknown` | writes `unknown`, `wifi`, `cellular`, `wired` | corrected in §5.1 |
| C16 | W2 inventory / W4 C8: `hang.cpu_usage` is "the only CPU number" | never emitted (C4) | corrected |
| C17 | W2 inventory: `device.screenWidth/Height` in points | pixels (`nativeBounds`) | corrected in §5.1 |
| C18 | W2 D9: `screen.duration`, `resource_timing`, `user.interaction` "never land" | they land in the JSONB bag; metrics are never *promoted*, `user.interaction` misses its table | P1, P2 |
| C19 | W6 premise: "everything streams within 5 s" | false (C2) | W6's conclusion (sampling bypass) unaffected |
| C20 | `OfflineQueue` / `_buffer`: in-memory footprint bounded by design | `_buffer` (`Recorder.swift:109`) is uncapped | cap the buffer — **T7** |
| C21 | `MemorySampler`, `PageLoadCapture`: readings are real | `rss = 0` on `task_info` failure, `footprint = rss` substitution, clamped `0` launch duration | omit, never falsify — **T5**, **T9** |

**Prevention:** every fix lands with the test that pins its claim; `CLAUDE.md` § Testing conventions
gains the rule *a doc comment asserting runtime behaviour must have a test that pins it*. Deferred: a
catalogue-parsing lint cross-checking emitted keys against these rows ([W7][W7] §10) — it needs a
parser and this document first.

---

## 13. Conflicts resolved

### 13.1 Roadmap §10 rulings, as reflected here

The roadmap ([`rum-coverage-roadmap.md`](../specs/rum-coverage-roadmap.md) §10) is the spec and
wins. Each of its 21 rows and where this catalogue carries it:

| roadmap row | ruling | carried in |
|---|---|---|
| 1 | Trace v3 §12.1 / §13 assume the per-event sidecar write → amended by roadmap §9 | §5.16, §12 C14 |
| 2 | `interaction.name_source` keeps trace v3's `accessibility_identifier`, `button_title`, `none`; [W13][W13]'s new case ships as fourth value `host` in T4 | §5.7, P3 |
| 3 | `hang.cpu_usage`: CPU reader built in **T1**, reused by T5; unit per-core percent, may exceed 100 | §5.10, §9.4, §12 C4 |
| 4 | `<prefix>.binary_images` class `none`, not [W20][W20]'s `technical` | §5.10, §5.11 |
| 5 | Error correlation rides `action.id`, not `rum.action.id` | §5.2, §5.13 |
| 6 | `captureBreadcrumbs: Bool = true` in T6 — a capture switch, not a privacy toggle | §5.12, §9.5 |
| 7 | D13 `resource.*` deletion deferred to the next breaking batch after T11 | §5.6 |
| 8 | Identity keys off the sidecar and `button_title` default-off in **T2**; `interaction.target_id` rename stays T4 | §3.3, §5.7, §9.2 |
| 9 | `page_load.duration_ms` not renamed; anchor documented, exclusion made visible by `launch.pre_sdk_duration_ms` | §5.4 |
| 10 | Clamp removal in **T9** (value correction) | §5.4, §9.4 |
| 11 | On `app.hang` only: `crash.timestamp` → `hang.timestamp`, `crash.thread.main_stack` → `hang.stack`, T4 | §5.10, §9.1 |
| 12 | Free-text `http.error` deleted; `http.error_domain` (string, `none`) + `http.error_code` (int) added, T4 | §5.6, §9.1–9.3, P5 |
| 13 | `markInteractive()` → metric `launch_interactive`, ms from `launchStart`, T13 | §4.2, §6.1 |
| 14 | Metric allowlist 6 (T4) → 8 (T13) with `screen_ready` + `launch_interactive` | §2.1, §4.2 |
| 15 | [W6][W6]'s "streams within 5 s" premise false; timer armed in T1 | §12 C2, C19 |
| 16 | Riders (incl. screen) persist **on change** via the volatile contract; previous-session evidence keeps the lifecycle-only write | §0 clause 3, §5.2, §5.3 |
| 17 | `action.name_capped` → `action.name.dropped` | §5.14 |
| 18 | `scope` column added to [W1][W1]'s row | §1.1 |
| 19 | `disable()` consent guard fixed in **T0**; dated correction, not a merge gate | §3.3, §12 C5 |
| 20 | Epic [#169][I169] reopened as T11 | §1.3 |
| 21 | ADR-014 (*iOS conforms to the Processor of record*) superseded for naming outside trace v3 by ADR-016 | §0 clause 1, X1 |

### 13.2 Catalogue-level resolutions (not ruled in the roadmap)

| # | conflict | resolution |
|---|---|---|
| X1 | Map #140 / ADR-014 pending targets vs map #188 | `screen.duration` drop ([#144][I144]) and `value` dedup ([#146][I146]): adopted, T4. Memory MB ([#145][I145]): adopted, T4 — the one grandfathered unit change, landing in the release that freezes units ([W16][W16]'s rule binds from T4 on). Not adopted: `memory.pressure_level` (W13: never rename to match the Processor; W12 keeps `memory.pressure`), `http.success` and `frame.dropped` (derivable from `http.status_code` / `frame.dropped_count`; W19 refuses labels). `navigation.to_screen` / `from_screen` / `method` (#143) superseded by W13/W17. Consistent with roadmap row 21. `CLAUDE.md` and `docs/payload-example.jsonc` need amending to this catalogue |
| X2 | Error family: [W11][W11] / [W13][W13] put split, `error_type`, `crash.mach_exception`, `previous_session.*` all in the breaking batch | Per the roadmap's tranche tables: name split in T4; the rest in T8 |
| X3 | [W8][W8] said `long_task.stack.truncated` counts frames; `long_task.stack` is byte-capped (`RunLoopObserverCapture.swift:57,97`) and `CrashStackTruncator` serves the hang stack | `long_task.stack.truncated` = bytes; `hang.stack.truncated` = frames |
| X4 | [W16][W16] treats `screen.duration` as already gone; it is emitted at alpha.2 | As-is emitted; deleted T4 |
| X5 | [W12][W12] / roadmap T5 name `cpu.percent` | Read as the unit of `cpu_usage`'s `value` (and of `hang.cpu_usage`), not a separate key ([#146][I146] no-duplicate rule) |
| X6 | `device.family` members unspecified | `phone`, `pad`, `mac`, `unknown` |
| X7 | `device.boot_time` type unspecified | ISO 8601 string (wire timestamp rule) |
| X8 | `screen.ready_outcome` — only `abandoned` named | `ready`, `abandoned`, required |
| X9 | `sdk.start_duration_ms` appears in both the roadmap's T7 and T9 scope | Owned by T9 (c); if T9 ships before T7, it lands with T7 (roadmap T9 "depends on") |
| X10 | `action.abandon_reason` — this catalogue's first draft spelled `session_end` and included SDK shutdown | Roadmap tranche 12 wins: `rotation`; shutdown is not a trigger |

---

## 14. Open items (not decided by any ticket or the roadmap)

| item | owner |
|---|---|
| Whether `app.error` carries trace join keys (v3 §12 annotates crash and hang only) | T11 epic |
| ~~Byte cap for `error_type` ([W11][W11] and the roadmap: "byte-capped", no number)~~ | **Resolved (T8, ADR-024):** 128 UTF-8 bytes (W6's label constant), cut on a character boundary, no marker |
| ~~Counter spelling for host keys dropped by the reserved-prefix rule~~ | **Resolved (T4, ADR-020):** event-level `host_attributes.dropped`, §5.15 |
| Name of the button-title opt-in flag | T2 epic |
| Exact envelope placement of §2.2 counters (top-level keys vs a nested object) — Processor delta P17 | T7 epic |
| Whether `runtime`, `duration_ms` and `crash.context.*` on `app.error` survive a later breaking batch | next breaking batch |
| Checklist items no ticket ruled on (install markers, memory/CPU denominators, automatic error capture, global-attributes API) | roadmap §8 residual gaps |

---

## 15. Provenance

| ticket | owns here |
|---|---|
| [W1 Catalogue schema][W1] | row shapes, header clauses 1–3 |
| [W2 Wire inventory][W2] | every untagged row; D1–D13 |
| [W3 O1 / volatile sidecar][W3] | sidecar zones, §5.16, C14 |
| [W4 Gap classification][W4] | C-findings cited (C1, C3–C6, C8–C10, C15), D9 correction |
| [W5 Action lifecycle][W5] | §5.14, `action.id` rider |
| [W6 Breadcrumb model][W6] | §5.12 |
| [W7 PII classes][W7] | §3, §7, P5–P7, strips |
| [W8 SDK health][W8] | §2.2, markers, omit-never-falsify |
| [W9 Launch][W9] | `page_load` rows, `launch.pre_sdk_duration_ms`, start counters, `launch_interactive` API |
| [W10 Context riders][W10] | `scope` column, riders, `device.family` |
| [W11 Error taxonomy][W11] | three-name split, `error_type`, `previous_session.*`, clauses 5–6 |
| [W12 Sampling policy][W12] | `cpu_usage`, motion windows, gate |
| [W13 Rename batch][W13] | §9 |
| [W14 Rank the tranches][W14] | tranche numbers |
| [`rum-coverage-roadmap.md`](../specs/rum-coverage-roadmap.md) | tranche placement, epics, §10 rulings (§13.1) |
| [W15 Catalogue and roadmap][W15] | this document |
| [W16 Metric wire row][W16] | §6.1, `custom_timer`, metric allowlist |
| [W17 Screen attribution][W17] | `screen.name` rider |
| [W18 Session boundary][W18] | `session.finalized`, `session.end_time` |
| [W19 Frame and hang vocabulary][W19] | §6.2, two-phase hang |
| [W20 Symbolication][W20] | frame format, `*.binary_images`, P18 |
| [W21 Radio and offline][W21] | `network.effectiveType` |
| [W22 Doc-truth][W22] | §12 |
| [W23 Screen readiness][W23] | `screen_ready` |
| [#168 Trace v3 backend delta][I168] + `docs/specs/distributed-trace-v3-ios.md` | §5.13, P11–P13 |

[M188]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/188
[W1]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/189
[W2]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/190
[W3]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/191
[W4]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/192
[W5]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/193
[W6]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/194
[W7]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/195
[W8]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/196
[W9]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/197
[W10]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/198
[W11]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/199
[W12]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/200
[W13]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/201
[W14]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/202
[W15]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/203
[W16]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/204
[W17]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/205
[W18]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/206
[W19]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/207
[W20]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/208
[W21]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/209
[W22]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/210
[W23]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/211
[I144]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/144
[I145]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/145
[I146]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/146
[I168]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/168
[I169]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/169
[E212]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/212
[E213]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/213
[E214]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/214
[E215]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/215
[E216]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/216
[E217]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/217
[E218]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/218
[E219]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/219
[E220]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/220
[E221]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/221
[E222]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/222
[E223]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/223
[E224]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/224
