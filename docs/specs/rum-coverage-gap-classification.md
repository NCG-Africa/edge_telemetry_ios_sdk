# Coverage classification — the 16-area iOS RUM checklist against the code

**Source of truth:** `Sources/` at `main` @ `e72928f`. Read, not run — every verdict below cites the
file and line that justifies it.

**Status:** the gap-analysis half of `docs/specs/rum-coverage-roadmap.md`. Produced for
[[W4] Classify all 16 checklist areas against the code](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/192)
under map [iOS RUM coverage](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/188).

**Input:** the as-is inventory from
[[W2] Wire inventory](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/190) —
[`docs/catalogue/as-is-wire-inventory.md`](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/blob/wayfinder/w2-wire-inventory/docs/catalogue/as-is-wire-inventory.md).
Its divergences are cited as **D1–D13**; findings first recorded here are **C1–C16**. Where this
document contradicts the inventory it says so explicitly (see [§0.3](#03-correction-to-d9)).

**What this document is not.** It classifies coverage. It proposes no fix, ranks nothing, and
names no tranche — ranking is [W14](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/202)'s
job and the roadmap is [W15](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/203)'s.

---

## 0. How to read this

### 0.1 Verdict vocabulary

| verdict | meaning |
|---|---|
| **covered** | the checklist area's intent is met by what the SDK emits today |
| **partial** | the area is instrumented but a named field or behaviour is missing |
| **absent** | nothing in `Sources/` serves the area |
| **out-of-scope** | ruled beyond this map's destination |

**Verdicts classify what the iOS SDK emits**, not what the backend stores. This follows the map's
standing preference — the catalogue is the contract, the Processor adapts. Where a signal is emitted
but not promoted to a specialised backend table, that is recorded as a **promotion delta**, not as an
iOS absence.

No area classified **out-of-scope**. The map's out-of-scope list rules out the Processor itself, the
RN/Flutter bridges, on-device Apdex, and re-deciding trace v3 — none of which is one of the sixteen
areas. §13 is the closest call: its decision work is complete and closed, so only its *ranking* is
owed, but the capability is still absent from the code and is classified that way.

### 0.2 Gap shape

One extra axis, because twelve rows reading `partial` is not a usable answer on its own. Shape says
*what kind of work closes the gap*, which is the axis W14 ranks on:

- **naming** — the signal exists and is correct; the vocabulary is wrong. Cheapest class, and the
  rename batch ([W13](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/201)) already owns it.
- **field** — the signal and its model exist; named attributes are missing.
- **model** — the underlying model does not exist. Most expensive class; a new capture, a new
  lifecycle, or a new event.

### 0.3 Correction to D9

D9 reads "three signals are emitted but never land". Verified against `#168` §3, which was written
live against `EDGETELEMETRYPROCESSORGO@2874607`, that is **too strong** and it changes three verdicts.

The accurate statement: **nothing is lost from the bag; what is lost is promotion.**

- The parent-row write and `extractTraceInfo` run at `service.go:305`, **before** the
  `event.Type == "metric"` branch at `:310`. So every iOS metric — all five fixed names and the
  unbounded host-supplied space — reaches `rum_telemetry_events.attributes` like any event.
- That metric branch then returns at `:315`, before the event-name switch at `:342`. So **no metric
  is ever promoted to a specialised table.** `screen.duration` → `rum_screen_durations` is the named
  casualty because a destination table exists and is expected to fill. `resource_timing`,
  `long_task`, `frame_render_time` and `memory_usage` have no promoted destination at all — the same
  fact seen from the other end.
- `user.interaction` is an **event**, so it does reach the switch, and falls to `default:` because
  the switch keys `ui.interaction`. Bag yes, `rum_ui_interactions` no. This one is a pure naming
  divergence (D9, `#168` §3).

So §4, §5 and §11 are **not** hollow — their data is queryable through the JSONB bag today. They are
partial for reasons of their own, listed under each. **Trap 1 as the ticket framed it — "looks
covered, data never arrives" — does not fire anywhere.** Trap 2 fires twice: [C2](#c2) and [C8](#c8).

### 0.4 Verdict summary

| # | area | verdict | shape | the one-line reason |
|---|---|---|---|---|
| 1 | App & device context | partial | field | 44 keys ride every event, but no orientation, no device family, no memory/CPU denominator, no app state |
| 2 | Session monitoring | partial | model | `session.finalized` fires on every `willResignActive` **without rotating** — it marks a flush, not a session end |
| 3 | App launch performance | partial | model | the measured window starts at `EdgeRum.start()`, not at the process — pre-main is invisible; no warm or hot launch at all |
| 4 | Screen / view-controller | partial | naming + field | three `navigation` emitters write two different name keys; no screen attribution on anything else |
| 5 | Network monitoring | partial | field | rich timing and TLS detail, but no headers, no error taxonomy, no trace context, no screen |
| 6 | Connectivity | partial | field | `network.effectiveType` never resolves a radio generation; no offline duration |
| 7 | iOS performance | partial | field + model | no CPU sample anywhere, no memory denominator, no OOM detection |
| 8 | Main-thread / UI performance | partial | field | raw 1-second frame windows with no slow/frozen classification; `long_task` has no duration key |
| 9 | Crashes | partial | field | capture is strong; the symbolication **pipeline** is missing and size-cap degradation is silent |
| 10 | Errors | partial | model | handled errors have no event of their own — they ride `app.crash`; no grouping key, no auto-capture |
| 11 | User actions | partial | model + naming | taps only, no action lifecycle, therefore no `action_abandoned`; `user.interaction` vs `ui.interaction` |
| 12 | Business events | partial | field | free-form `track`/`time`/`identify`, but unbounded metric names and no global-attributes API |
| 13 | Distributed tracing | **absent** | model | zero `trace`/`span` writes in `Sources/`; fully specified, fully unbuilt |
| 14 | Breadcrumbs | **absent** | model | zero hits for `breadcrumb` in `Sources/`, `Tests/` or `docs/` |
| 15 | App lifecycle | **covered** | — | five `UIApplication` notifications, both states, and the drain/flush hooks |
| 16 | SDK health | **absent** | model | every drop path is `os_log` under `debug` only; nothing about the SDK reaches the wire |

One covered, twelve partial, three absent.

---

## 1. App & device context — **partial** (field)

### Covered

44 context keys merged into every event in the batch (`PayloadBuilder.swift:39`), written in a fixed,
collision-free order by `ContextProvider.snapshot()` (`ContextProvider.swift:70-81`). App identity
and environment; a Keychain-backed `device.id`; hardware model, screen geometry and pixel ratio;
locale, timezone and offset; battery level and charging; thermal state and low-power mode; five
accessibility keys (`AccessibilityContext.swift:78`); disk free and total; the full network block;
session triple; user identity; SDK version and platform. Inventory §4.1 is the row-by-row list.

This is a genuinely broad context block — broader than the checklist asks for on accessibility and
storage.

### Missing

- **`device.orientation`** — no orientation key anywhere. `grep -rn -i "orientation" Sources/`
  returns nothing. Portrait-vs-landscape is unanswerable, which also removes the obvious explanation
  for a layout-shaped frame or interaction anomaly.
- **Device family / idiom.** `device.model` is the raw `utsname.machine` identifier
  (`DeviceContext.swift:7-20,95`) — `iPhone15,3`. Correct and stable, but there is no
  `userInterfaceIdiom` key, so iPhone-vs-iPad-vs-Mac-Catalyst requires a backend lookup table the
  wire does not carry. Record as a catalogue delta, not necessarily an SDK gap.
- **No memory or CPU denominator.** `grep -rn "physicalMemory\|processorCount" Sources/` returns
  nothing. `memory_usage` reports resident/virtual/footprint in absolute kB with no device ceiling,
  so "percent of available memory" — the only form in which the number is comparable across devices —
  cannot be computed anywhere in the pipeline. Feeds §7.
- **No app state at emit.** Only the `app_lifecycle` event carries `lifecycle.state`. Every other
  event is silent about whether the app was foregrounded, so a background-emitted event is
  indistinguishable from a foreground one.
- **No carrier / SIM.** `CTCarrier` is deprecated from iOS 16 and returns placeholder values; the
  honest position is to record this as consciously unavailable rather than as a gap.
- **No install or first-launch markers** — no `app.first_launch`, no install id distinct from
  `device.id`, no `app.previous_version`. Version-adoption and upgrade-regression questions are not
  answerable from the wire.

### Findings

<a id="c1"></a>**C1 — `network.effectiveType` can never produce its own declared enum.** The key is
documented as `2g | 3g | 4g | 5g | wifi | unknown` (inventory §4.1), but `NetworkContext.from(_:)`
(`NetworkContext.swift:80-116`) only ever writes `unknown`, `wifi`, `cellular` or `wired` — and
`cellular` is not a member of that enum. The `CTTelephonyNetworkInfo` refinement is a comment
(`NetworkContext.swift:96`), not code. So the declared contract is unsatisfiable as written and every
cellular session reports the same value. Also §6.

<a id="c2"></a>**C2 — context values are flush-time, up to five minutes stale, and this makes
per-event device condition unanswerable.** The snapshot is taken in `Recorder.flush`
(`Recorder.swift:416`) and merged into *every* event in the batch (`PayloadBuilder.swift:39`), and the
underlying power/accessibility/storage snapshots refresh on notification plus a 5-minute
`DispatchSourceTimer` (`ContextObservers.swift:75,195`). So `device.batteryLevel`,
`device.thermal_state` and `device.disk_free_mb` on an event are the values as of flush, themselves
up to five minutes old. Already carried as clause 3 of the catalogue header contract
([W1](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/189)); recorded here as a **trap 2
hit** — the values are collected accurately and what reaches the wire does not mean what a reader
assumes.

**Trap 1:** does not fire. All 44 keys are on the parent row.

---

## 2. Session monitoring — **partial** (model)

### Covered

`session.id`, `session.start_time` and `session.sequence` on every event. `session.started` and
`session.finalized` are both on the forced-emit allowlist (`Sampler.swift:22-28`), so they survive
sampling. 30-minute idle rotation emits a finalized/started pair carrying the prior session's identity
before the context rotates (`Recorder.swift:513-518`, `SessionContext.swift:70,93-105`). Session state
persists across launches (`UserDefaultsSessionStore.swift`). The crash sidecar carries the crashed
session's identity onto a replayed `app.crash` (inventory §4.3).

### Missing

- **No maximum session duration.** `SessionManager` has exactly one rotation rule — 30 minutes of
  inactivity (`SessionContext.swift:70,93`). A continuously-used app never rotates, so a kiosk or a
  long-running session grows without bound.
- **No session rollup fields.** `crash_count`, `error_count`, `screen_count` and `action_count` do not
  exist. Whether these belong in the SDK or the analytics layer is a live question and depends on the
  action model — it stays as map fog for now, but this classification confirms the fields are absent,
  not merely unpromoted.
- **No session type or launch reason** — user launch vs background fetch vs push vs background-URLSession
  wake. `handleBackgroundEvents` (`EdgeRum.swift:444`) exists, so background-woken sessions are real.
- **No session duration on `session.finalized`.** A consumer must subtract timestamps, and
  `session.start_time` is only re-stated on the event for the **idle-rotation** variant (D2), not for
  the lifecycle one.
- **`session.sequence` is a transport counter, not an event ordinal.** It increments once per ACKed
  batch (`SessionContext.swift:106-116`), so it cannot be used to detect a gap in the event stream,
  which is the thing a sequence number is usually reached for.

### Findings

<a id="c3"></a>**C3 — `session.finalized` marks a flush, not a session end, and one `session.id` can
carry many of them.** `LifecycleCapture` emits `session.finalized` on **every** `willResignActive`
(`LifecycleCapture.swift:149-156`) and again on `willTerminate` (`:179-186`). `willResignActive` fires
for a Control-Centre pull-down, an incoming call, an app-switcher peek, a permission alert or a Face ID
prompt — not only for a real backgrounding. Critically, **nothing rotates the session on that path**:
`SessionManager.rotate()` has no caller anywhere in `Sources/` (`grep -rn "\.rotate()" Sources/`
returns nothing; the only caller is `Tests/EdgeRumTests/Persistence/IdentityFormatTests.swift:28`), and
`Recorder.stop()` (`:303-311`) does not rotate either. So the event means "the buffer was flushed
because the app may be about to suspend", and any consumer counting sessions by `session.finalized`,
or pairing started/finalized to compute duration, overcounts by the number of interruptions. This is
the single largest §2 finding and it is a correctness defect, not a missing field.

<a id="c14"></a>**C14 — a sampled-out session is invisible rather than marked.** `session.started` and
`session.finalized` are forced-emit; `app_lifecycle`, `navigation` and everything else are not
(`Sampler.swift:22-28`), and metrics have **no** forced-emit list at all
(`Sampler.swift:56-61`). So a sampled-out session arrives as a bare started/finalized pair with no
trail, which is indistinguishable on the wire from a session in which the user did nothing. Nothing
records the sampling decision. Also §16.

---

## 3. App launch performance — **partial** (model)

### Covered

Exactly one `page_load` event per process (`PageLoadCapture.swift:200-232`), carrying
`page_load.duration_ms`, `page_load.cold_start`, `page_load.prewarmed` and
`page_load.source = "displaylink"`. The end of the window is honest: the first `CADisplayLink` tick
observed while `applicationState == .active`, with a defensive re-check for an alert racing the
transition (`:289`). Prewarm is read from the iOS 15+ `ActivePrewarm` environment variable.

### Missing

<a id="c4"></a>**C4 — the measured window starts at the SDK, not at the process, so this is not launch
time.** `launchStart` is a lazily-initialised `Date()` (`PageLoadCapture.swift:71-79`) touched from
`EdgeRum.start()` (`EdgeRum.swift:184-189`). Everything before that — dyld, static initialisers,
`+load`, and whatever host work runs ahead of the SDK — is outside the measurement. There is no
`kinfo_proc`/`KERN_PROC_PID` process-start read and **no MetricKit anywhere**
(`grep -rn "MetricKit\|MXMetric\|kinfo_proc" Sources/` returns nothing), so the true process start is
not obtainable today. The number is "SDK start to first frame", and it is named as if it were launch
time. Anything that slows a host's pre-main is invisible to it.

<a id="c5"></a>**C5 — `cold_start` is defined as `!prewarmed`, which is not what cold start means.**
`PageLoadCapture.swift:293-294`. A warm launch — process gone, page cache hot — and a genuinely cold
one both report `cold_start = true` as long as the process was not prewarmed. The key answers "was
this prewarmed", and there is already a `prewarmed` key that answers exactly that.

- **No warm and no hot launch at all.** The `_emitted` one-shot (`:200-210`) fires once per process, so
  foreground-from-background produces no duration of any kind. Resume latency — the most frequent
  launch a user experiences — is unmeasured.
- **No phase breakdown** — no pre-main, no main→first-frame, no first-frame→interactive split, so a
  regression cannot be localised.
- **Time-to-interactive** stays open; it may not be honestly measurable without host cooperation.
  Graduated out of map fog into its own ticket by this classification.

**Trap 1:** does not fire. `page_load` is an allowlisted event and reaches the switch.

---

## 4. Screen / view-controller monitoring — **partial** (naming + field)

### Covered

`navigation` from three emitters: the `viewDidAppear` swizzle (`UIViewControllerCapture.swift:309`),
the `.edgeRumScreen` SwiftUI modifier (`ViewModifiers.swift:54`) and `EdgeRum.trackScreen`
(`EdgeRum.swift:340`). Dwell time as a `screen.duration` metric on disappear
(`UIViewControllerCapture.swift:337`, `ViewModifiers.swift:81`) with `screen.name`, `screen.kind` and
`screen.duration_ms`. Both UIKit and SwiftUI are instrumented, which is more than many SDKs manage.

### Missing

- **Three emitters, two different name keys** (D3). The swizzle and `.edgeRumScreen` write
  `navigation.screen`; `EdgeRum.trackScreen` writes **`navigation.name`** and omits `navigation.kind`
  and `navigation.type` entirely. There is no single key a consumer can read to get the screen name.
  Pure naming work — the cheapest fix on this list and the clearest W13 candidate.
- **No screen identity.** Screens are joined by name only; there is no per-visit id, so two visits to
  the same screen cannot be told apart, and a `navigation` cannot be tied to its own later
  `screen.duration`.
- **No time-to-interactive / render-complete**, only appear-to-disappear dwell. See [C4](#c4) — the
  same measurement problem as launch, one level down.
- **No screen-scoped counts** — no errors, resources or actions per screen.

### Findings

<a id="c6"></a>**C6 — nothing outside the screen events carries a screen name, so "which screen"
is unanswerable for every other signal.** Checked row by row against inventory §4.2:
`http.request`, `resource_timing`, `frame_render_time`, `memory_usage`, `long_task`, `app.crash`,
`custom_event` and host-named metrics carry **no** screen key. The single exception is
`interaction.screen`, and only on the UIKit path of `user.interaction`
(`InteractionCapture.swift:276-288`). So the SDK cannot answer "which screen was slow", "which screen
made this call", "which screen crashed", or "which screen leaks memory". This is one gap, it cuts
across §5, §7, §8, §9 and §11, and it is the highest-leverage finding in this document — closing it
is a single mechanism (a current-screen read at emit) that raises five areas at once.

**Promotion delta:** `screen.duration` is a metric, so it reaches the bag but never
`rum_screen_durations` ([§0.3](#03-correction-to-d9)). Dwell time is queryable today only through
JSONB.

---

## 5. Network monitoring — **partial** (field)

### Covered

Genuinely deep. `http.request` carries method, sanitised URL, host, path, status, duration, request
and response sizes, cache hit and transport error (`HTTPCapture.swift:350`), plus a metrics enrichment
block with redirect count, TLS protocol and cipher, connection reuse, proxy use, normalised ALPN,
pre-encoding body bytes and — iOS 17+ — cellular fallback (`:371,415`). `resource_timing` adds the
DNS / connect / TLS / TTFB / download phase breakdown.

Interception is layered and thought through: a globally-registered `URLProtocol` plus class-method
swizzles on `URLSessionConfiguration.default` and `.ephemeral` so custom sessions are picked up
(`HTTPCapture.swift:7-15,174,188`). Self-traffic is excluded by three independent checks before
`ignoreUrls` and `sanitizeUrl` run (`:29-33,230-246,306`).

### Missing

- **`background` URLSession configurations are not instrumented**, by design — they have no in-process
  delegate window for `URLSessionTaskMetrics` (`HTTPCapture.swift:15-17`). Host uploads and downloads
  that run in the background are invisible. This is a stated, reasoned exclusion; it belongs in the
  catalogue as a documented blind spot rather than as a bug.
- **No WebSocket, no `WKWebView`, no non-`URLSession` stack** (CFNetwork, gRPC, `dart:io`). `#168` §2
  records real measurements of these ceilings.
- **No headers, request or response**, not even an allowlisted subset — so no `content-type`, no
  correlation id, no `server-timing`. No body capture, which is the right default.
- **No trace context.** Nothing injects `traceparent` and no span or trace attribute is written
  anywhere (`grep -rn "traceparent\|trace_id\|span_id" Sources/` returns nothing). §13 is the whole
  story here.
- **No screen attribution** ([C6](#c6)) and no per-view resource cap, so a chatty screen is neither
  identifiable nor bounded.
- **No retry or attempt counter** — a request retried three times is three unrelated events.

### Findings

<a id="c7"></a>**C7 — HTTP failures have a sentinel and free text where they need a taxonomy.**
`http.status_code` is `0` whenever the response was not an `HTTPURLResponse` (inventory §4.2), so a
transport failure is indistinguishable from a genuine status of 0 and from an unparsed response. The
only other signal is `http.error`, a `String(describing:)` of the underlying error — unbounded,
version-dependent and potentially localised. There is no `timeout` / `cancelled` / `dns` / `tls` /
`offline` class and no `http.handled` boolean, so error-rate dashboards must regex free text.

**Promotion delta:** `http.request` is an event and promotes normally; `resource_timing` is a metric
and stops at the bag ([§0.3](#03-correction-to-d9)), taking every phase-timing number with it. It also
restates four `http.request` keys under a second prefix on a row always emitted alongside it (D13).

---

## 6. Connectivity — **partial** (field)

This section resolves the map's *Not yet specified* patch "Connectivity event completeness (§6)".

### Covered

`NWPathMonitor` transitions drive one forced-emit `network_change` event, deduplicated by a
fingerprint over type, effective type, both flags and the unsatisfied reason, so a chatty monitor
cannot flood the wire — and context is refreshed **even when the event itself is deduped**
(`NetworkPathCapture.swift:225-251`). The event carries `network.type`, `network.effectiveType`,
`network.is_expensive`, `network.is_constrained` and, when the path is unsatisfied, a five-member
`network.unsatisfied_reason`.

**On the fog question — one event or three:** the single `network_change` name covers all three shapes
the fog patch asked about. `network_available` and `network_lost` are readable from
`network.type == "none"` and the presence of `network.unsatisfied_reason`; a third name would add
nothing the bag does not already answer. The shape is **complete**; the two misses below are about
values, not about event names.

### Missing

- **[C1](#c1) — no radio generation.** `network.effectiveType` never resolves 2g/3g/4g/5g; every
  cellular session reports the literal `cellular`, which is outside the key's own declared enum. So
  "how do users on slow radios experience this app" — the main reason the key exists — is
  unanswerable, and the declared contract is currently a fiction.
- **No offline duration.** Transitions are stamped but nothing pairs lost→restored, so time-offline is
  a backend derivation across two events — and it is lost entirely if the app is killed while offline,
  because the restoring event never happens.
- **Two spellings for the same facts on one event** (D8): context writes `network.expensive` /
  `network.constrained` while the event writes `network.is_expensive` / `network.is_constrained`, so
  both pairs appear on `network_change`. Naming work, W13.

---

## 7. iOS performance — **partial** (field + model)

Device-level resource health: memory, disk, thermal, battery, CPU.

### Covered

`memory_usage` every 10 seconds and on every memory-pressure notification
(`MemorySampler.swift:151`, driver `:241`), carrying `memory.resident_kb`, `memory.virtual_kb`,
`memory.footprint_kb` and a three-level `memory.pressure`. `device.disk_free_mb` / `disk_total_mb`,
`device.thermal_state` (four levels), `device.batteryLevel`, `device.batteryCharging` and
`device.low_power_mode` ride the context block.

### Missing

<a id="c8"></a>**C8 — there is no CPU measurement.** The only CPU number the SDK emits anywhere is
`hang.cpu_usage`, and it appears solely on an `app.crash` with `cause = "Hang"` (inventory §4.2). So
CPU is sampled only in the one situation where the app is already broken. There is no periodic sample,
no per-session or per-screen CPU figure, and no thread-level breakdown. This is a **trap 2 hit** from
the other direction: an `app.crash` bag that contains a CPU reading makes the area look instrumented
when nothing routine collects it.

- **No memory denominator** (§1) — absolute kB with no device ceiling and no jetsam limit, so footprint
  is not comparable across devices and "near the limit" is not computable.
- **No OOM / jetsam detection.** Nothing correlates "previous session ended with no `session.finalized`
  and no crash report" into an OOM signal — and [C3](#c3) makes that inference materially harder,
  because `session.finalized` is emitted on interruptions too, so its absence is a weaker signal than
  it looks. Whether OOM is detectable at all is
  [W11](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/199)'s question; this classification
  records only that nothing attempts it.
- **No disk I/O and no energy metrics**, and no MetricKit (`MXCPUMetric`, `MXDiskIOMetric`,
  `MXAppLaunchMetric`) — zero hits in `Sources/`. MetricKit would supply several of these gaps at
  once, at the cost of next-launch-only delivery.
- **Battery and thermal are 5-minute-stale context, not per-event readings** ([C2](#c2)).
- **No screen attribution** ([C6](#c6)) — memory growth cannot be localised to a screen.

**Promotion delta:** `memory_usage` is a metric, so bag-only ([§0.3](#03-correction-to-d9)). No
promoted destination exists for it today.

---

## 8. Main-thread / UI performance — **partial** (field)

This section resolves the map's *Not yet specified* patch "Frame performance depth (§8)".

### Covered

Three independent mechanisms, which is more than the checklist strictly asks for:

- `frame_render_time` every 1-second window from a `CADisplayLink` (`FrameSampler.swift:220`), carrying
  `frame.max_ms`, `frame.p95_ms`, `frame.dropped_count`, `frame.target_hz`, `frame.sample_count` and
  `frame.source`, with `targetHz` read from the display so ProMotion is handled.
- `long_task` for any run-loop gap ≥ 50 ms (`RunLoopObserverCapture.swift:53,132`), with
  `long_task.threshold_ms` and a 4096-byte-truncated `long_task.stack`.
- The hang watchdog: ≥ `hangTimeout` (default 5 s, hard floor 2 s — `HangDetector.swift:47-58`) emits
  `app.crash` with `cause = "Hang"`, `hang.duration_ms`, `hang.threshold_ms`, `hang.cpu_usage` and a
  Mach-based main-thread stack captured off the main thread (`:24-25`).

### Missing

- **No slow/frozen frame classification and no ladder.** The wire carries raw numbers per window and no
  vocabulary — nothing says which windows were user-visibly bad. Every threshold decision is pushed to
  the backend, which then needs `frame.target_hz` to do it, which it has. So this is a vocabulary gap
  rather than a data gap, and cheaper than it looks.
- **`long_task` has no duration attribute.** The stall length exists **only** as the envelope `value`
  (inventory §3); the bag carries a threshold and a stack but not the duration. A consumer reading
  attributes alone sees that something was slow and not how slow.
- **No screen or action attribution** on frames, long tasks or hangs ([C6](#c6)).
- **Hangs are filed as crashes.** `cause = "Hang"` on `app.crash` mixes a recoverable stall into the
  crash stream, and `crash.fatal` is the only other discriminator (D5). Any crash count that does not
  filter on `cause` is wrong. Also §10.
- **No hang tiers** — one threshold, so a 2-second stall and a 30-second freeze are the same event
  shape.

### Findings

<a id="c9"></a>**C9 — `frame.dropped_count` is inferred, not observed, and over-reports whenever the
display link is throttled.** `FrameWindowAggregator` computes `expected − observed` from
`targetHz × windowSeconds` (`FrameSampler.swift:113-122`), and a window with zero samples reports the
full expected count as dropped (`:113-114`). Any window in which the link legitimately runs slow —
low-power mode, ProMotion ramp-down, thermal throttling, the moment around backgrounding — reports
frames the user never missed. The file already guards the backgrounding case (`:23`), which shows the
problem was seen; the remaining cases are not guarded. Note the interaction with [C2](#c2): the very
context that would explain the throttling (`device.low_power_mode`, `device.thermal_state`) is
flush-time and up to five minutes stale.

- **Volume:** the window emits unconditionally, even when perfectly smooth — roughly 60 metrics per
  foregrounded minute (inventory §6). Not a coverage gap, but it is the SDK's largest volume driver and
  it is the reason O1 is a prerequisite.

---

## 9. Crashes — **partial** (field)

### Covered

The capture half is strong. PLCrashReporter handles Mach exceptions and signals; the report is replayed
on the next launch and folded onto the **crashed** session's identity from the sidecar
(`PLCrashIntegration.swift:174`, inventory §4.3). On-device symbolication runs with
`symbolicationStrategy: .all` (`:196`). `crash.report_json` embeds the report with binary images and
their UUIDs preserved specifically so the backend can dSYM-symbolicate without walking the full report
(`CrashReportEncoder.swift:97,209-222`), alongside promoted `crash.signal`, `crash.signal_code`,
`crash.exception_name`, `crash.exception_reason`, `crash.binary_uuid` and `crash.binary_name`. The
event is forced-emit and triggers an immediate flush.

### Missing

<a id="c10"></a>**C10 — the size-cap fallback discards exactly what symbolication needs, silently.**
When the encoded report exceeds the cap, `CrashReportEncoder` first strips registers and then sets
`dict["binary_images"] = []` (`CrashReportEncoder.swift:115-124`). Binary images are the load addresses
and UUIDs that make backend dSYM symbolication possible, so the reports most likely to be stripped —
the big, deep, interesting ones — are the ones that arrive unsymbolicatable. **No attribute records
that stripping occurred**, so a backend cannot distinguish "this crash had no binary images" from "we
threw them away", and the failure presents as a mysterious symbolication miss.

- **No dSYM upload pipeline in this repo.** The wire carries UUIDs; nothing uploads the matching symbols
  to a symbol server, and there is no build-phase upload step. Without it, backend symbolication cannot
  run at all — so the careful UUID preservation above currently has no counterpart. This is a
  **pipeline** gap, not a wire gap, and it is the largest single item in this area.
- **Three producers with near-disjoint bags** (D5): `crash.fatal` is absent on the `AppError` bag, so
  fatality is not uniformly answerable, and `crash.timestamp` is likewise absent there. `cause` is the
  only reliable discriminator.
- **No context at crash time.** A replayed crash carries the *next* launch's network and battery values
  because transient context is deliberately not mirrored (inventory §4.3). Defensible — but it means
  device conditions at the moment of the crash are unavailable, and [C2](#c2) means they would have been
  stale anyway.
- **No breadcrumb trail** (§14), **no screen** ([C6](#c6)), and **no crash-free-session rate** (needs the
  §2 rollups).

---

## 10. Errors — **partial** (model)

### Covered

`EdgeRum.captureError` (`EdgeRum.swift:368`) produces a well-built error bag via `AppErrorBuilder`:
`error.type`, `error.message`, `error.kind`, `error.domain`, `error.code`, a 4096-byte-truncated
`error.stack`, the flattened `error.userInfo.*` prefix, and a caller-supplied `crash.context.*` prefix.
Bridged Swift errors and `NSError` are both handled, with a synthetic domain for the former.

### Missing

<a id="c11"></a>**C11 — handled errors have no event of their own.** Every caught error is emitted as
`app.crash` with `cause = "AppError"` (inventory §3), so the crash stream contains crashes, hangs and
handled errors together. `crash.fatal` — the obvious way to filter — is **absent** on exactly this bag
(D5), so the only correct filter is `cause`, a key whose name gives no hint that it discriminates
fatality. Any consumer that counts `app.crash` rows and calls the result a crash count is wrong, and
the wire does nothing to warn them.

- **Manual capture only.** Nothing auto-captures unhandled Swift errors, failed HTTP responses, decoding
  failures, or Combine/async failures. An error reaches the wire only if a host developer remembered to
  call `captureError`, which makes error volume a measure of host diligence rather than of app health.
- **No fingerprint or grouping key.** Nothing on the wire groups two occurrences of the same error;
  grouping is entirely backend-side off free-text `error.message`, which is unbounded and may be
  localised.
- **No severity and no `handled` boolean.**
- **Truncation is unmarked.** `error.stack` truncates whole-frame at 4096 B with no flag, so a truncated
  stack looks like a short one — the same defect species as [C10](#c10).
- **Two open prefixes** — `error.userInfo.*` and `crash.context.*` (inventory §4.2) — are unbounded
  host-controlled key spaces with no redaction, feeding
  [W7](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/195) directly.

---

## 11. User actions — **partial** (model + naming)

### Covered

A `UIWindow.sendEvent` swizzle captures completed touches (`InteractionCapture.swift:180`) and emits
`user.interaction` with `interaction.kind`, `interaction.target`, `interaction.target_id` and
`interaction.screen`. Secure-entry fields are excluded and the capture path never reads `.text` from
any view (`:21`, `:188-191`) — a good privacy default, built in rather than configured. `.edgeRumTrackTap`
gives SwiftUI hosts a manual path.

### Missing

- **No action lifecycle, therefore no `action_abandoned`.** An interaction is a point event with no
  start/end, no duration, and no attached resources or errors. Nothing can express "the user tapped,
  something began, and it never finished" — which the map's Notes already identify as the genuinely hard
  SDK problem. Owned by [W5](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/193).
- **Taps only.** `interaction.kind` is the constant `tap` (inventory §4.2) — no swipe, scroll,
  long-press, pan, keyboard or SwiftUI gesture.
- **Two producers with no key in common** (D4). UIKit writes `interaction.target` / `target_id` /
  `screen`; `.edgeRumTrackTap` writes `interaction.name` and nothing else. There is no single "what was
  tapped" key across the two.
- **No frustration signals** — no rage click, dead click or error click.
- **`interaction.target_id` collapses two different things** (D11): `accessibilityIdentifier` when
  present, otherwise the rendered button title (`InteractionCapture.swift:276-288`). So one key is
  sometimes a stable test id and sometimes user-visible copy — a grouping hazard and a PII hazard at
  once. `#168` §1 row 4 already proposes `interaction.name_source` as the discriminator, but that key is
  part of trace v3 and is **not on the wire today**.

**Promotion delta:** the naming divergence is the whole story — `rum_ui_interactions` stays empty
because the Processor switch keys `ui.interaction` (D9, `#168` §3). The data is in the bag; one name
reconciles it.

---

## 12. Business events — **partial** (field)

### Covered

Three host-facing surfaces. `EdgeRum.track(name:attributes:)` → `custom_event` (`EdgeRum.swift:330`).
`EdgeRum.time(name)` → `RumTimer`, emitting a host-named metric with `duration_ms`
(`RumTimer.swift:50,62`). `EdgeRum.identify` → `user.profile.update` carrying the host's
`user.external_id` alongside the SDK-owned `user.id` (`EdgeRum.swift:310`). All five host entry points
apply SDK-owned keys **last** so a caller cannot overwrite them (inventory §4.4) — a good default.

### Missing

- **Metric names are unbounded while event names are allowlisted** (D7). `recordPerformance` consults no
  allowlist, so `EdgeRum.time("chekout")` becomes a permanent new metric name on the wire, whereas an
  unknown event name is dropped on ingress with a debug log (`Recorder.swift:322-331`). The asymmetry is
  the gap — one half of the wire is guarded and the other is not.
- **No typed business vocabulary** — no revenue, currency, conversion or funnel-step shape. Every
  business event is a free `[String: AttributeValue]` bag with no prefix, allowlist or cardinality guard
  (inventory §4.4).
- **`custom_event` buries the host's name in an attribute.** The event name on the wire is the literal
  `custom_event`; the host's chosen name travels as the `event.name` attribute (inventory §3), so every
  business event shares one name and must be split in the bag.

### Findings

<a id="c12"></a>**C12 — there is nothing between SDK-owned context and a per-call bag.** No
`setGlobalAttribute` / `addAttribute` API exists (`EdgeRum.swift` public surface: `start`, `identify`,
`track`, `trackScreen`, `time`, `captureError`, `disable`, `enable`, `handleBackgroundEvents`). A host
cannot set a tenant id, a feature-flag variant, an experiment arm or a build channel once and have it
ride every event; it must be passed to every call, and there is no call at all for automatically
captured events like `http.request` or `app.crash`. `identify` is the only persistent host-controlled
state and it reaches exactly four keys.

<a id="c13"></a>**C13 — there is no logout and no consent surface.** No `clearUser()`, so `user.name`,
`user.email` and `user.phone` — stored **verbatim** (inventory §4.1) — persist in context for the life
of the process once `identify` has been called; a subsequent user on the same device inherits them until
a new `identify` overwrites them or the process ends. The only lever is `EdgeRum.disable()`
(`EdgeRum.swift:391`), which stops everything. Feeds
[W7](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/195).

- **`RumTimer.cancel()` emits nothing** (`RumTimer.swift:68`), so an abandoned timing is silent. Same
  hole as `action_abandoned`, one layer up: the wire records completions and is blind to abandonments.

---

## 13. Distributed tracing — **absent** (model)

`grep -rn "traceparent\|trace_id\|traceId\|span_id\|spanId" Sources/` returns **zero hits**, and
inventory §3 records `span = no` on every event row. Nothing writes a trace or span attribute, nothing
injects a `traceparent` header, and no root is minted.

This is the only area whose decision work is finished. `docs/specs/distributed-trace-v3-ios.md` and
ADR-015 are merged and authoritative, `#168` records the verified backend delta against
`EDGETELEMETRYPROCESSORGO@2874607` — the schema already serves iOS with **no new column and no new
table** — and the implementation epic #169 with tasks #170–#186 is closed `NOT_PLANNED`. Per the map's
Notes this map does not reopen any of it and owns only where tracing sits in the ranking.

Two consequences worth carrying into W14, because they change tracing's rank rather than its content:

- Tracing is what would give §11 an action model and §5 a request-to-action join. Several `model`-shaped
  gaps elsewhere are partly downstream of this one being unbuilt, so ranking tracing purely on its own
  value understates it.
- W3's O1 decision **amends** the trace v3 spec's §12.1 "zero new I/O" claim and its §13 O1 row. Nothing
  regresses, because the spec is spec-only — but a reader of the merged spec will find those two
  statements false until W15 writes the amendment.

---

## 14. Breadcrumbs — **absent** (model)

`grep -rln -i "breadcrumb" Sources/ Tests/ docs/` returns **nothing**. No ring buffer, no automatic
breadcrumb from navigation / network / lifecycle / interaction, no public `addBreadcrumb`, and nothing
attaches a trail to `app.crash`.

The raw material exists — `navigation`, `http.request`, `app_lifecycle` and `user.interaction` are all
emitted — but only as independent events on a **sampled, batched** wire. Reconstructing a trail
backend-side therefore works only for sessions that were sampled in ([C14](#c14)) and whose batches all
arrived; the `OfflineQueue` is a 200-file drop-oldest FIFO drained with unbounded delay (`#168` §4,
`OfflineQueue.swift:7-8,81,204-205`), so the batches immediately preceding a crash are exactly the ones
most likely to be missing. A breadcrumb buffer attached to the crash event is the only construction that
survives that. Owned by [W6](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/194).

---

## 15. App lifecycle — **covered**

Five `UIApplication` notifications drive `app_lifecycle` (`LifecycleCapture.swift:148-186`), carrying
`lifecycle.state` and `lifecycle.previous_state` over a five-member enum plus `unknown` for the first
emission after install. `didBecomeActive` also drains the offline queue (`:172-177`), and both
`willResignActive` and `willTerminate` force a flush through `session.finalized` (`:155,185`) so the
buffer is on the wire before the OS suspends or kills the process. Scene-based apps are covered because
`UIApplication` notifications still fire.

The area's own intent is met. Two caveats belong to adjacent areas and are not missing lifecycle
coverage:

- `app_lifecycle` is **sampled**, not forced-emit (`Sampler.swift:22-28`), so a sampled-out session has
  no lifecycle trail at all — [C14](#c14), §2 and §16.
- The finalized-on-resign behaviour is [C3](#c3), a §2 defect.

---

## 16. SDK health — **absent** (model)

Nothing about the SDK's own behaviour reaches the wire. Every failure and drop path is `os_log` under
`debug` only, which means it is invisible in production by construction:

| what is lost | where | recorded as |
|---|---|---|
| batch dropped — offline queue unavailable | `HTTPTransportSink.swift:158-166` | debug `os_log` |
| batch dropped — non-retryable status | `HTTPTransportSink.swift:165-173` | debug `os_log` |
| oldest queued batches deleted at the 200-file cap | `OfflineQueue.swift:7-8,81,204-205` | **nothing** |
| event dropped — name not in the allowlist | `Recorder.swift:322-331` | debug `os_log` |
| non-primitive `NSError.userInfo` values dropped | `AppErrorBuilder.swift:138-151` | debug `os_log` |
| tap dropped — secure field in the hierarchy | `InteractionCapture.swift:188-191` | **nothing** |
| session excluded by sampling | `Sampler.swift:33-53` | **nothing** ([C14](#c14)) |

### Findings

<a id="c15"></a>**C15 — a quiet app and a broken SDK are indistinguishable on the wire.** There is no
queue depth, no drop count, no flush success or failure rate, no batch latency, no init duration, no SDK
error signal and no record of the sampling decision. Every one of the rows above is a silent data loss,
and because `session.started` / `session.finalized` / `app.crash` / `network_change` are forced-emit
while everything else is not, a session that dropped 200 batches still produces a plausible-looking
started/finalized pair.

<a id="c16"></a>**C16 — the reflexivity problem is real and structural.** Any health signal the SDK emits
must travel through the same `Recorder.enqueue` → `SessionSidecar.write` → `OfflineQueue` →
`HTTPTransportSink` path whose health it is reporting, so the failure modes that most need reporting are
exactly the ones that suppress the report. W3's O1 decision changes the first hop's cost but not this
property. Owned by [W8](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/196); recorded here
so the area is not read as "just add some counters".

---

## 17. Cross-cutting findings

Four findings are not confined to one area and are listed once, because ranking them per-area would
count the same work three or four times.

1. **[C6](#c6) — no screen attribution outside the screen events.** Raises §5, §7, §8, §9 and §11 with a
   single mechanism. The highest-leverage item in this document.
2. **[C2](#c2) — flush-time context.** Every "what were the device conditions when X happened" question
   in §1, §7 and §8 is answered with a value up to five minutes stale. Already a catalogue header clause;
   it is a defect as well as a documentation problem.
3. **[C3](#c3) — `session.finalized` marks a flush, not a session end.** Corrupts session counts (§2),
   weakens OOM inference (§7), and makes "sessions per user" wrong by the number of interruptions.
4. **Silent degradation has no marker anywhere.** [C10](#c10) strips binary images, §10 truncates stacks,
   [C15](#c15) drops whole batches, and `frame.dropped_count` ([C9](#c9)) infers rather than observes —
   in every case the wire looks normal and the consumer cannot tell. One convention (a `*.truncated` /
   `*.degraded` marker) addresses all four.

---

## 18. What this feeds

| ticket | what it takes from here |
|---|---|
| [W5 Action lifecycle](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/193) | §11 — point events only, no lifecycle; `RumTimer.cancel()` is the same hole one layer up |
| [W6 Breadcrumb model](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/194) | §14 — absent; and why backend reconstruction from existing events cannot substitute |
| [W7 PII & redaction](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/195) | D11 / [C13](#c13) — `interaction.target_id`, verbatim user fields, no logout, two open prefixes |
| [W8 SDK self-monitoring](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/196) | §16 — the seven silent-loss sites and [C16](#c16) |
| [W9 Launch performance](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/197) | [C4](#c4) / [C5](#c5) — the window starts at the SDK; `cold_start` means `!prewarmed`; no warm or hot launch |
| [W10 Context gaps](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/198) | §1 — orientation, device family, memory/CPU denominator, app state; [C2](#c2) |
| [W11 Error taxonomy & OOM](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/199) | [C11](#c11) — errors ride `app.crash`; and how [C3](#c3) weakens the OOM inference |
| [W12 Sampling policy](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/200) | [C14](#c14) — sampled-out sessions are invisible, not marked; metrics have no forced-emit list |
| [W13 Rename batch](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/201) | D3, D4, D8, D9, D10, D12 and [C1](#c1) — every naming-shaped gap above |
| [W14 Rank the tranches](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/202) | [§0.4](#04-verdict-summary) verdicts + shapes, and [§17](#17-cross-cutting-findings) so shared work is counted once |
| [W16 Metric wire row](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/204) | D6 / D7 and [§0.3](#03-correction-to-d9) — units are unstated, names unbounded, and no metric is ever promoted |
