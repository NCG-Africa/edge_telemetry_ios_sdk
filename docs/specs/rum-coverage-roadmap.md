# iOS RUM coverage — roadmap

**Status:** frozen. Destination artifact of wayfinder map [iOS RUM coverage][m188]
([W15 — write the catalogue and roadmap][w15]). Every decision here was resolved on a ticket;
[§12](#12-ticket-map) maps each ticket to the section that carries it. Where a ticket and a later
ticket disagree, **this spec wins** — and where this spec and any ticket disagree, **this spec
wins**. Several ticket premises were corrected by later tickets; [§10](#10-conflicts-resolved-by-this-spec)
lists every disagreement and the ruling.

**Planned against:** `147c64d` (`wayfinder/w15-catalogue-roadmap`). `file:line` citations are
inherited from the ticket that verified them and are not re-verified here.

**Companion documents.**

| document | role |
|---|---|
| [`docs/catalogue/ios-data-catalogue.md`](../catalogue/ios-data-catalogue.md) | **the contract** — every event and attribute, its PII class, scope, unit and platform delta. This roadmap says *when* a row changes; the catalogue says *what* it is. |
| [`rum-coverage-gap-classification.md`](rum-coverage-gap-classification.md) | the evidence — 16 areas, C1–C16, verdict and gap shape per area ([W4 — classify all 16 areas][w4]) |
| [`../catalogue/as-is-wire-inventory.md`](../catalogue/as-is-wire-inventory.md) | the as-is wire, D1–D13 ([W2 — wire inventory][w2]) |
| [`distributed-trace-v3-ios.md`](distributed-trace-v3-ios.md) | tranche 11's spec — not reopened; amended in two paragraphs only ([§9](#9-amendment-to-distributed-trace-v3-ios)) |

**Ranking rule for the whole document:** *value per unit of work.* Dependency order breaks ties
only. Ranking by dependency is what left the [distributed tracing epic][e169]'s seventeen tasks
unstarted, and is the failure this order exists to avoid.

**Implementation convention:** one epic per tranche, following the repo's F-numbered epic/task
convention — **not** a second wayfinder map. This spec is what a map would have produced.

---

## 0. How to read a tranche

| field | meaning |
|---|---|
| **Epic** | F-number and issue. |
| **Scope** | what ships, and nothing else |
| **Sources** | the tickets whose resolution this tranche implements |
| **Size** | **S** ≈ days, one PR, no new mechanism · **M** ≈ one to two weeks, one new mechanism or several touch points · **L** ≈ multi-PR epic with its own task list |
| **Why here** | the value-per-work argument for this rank |
| **Depends on** | hard SDK edges only. Soft edges say what degrades if the order is broken. The backend is never listed: it is never a gate. |
| **Acceptance** | tests and measurements that close the epic |
| **Backend / RN delta** | summary; the full write-up is the in-repo delta issue ([§11](#11-backend-and-rn-delta)) |

Every tranche is **independently shippable**: each delivers value on its own, and a tranche whose
value exists only once a later one lands would be mis-cut.

---

## 1. The 16 areas

Condensed from [W4 — classify all 16 areas][w4]; evidence, `file:line` and findings C1–C16 live in
[`rum-coverage-gap-classification.md`](rum-coverage-gap-classification.md) and are not duplicated.
**1 covered, 12 partial, 3 absent.** Shape is what kind of work closes the gap: `naming` (vocabulary
wrong), `field` (named attributes missing), `model` (underlying model missing).

| # | area | verdict | shape | closed by tranche(s) | residual after the roadmap |
|---|---|---|---|---|---|
| 1 | App & device context | partial | field | 3 (orientation, family, app state), 8 (`device.boot_time`), 10 (radio) | memory denominator and install/first-launch markers — [§8](#8-residual-gaps) |
| 2 | Session monitoring | partial | model | 4 (`session.finalized` = end, 4 h cap, `session.end_time`) | rollups are analytics-layer by ruling ([§7](#7-registry-of-absences)) |
| 3 | App launch performance | partial | model | 9 (`launch.pre_sdk_duration_ms`, anchor), 13 (`markInteractive`) | pre-main, warm, resume declined ([§7](#7-registry-of-absences)) |
| 4 | Screen / view-controller | partial | naming + field | 3 (`screen.name` rider), 4 (D3 unification), 13 (`screen_ready`) | `render_complete` declined |
| 5 | Network monitoring | partial | field | 3 (screen), 4 (`http.error` reshape, `http.url` strip), 11 (trace context) | headers never collected by ruling |
| 6 | Connectivity | partial | field | 4 (D8), 10 (radio generation) | offline duration declined |
| 7 | iOS performance | partial | field + model | 1 (`hang.cpu_usage`), 3 (screen), 5 (`cpu_usage`, pressure truth) | OOM verdict declined; memory denominator ([§8](#8-residual-gaps)) |
| 8 | Main-thread / UI performance | partial | field | 3 (screen), 5 (motion windows), 8 (two-phase hang, disjoint rungs, observed drops) | tiers are backend classification by ruling |
| 9 | Crashes | partial | field | 3 (screen at crash), 4 (frame format, C10 markers), 6 (breadcrumbs) | symbolication pipeline — unranked epic ([§5](#5-unranked-symbolication-pipeline)) |
| 10 | Errors | partial | model | 4 (`app.error` split), 8 (`error_type`) | automatic error capture — [§8](#8-residual-gaps) |
| 11 | User actions | partial | model + naming | 2 (`interaction.name_source`), 4 (D4), 12 (action lifecycle) | Apdex is analytics-layer by ruling |
| 12 | Business events | partial | field | 4 (`custom_timer`, metric allowlist, reserved namespaces) | global-attributes API — [§8](#8-residual-gaps) |
| 13 | Distributed tracing | **absent** | model | 11 | — |
| 14 | Breadcrumbs | **absent** | model | 6 | — |
| 15 | App lifecycle | **covered** | — | (3 adds `app.state` as the absolute form) | — |
| 16 | SDK health | **absent** | model | 0 (`sdk.thread_time_ms`), 7 | — |

Cross-cutting findings counted once ([W4][w4] §17): **C6** screen attribution → tranche 3;
**C3** finalized-is-a-flush → tranche 4; **C4/C5** launch anchor and `cold_start` → tranches 4 and 9;
**silent degradation** → W8's marker convention (catalogue content), consumed by tranches 4, 6, 7, 8.

---

## 2. The order at a glance

| # | tranche | epic | size | depends on | sources |
|---|---|---|---|---|---|
| 0 | Hot path | Epic: F25 ([#212](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/212)) | S | — | [W3][w3], [W8][w8], [W22][w22] |
| 1 | Doc-truth | Epic: F26 ([#213](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/213)) | S | — | [W22][w22] |
| 2 | Privacy | Epic: F27 ([#214](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/214)) | S | — | [W7][w7] |
| 3 | Riders + screen attribution | Epic: F28 ([#215](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/215)) | S | 0 | [W10][w10], [W17][w17] |
| 4 | Breaking batch | Epic: F29 ([#216](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/216)) | M | 3 (one line, soft) | [W13][w13] + [W7][w7] [W9][w9] [W11][w11] [W16][w16] [W17][w17] [W18][w18] [W19][w19] [W20][w20] |
| 5 | Sampler cut | Epic: F30 ([#217](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/217)) | M | — | [W12][w12] |
| 6 | Breadcrumbs | Epic: F31 ([#218](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/218)) | M | 0, 3 | [W6][w6] |
| 7 | SDK health | Epic: F32 ([#219](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/219)) | M | 0 | [W8][w8], [W22][w22] |
| 8 | Error evidence + two-phase hang | Epic: F33 ([#220](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/220)) | M | 0, 3, 4 | [W11][w11], [W19][w19] |
| 9 | Launch | Epic: F34 ([#221](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/221)) | S | 7 (two fields, soft) | [W9][w9] |
| 10 | Radio generation | Epic: F35 ([#222](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/222)) | S | — | [W21][w21] |
| 11 | Distributed tracing | Epic: F24 ([#169][e169]) | L | 0, 3 | [trace v3 spec](distributed-trace-v3-ios.md) |
| 12 | Action lifecycle | Epic: F36 ([#223](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/223)) | L | 0, 3, 4 | [W5][w5] |
| 13 | Host-gated readiness | Epic: F37 ([#224](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/224)) | S | 3 | [W23][w23], [W9][w9] |

Source of the order: [W14 — rank the tranches][w14]. Tracing sits **at 11, inside the order**: its
spec and ADR-015 are merged and its tasks are written, so it is cheap to *start* — but it is L-sized,
and ranking it first would queue thirteen smaller, higher-yield tranches behind seventeen tasks.

---

## 3. Tranches

### Tranche 0 — Hot path

**Epic: F25 ([#212](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/212))**

| | |
|---|---|
| **Scope** | (a) **O1 inversion:** delete the per-event `sidecar?.write(snapshot: context.snapshot())` in `Recorder.enqueue` (`Recorder.swift:539`) and the per-event `snapshot()` build with it; add the write at the three identity-mutation sites that relied on it — `setUser` (`:386`), `start()` rotation (`:285`), idle rotation (`:516`) — beside the two that exist (`:200`, `:463`); serialize `SessionSidecar.write` under its existing lock. (b) **`sdk.thread_time_ms`** — cumulative caller-thread wall-time inside SDK entry points, the acceptance instrument; session-scoped, carried on the envelope. (c) **Consent guard:** one `_enabled` early return in `Recorder.enqueue`, which covers `track`, `captureError`, `RumTimer.end` and the three SwiftUI emitters at once. |
| **Sources** | [W3 — O1][w3]; [W8 — SDK self-monitoring][w8] (instrument split across the O1 boundary); [W22 — docs vs code][w22] row 5 |
| **Size** | S |
| **Why here** | Fixed at charting: every later tranche adds volume through `enqueue`. The write is redundant, not merely expensive — all ten mirrored keys change only at init, `setUser`, rotation and ACK. The consent guard is one line in the same function, and a `disable()` that does not disable is a legal-shaped defect the privacy posture rests on. |
| **Depends on** | — |
| **Unblocks** | 3, 6, 7, 8, 11, 12 (everything that adds per-event work or consumes the sidecar's volatile zone) |
| **Acceptance** | Positive: after each of the five mutation sites the file equals `filter(context.snapshot())`. **Negative guard (load-bearing):** a spy `SessionSidecarWriting` asserts N `recordEvent` calls with no identity mutation produce **zero** writes — nothing in the suite asserts the write today, which is how O1 arose. **Before/after measurement** of `sdk.thread_time_ms` on a scripted event burst — the first real number for the volume budget ([§6](#6-volume-and-retention-budget)). After `disable()`: `track`, `captureError`, `RumTimer.end` and all three SwiftUI emitters emit nothing. |
| **Backend / RN delta** | Processor: none (`sdk.thread_time_ms` is one envelope field, additive). RN: behaviour change — bridge-forwarded calls after `disable()` now emit nothing. **The tranche-4 Processor delta is handed over when this tranche starts** ([§4](#4-rules-fixed-by-this-ranking)). |

Write rate after O1: from every event to **3–5 per session plus one per ACKed batch**. Side effect:
sidecar freshness becomes independent of sampling.

### Tranche 1 — Doc-truth

**Epic: F26 ([#213](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/213))**

| | |
|---|---|
| **Scope** | (a) **Arm the `flushInterval` timer** (`FlushReason.timer` exists, no timer is ever created). (b) **`maxQueueSize` trims by event count:** write the count into the filename (`<epochMs>-<seq>-<n>.json`), trim oldest-first to ≤ cap, no file reads. (c) **`hang.cpu_usage` wired** to a whole-process CPU reader (`task_info(TASK_THREAD_TIMES_INFO)` + dead-thread times; one inject at `EdgeRum.swift:300-305`). The reader is built here and reused by tranche 5 ([§10](#10-conflicts-resolved-by-this-spec) row 3). (d) **Threading docs amended** (`Recorder.swift:16-17`, `HangDetector.swift:28-29`) and the dead `Recorder.queue` (`:92`, `:131`) deleted. (e) **Test-per-claim** for each fix, plus one CLAUDE.md § Testing conventions rule: *a doc comment asserting runtime behaviour must have a test that pins it.* (f) Retire the `NetworkContext.swift:15-20,96` carrier TODO comment. |
| **Sources** | [W22 — docs vs code][w22] rows 1–4; [W10][w10] (TODO retirement) |
| **Size** | S |
| **Why here** | Makes shipped docs true and closes a real loss path: a quiet sampled session holds up to 29 events and loses them at process death. The documented 200-event queue cap is really ~6,000 events (files, not events). No wire change. |
| **Depends on** | — |
| **Unblocks** | 7 (counters measure real behaviour, not documented behaviour) |
| **Acceptance** | A quiet session flushes within `flushInterval`. The queue trims by event count. A hang carries `hang.cpu_usage`. `Recorder.queue` is gone and the threading docs describe caller-thread execution. The catalogue's dated corrections for all six W22 rows are true. |
| **Backend / RN delta** | Processor, informational: quiet sessions arrive sooner and lose less; the offline backlog ceiling drops from ~6,000 to 200 events, so long-offline devices drop older batches sooner; `hang.cpu_usage` appears on the wire for the first time. RN: none. |

### Tranche 2 — Privacy

**Epic: F27 ([#214](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/214))**

| | |
|---|---|
| **Scope** | (a) `EdgeRum.clearUser()` — the non-merging path `ContextProvider.refreshUser` already exists and is unreachable. (b) `EdgeRum.resetIdentity()` — the erasure hook, calling both `IdentityProvider.regenerateDeviceId()` and `regenerateUserId()`. (c) `user.name` / `user.email` / `user.phone` **off the sidecar** (`SessionSidecar.mirroredKeys:60-63`); `user.id` stays. (d) **`button_title` default-off** behind an opt-in config flag, with `interaction.name_source` on `user.interaction` (`accessibility_identifier \| button_title \| none` — trace v3's frozen spelling). (e) `PrivacyContractTests`: six absence greps (`ASIdentifierManager`, `advertisingIdentifier`, `identifierForVendor`, `allHTTPHeaderFields`, `IOPlatformSerialNumber`, `ATTrackingManager`) plus *`identity` is exactly four keys*. (f) PII class column in the catalogue (content, already written). (g) `Privacy.md` corrections pass — three false claims. (h) A review note listing the structural strips that ship physically in tranche 4. |
| **Sources** | [W7 — PII classes and redaction][w7] |
| **Size** | S |
| **Why here** | Live cross-user PII leak: `identify()` cannot be undone today, so a logged-out user's email rides every event until process death, and it is on disk in plaintext. Small and additive. **Cost line:** `button_title` off is a stated signal loss — taps on un-annotated buttons lose their label. |
| **Depends on** | — |
| **Unblocks** | — |
| **Acceptance** | After `clearUser()`, no event carries `user.name/email/phone/external_id`. `resetIdentity()` yields new `device.id` and `user.id` matching the ID-format regexes. The sidecar file never contains the three identity keys. A tap on a button with no `accessibilityIdentifier` emits `interaction.name_source = none` and no label. `PrivacyContractTests` green. |
| **Backend / RN delta** | Processor: `interaction.name_source` appears (already cleared via ADR-015); `interaction.target_id` becomes **frequently absent** — will look like a regression on dashboards, needs a human sentence; identity keys absent on replayed crashes; advisory PII-class obligations. RN: expose `clearUser()`, `resetIdentity()`, and the `button_title` opt-in flag. |

### Tranche 3 — Riders + screen attribution

**Epic: F28 ([#215](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/215))**

| | |
|---|---|
| **Scope** | (a) **Build W3's volatile contract** — a lock-free latest-wins box, flag-coalesced onto a serial queue that merges into the sidecar's volatile zone under the write lock. No sidecar format or `CrashSidecarReader` change (unrecognised keys already sweep into `extras`). (b) Riders stamped **at enqueue** into the event's own attributes (event attrs already win on merge): `device.orientation` (`portrait \| landscape`, interface orientation), `app.state` (`active \| inactive \| background`), `screen.name` (≤128 B, `.truncated` counted, absent until the first screen). (c) `device.family` as **context** (one `userInterfaceIdiom` read). (d) Rename `UIViewControllerCapture._previousScreen` to a current-screen box with **three writers** — UIKit `viewDidAppear`, `.edgeRumScreen`, `trackScreen` — written before `navigation` emits; one-level restore on sheet dismissal. (e) All riders persist on change through the volatile contract, so a replayed `NativeCrash` carries crash-time screen, orientation and app state. |
| **Sources** | [W10 — context gaps][w10], [W17 — screen attribution][w17]; mechanism from [W3][w3] |
| **Size** | S |
| **Why here** | Closes **C6**, the highest-leverage gap — one mechanism raises §5, §7, §8, §9 and §11 together. Purely additive, no Processor need. |
| **Depends on** | 0 (the volatile contract assumes `enqueue` never writes the sidecar) |
| **Unblocks** | 4 (the `interaction.screen` deletion), 6, 8, 11, 12, 13 |
| **Acceptance** | A rotation mid-batch: events before and after carry different `device.orientation`. A sheet dismissal restores the presenter's `screen.name`. A replayed `NativeCrash` carries the crash-time `screen.name` / `app.state`, not the reporting launch's. The tranche-0 spy still asserts zero sidecar writes from `enqueue`. |
| **Backend / RN delta** | Processor: four new keys; `screen.name` now rides **every** event and metric and must not be read as a `screen.duration` signal; it is class `content`. Catalogue gains the `scope` column (`context` / `rider` / `event`). RN: none — bridge `trackScreen` calls become box writers automatically. |

Overlap: `interaction.screen` and `screen.name` both ship on UIKit taps until tranche 4 deletes the
former. That overlap is the migration path.

### Tranche 4 — Breaking batch

**Epic: F29 ([#216](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/216))**

Scope rule: **names, not values** ([§4](#4-rules-fixed-by-this-ranking)). Ships as one
`1.0.0-alpha.N` with `docs/migration/1.0.0-alpha.2-to-alpha.N.md` copied from
`docs/migration/TEMPLATE.md`; **wire format impact: yes**; rollout **Processor first**.

| change | old → new | source |
|---|---|---|
| **Event-name split** | `app.crash` → `app.error` (sampled, no flush) / `app.crash` (forced, flushes) / `app.hang` (sampled, no flush). `Sampler.forcedEmitAllowlist` and the `Recorder.swift:350` flush condition follow. | [W11][w11] |
| Allowlist | 12 → **13**: −`screen.duration` (dead, D1), +`app.error`, +`app.hang` | [W11][w11], [W13][w13] |
| Rename | `navigation.name` → `navigation.screen`, + `navigation.kind = manual` (D3) | [W13][w13] |
| Rename | `interaction.target_id` → `interaction.name`; `interaction.name_source` gains **`host`** for `.edgeRumTrackTap` (D4/D11) | [W13][w13], [§10](#10-conflicts-resolved-by-this-spec) row 2 |
| Rename | `network.is_expensive` / `network.is_constrained` → `network.expensive` / `network.constrained` on `network_change` (D8) | [W13][w13] |
| Rename | `error.type` → `error.class` | [W11][w11] |
| Rename | on `app.hang` only: `crash.timestamp` → `hang.timestamp`, `crash.thread.main_stack` → `hang.stack` | [§10](#10-conflicts-resolved-by-this-spec) row 11 |
| Delete | `cause`, `crash.fatal`, `navigation.type`, `page_load.cold_start`, `interaction.screen`, `http.url`, `resource.url` | [W11][w11] [W13][w13] [W9][w9] [W17][w17] [W7][w7] |
| Reshape | free-text `http.error` deleted → `http.error_domain` (string) + `http.error_code` (int) | [W7][w7], [§10](#10-conflicts-resolved-by-this-spec) row 12 |
| Metric funnel | `EdgeRum.time(name)` emits `metricName = custom_timer` + `timer.name` (`content`); `recordPerformance` gains a 6-name allowlist: `resource_timing`, `long_task`, `frame_render_time`, `memory_usage`, `cpu_usage`, `custom_timer`; #146's duplicated `value` stripped from `attributes` | [W16][w16] |
| Frame format | `hang.stack`, `long_task.stack`, `error.stack` frames become `image +0x<offset> <hint>`; sibling `<prefix>.binary_images` JSON string of referenced `{name, uuid}`; C10 markers `crash.binary_images.dropped`, `crash.registers.dropped`; fallback drops unreferenced images first | [W20][w20] |
| Session semantics | `session.finalized` emitted **only on rotation** (resign / terminate / `stop()` flush directly); gains `session.end_time`; `session.rotation ∈ {idle, max_duration}`; 4 h cap in `SessionManager.touch()`; dead `rotate()` deleted | [W18][w18] |
| Config | delete `resolveLocation`, `locationProviderUrl` (dead). Migration: *set `config.location` yourself.* | [W7][w7] |
| Namespaces | host keys under an SDK prefix (`app.` `device.` `network.` `session.` `user.` `sdk.` `navigation.` `interaction.` `http.` `resource.` `crash.` `error.` `hang.` `action.` `trace.` `span.` `rum.` `screen.` …) dropped at the public entry, counted, logged under `debug` | [W13][w13] |

| | |
|---|---|
| **Sources** | [W13 — rename batch][w13] + [W7][w7] / [W9][w9] / [W11][w11] / [W16][w16] / [W17][w17] / [W18][w18] / [W20][w20] |
| **Size** | M |
| **Why here** | Stops `captureError` force-flushing unboundedly — today every handled error bypasses the sampler and forces a network flush on the caller's thread. One Processor rollout, one migration note, one break for consumers rather than a drip. |
| **Depends on** | 3 — **soft, one line**: the `interaction.screen` delete needs `screen.name` to exist. If 4 ships first, that one deletion moves to the next breaking batch. |
| **Unblocks** | 8, 12 |
| **Acceptance** | `Tests/Fixtures/golden-batch-ios.json` regenerated and reviewed; `WireAssertions` updated (13 allowlisted names; `cause` absent); a `captureError` call neither bypasses the sampler nor flushes; a host `track` with a `device.` key is dropped; migration note covers every row above plus tranche 1–3 additions in the same release; CLAUDE.md event table and Configuration.md forced-emit list amended. |
| **Backend / RN delta** | **Handed over when tranche 0 starts.** Processor: switch on `user.interaction`; promote `type: metric`; route errors on event name; accept `app.error` / `app.hang` (unknown event names are dropped, hence Processor first); accept every rename and deletion above. RN: config mapping drops the two location knobs; bridge must not forward keys under SDK prefixes; host timer names move to `timer.name`. |

### Tranche 5 — Sampler cut

**Epic: F30 ([#217](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/217))**

| | |
|---|---|
| **Scope** | (a) `FrameSampler` runs only in **motion windows** — armed by touch begin/end (existing `UIWindow.sendEvent` swizzle) and screen transitions, closing ~2 s after the last, hard cap 10 s; **one `frame_render_time` per window** with `frame.window_ms`. (b) Memory timer carries the **last observed** pressure, never a hard-coded `normal`; cadence 10 s → 30 s. (c) `cpu_usage` metric (`cpu.percent`, whole-process, per-core, may exceed 100) on the memory tick, reusing tranche 1's reader. (d) **One gate:** app active ∧ ¬low power ∧ thermal < `serious`, consulted by the three periodic costs; pressure events, hangs, crashes and `long_task` exempt. |
| **Sources** | [W12 — sampling policy][w12] |
| **Size** | M |
| **Why here** | ~3,960 → ~350–550 periodic events per foreground hour, plus the display-link battery drain. Cuts volume **before** tranches 6 and 7 add it. |
| **Depends on** | — (if tranche 1 has not shipped, the CPU reader is built here instead) |
| **Unblocks** | volume-budget numbers |
| **Acceptance** | Instruments: on ProMotion hardware the panel is not pinned at max refresh on static content. Foreground-hour periodic volume within the estimate. A sustained pressure warning is reported as such on every subsequent sample. Gate closed ⇒ no periodic samples. |
| **Backend / RN delta** | Processor: `cpu_usage` per-name unit (percent); `frame_render_time` now describes a window, not a 1 s slice — normalise by `frame.window_ms`; gate-closed periods are absent by design, disambiguated by `device.low_power_mode` / `device.thermal_state`. RN: none. |

### Tranche 6 — Breadcrumbs

**Epic: F31 ([#218](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/218))**

| | |
|---|---|
| **Scope** | A 100-row in-memory ring fed **above the sampler** by every recorded **event** (never a metric) whose name is not forced-emit. Row projection `{t, n, l, s}` — `l` the only PII-bearing field (≤128 B, class `content`). Durability: whole-ring snapshot coalesced at most once per 1 s onto W3's volatile contract widened to a **latest-wins ring**, in its own `Library/Caches/edge-rum/breadcrumbs.json` carrying its own `session.id` and a monotonic sequence counter. Wire: `breadcrumbs` (JSON-string array of objects) + `breadcrumb.dropped`. Attaches to `app.crash` (prior session's ring from file, deleted after replay, `session.id`-matched) and to live `app.hang` / `app.error` (in-memory ring, **at most once per session**). Ring cleared on rotation. Four constants, none configurable; one `captureBreadcrumbs` on/off flag in the existing `capture*` family. |
| **Sources** | [W6 — breadcrumb model][w6] |
| **Size** | M |
| **Why here** | At `sampleRate = 0.1`, nine in ten crashes arrive today as a stack with no user journey — `app.crash` is forced-emit, everything around it is not. The ring is a sampling **bypass**, not a volume saver. Crash triage is the dashboard's core use. |
| **Depends on** | 0, 3 (consumes the volatile writer). Soft on 4: before the split, attach to `app.crash` of all three causes; before the renames, the projection keeps W6's `??` fallback chains. |
| **Unblocks** | — |
| **Acceptance** | A crash in a session with `sampleRate = 0` replays with the prior session's ring. A `session.id` mismatch drops the trail and counts it in `breadcrumb.dropped`. A retry-looping `captureError` attaches the ring once. An idle or backgrounded app writes nothing. |
| **Backend / RN delta** | Processor: parse one JSON-string attribute; `l` is `content`. RN: expose `captureBreadcrumbs`. |

Stated ceiling: **mmap ring rejected for now** — durable per crumb at near-zero cost, but needs
fixed-width slots. If the 1 s coalescing window measurably costs diagnostics, it is a swap behind
the same interface.

### Tranche 7 — SDK health

**Epic: F32 ([#219](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/219))**

| | |
|---|---|
| **Scope** | Cumulative counters (totals since scope start, **never deltas**) on the **batch envelope**, once per upload, sampled sessions only. Session-scoped: `sdk.events_generated`, `sdk.events_dropped.sampled`, `sdk.events_dropped.unknown_name`, `sdk.start_duration_ms` (+ `sdk.thread_time_ms` from tranche 0). Process-scoped: `sdk.events_uploaded`, `sdk.batches_uploaded`, `sdk.upload_failures`, `sdk.events_dropped.{queue_overflow, encode_failure, non_retryable, enqueue_failure}`, high-water marks `sdk.queue_depth_max`, `sdk.storage_bytes_max` (needs a size walk the queue does not do today). Capability: `sdk.capabilities_failed` — comma-joined `interaction_swizzle, http_swizzle, crash_reporter, hang_observer, offline_queue, keychain` (the last is `deviceIdFromFallback`, plus its promised `debug` log line). Cap `Recorder._buffer`. |
| **Sources** | [W8 — SDK self-monitoring][w8], [W22][w22] row 6 |
| **Size** | M |
| **Why here** | Operator value, and it gives every later tranche a measured acceptance and the volume budget its first real numbers. Ranked after 5 so it measures the post-cut pipeline. |
| **Depends on** | 0 (counters count events through the pipeline O1 rewrites) |
| **Unblocks** | volume budget; tranche 9's two `sdk.start_*` fields |
| **Acceptance** | Counters monotonic and correct when nine in ten envelopes are dropped. `queue_overflow` counts events, not files. A forced swizzle failure surfaces in `sdk.capabilities_failed`. `_buffer` bounded by a design constant. No runtime API exposes any counter. |
| **Backend / RN delta** | Processor: envelope gains counter fields; take the **max per scope**, never sum; process-scoped counters reset on process death; markers omitted when zero. RN: none (wire-only by ruling). |

### Tranche 8 — Error evidence + two-phase hang

**Epic: F33 ([#220](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/220))**

| | |
|---|---|
| **Scope** | (a) `captureError(_:type:context:)` — defaulted, source-compatible — emitting host-supplied free-string `error_type` (byte-capped). (b) `crash.mach_exception` flattened from the dict at `CrashReportEncoder.swift:165-171`. (c) Previous-session evidence written at lifecycle transitions and read into the next `session.started`: `previous_session.id`, `.end` (`clean \| crash \| unknown`), `.app_state` (`foreground \| background`), `.app_version`, `.os_version`, and `device.boot_time` (one `sysctl KERN_BOOTTIME`). (d) **Two-phase hang:** persist a pending-hang record at threshold, emit one `app.hang` at stall end with the **real** `hang.duration_ms`; if the process dies, replay next launch with `hang.terminated = true` on the previous session's identity. (e) **Disjoint rungs:** drop `long_task` when `enableHangDetection && duration ≥ hangTimeout`. (f) `frame.dropped_count` **observed** per display-link callback over the live refresh interval; omitted on an empty window. |
| **Sources** | [W11 — error taxonomy][w11], [W19 — frame and hang vocabulary][w19] |
| **Size** | M |
| **Why here** | Modest value for medium work: today's hang durations are wrong (≈ `hangTimeout` for every stall) but bounded; OOM becomes a backend query rather than a guess. |
| **Depends on** | 0, 3 (riders on error events; sidecar replay source), 4 (`app.error` / `app.hang` exist) |
| **Unblocks** | backend OOM inference |
| **Acceptance** | 6 s simulated stall ⇒ exactly one `app.hang` (`hang.duration_ms` ≈ 6000) and zero `long_task`. Killed mid-stall ⇒ replayed `app.hang` with `hang.terminated = true` and the previous `session.id`. `session.started` after a clean exit carries `previous_session.end = clean`. Empty frame window ⇒ no `frame.dropped_count`. |
| **Backend / RN delta** | Processor: join `previous_session.end = unknown` against `memory_usage` for OOM — **`unknown` never means `oom`**; read crash precedence **exception wins**; suggested classification bands (frames slow > 2× budget, frozen > 700 ms; hangs 2–5 s / 5–10 s / > 10 s / terminated) are Processor defaults, not SDK behaviour; `hang.duration_ms` and `frame.dropped_count` change meaning under the same name and unit. RN: expose `type` on the bridge's `captureError`. |

### Tranche 9 — Launch

**Epic: F34 ([#221](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/221))**

| | |
|---|---|
| **Scope** | (a) `launch.pre_sdk_duration_ms` on `page_load` = `p_starttime` → `launchStart`; **absent when prewarmed**. (b) `touchLaunchStart()` moves to the true first line of `start()` (step 10 of 24 today), making three doc comments true and the `let`/`var` mismatch fixed. (c) `sdk.start_duration_ms` + `sdk.start_replayed_crash` (bool) on the envelope. (d) The `max(0, …)` clamp at `PageLoadCapture.swift:299-304` removed with a monotonic clock domain — a duration that cannot be read is **omitted**, never `0`. |
| **Sources** | [W9 — launch performance model][w9] |
| **Size** | S |
| **Why here** | Cheap and narrow; C4 is already documented as a caveat, so the marginal value is a number instead of a caveat. `page_load` staying sampled is correct (a duration is a distribution) and is not priced as a gap. |
| **Depends on** | 7 — **soft, two fields**: `sdk.start_*` ride the tranche-7 envelope; if 9 ships first, (a), (b), (d) ship alone and (c) lands with 7. |
| **Unblocks** | — |
| **Acceptance** | Prewarmed launch omits `launch.pre_sdk_duration_ms`. `pre_sdk_duration_ms + page_load.duration_ms` equals process-start → first frame (the TTFF identity the catalogue states). A backwards clock jump omits the duration. |
| **Backend / RN delta** | Processor: one new attribute; TTFF is the sum, no third duration; `page_load.duration_ms` shifts by the few ms the anchor moved. Envelope fields as tranche 7. RN: none. |

Roadmap finding carried, not scheduled: **the crash-replay launch flush** is the SDK's largest launch
contribution and is an I/O, not a duration. Deferral candidate; no tranche owns it yet.

### Tranche 10 — Radio generation

**Epic: F35 ([#222](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/222))**

| | |
|---|---|
| **Scope** | When `NWPath` is cellular, read `CTTelephonyNetworkInfo().serviceCurrentRadioAccessTechnology?[dataServiceIdentifier]` and map: GPRS / Edge / CDMA1x → `2g`; WCDMA / HSDPA / HSUPA / CDMAEVDORev0/A/B / eHRPD → `3g`; LTE → `4g`; NRNSA / NR → `5g`; anything else or nil → `unknown`, **never `cellular`**. Refresh on `CTServiceRadioAccessTechnologyDidChangeNotification` through `refreshNetworkContext`; a radio-only change re-emits `network_change` via the existing dedupe fingerprint. Value set: `2g \| 3g \| 4g \| 5g \| wifi \| wired \| unknown`. Scope stays **context**. |
| **Sources** | [W21 — connectivity values][w21] |
| **Size** | S |
| **Why here** | Cheap; value only for cellular sessions. Fixes C1 (the key can never produce its declared enum today). |
| **Depends on** | — |
| **Unblocks** | — |
| **Acceptance** | Mapping table unit-tested including nil → `unknown`. `cellular` never appears. A handover with no `NWPath` change re-emits `network_change`. Links `CoreTelephony`; no privacy-manifest entry. |
| **Backend / RN delta** | Processor: iOS reports the **radio**, not web's throughput estimate — `4g` on iOS means "LTE radio", not "fast"; do not pool with web's distribution. `cellular` leaves the value set; `wired` joins it. RN: none. |

### Tranche 11 — Distributed tracing

**Epic: F24 ([#169][e169])**

| | |
|---|---|
| **Scope** | Exactly [`distributed-trace-v3-ios.md`](distributed-trace-v3-ios.md) as amended in [§9](#9-amendment-to-distributed-trace-v3-ios). The [epic][e169]'s seventeen tasks, closed `NOT_PLANNED` on 2026-09-18, are **reopened** for this tranche. |
| **Sources** | trace v3 spec, ADR-015, [trace v3 map][m153] |
| **Size** | L |
| **Why here** | Spec and ADR merged, tasks written, Processor already serves it ([trace v3 backend delta][i168]), and API monitoring is the product's headline. **At 11, not 1**, so nothing queues behind seventeen tasks. |
| **Depends on** | 0, 3 (the amended §12.1 mint publishes through tranche 3's volatile writer) |
| **Unblocks** | the deferred D13 `resource.*` deletion ([§4](#4-rules-fixed-by-this-ranking)) |
| **Acceptance** | Per the epic's tasks and the spec's §14, plus: a root mint performs no synchronous sidecar write. |
| **Backend / RN delta** | Already documented in [trace v3 backend delta][i168]. Nothing new. |

### Tranche 12 — Action lifecycle

**Epic: F36 ([#223](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/223))**

| | |
|---|---|
| **Scope** | `let a = EdgeRum.startAction("checkout")` → `a.complete()` / `a.fail(reason:)`, with `RumTimer`'s `settled`-lock idempotency copied verbatim. Two events: `action.started` (survives process death) and `action.ended` carrying `action.outcome = completed \| failed \| abandoned`. `startAction` mints its own **`action.id`** — not trace v3's `rum.action.id` — and the top of an **ordered stack** rides every event as a rider through tranche 3's box; `action.parent_id` reconstructs nesting (droppable if the tranche needs trimming). `abandoned` fires at **three deterministic points only**: session rotation with the action open (`action.abandon_reason = rotation`), next-launch reconstruction (`action.abandon_reason = process_death`), and a ~10 min leak-guard ceiling (`timeout`). Backgrounding is recorded (`action.background_count`, `action.background_duration_ms`), never judged; screen exit is not a trigger. Per-session cap on distinct `action.name`, overflow to `_other`, counted as `action.name.dropped`. `action.error_message` is `content`. Actions follow session sampling. Allowlist 13 → **15**. |
| **Sources** | [W5 — action lifecycle][w5] |
| **Size** | L |
| **Why here** | Same size as tracing but needs a new Processor delta and fresh ticketing. Raw material for Apdex / Experience Score, which are analytics-layer. |
| **Depends on** | 0, 3 (rider box, volatile persistence of open actions), 4 (rotation semantics from W18) |
| **Unblocks** | Apdex / Experience Score in the analytics layer |
| **Acceptance** | An OTP-style background hop ends `completed` with `background_count = 1`. Out-of-order completion removes by identity and the rider falls back. A process killed mid-action yields `abandoned` / `process_death` next launch. The name cap emits `action.name.dropped`. |
| **Backend / RN delta** | Processor: **two new allowlisted event names** — unknown names are dropped, so the delta must be filed before this tranche ships; `action.id` vs `rum.action.id` are different ids with different lifetimes; Apdex is computed downstream from duration + outcome. RN: a handle-shaped API across the bridge (id mapping). |

### Tranche 13 — Host-gated readiness

**Epic: F37 ([#224](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/224))**

| | |
|---|---|
| **Scope** | (a) `EdgeRum.markScreenReady()` — **no name parameter**; each appear stores a pending token beside tranche 3's box; first mark wins; late or stale marks are no-ops. Wire: `metric`, `metricName = screen_ready`, ms from the appear moment, `screen.name` rider. A per-process learned set of marked screens emits the same row with `screen.ready_outcome = abandoned` and a censored time-to-leave when a marked screen disappears pending. (b) `EdgeRum.markInteractive()` — once per process, first call wins; wire: `metric`, `metricName = launch_interactive`, ms from `launchStart` ([§10](#10-conflicts-resolved-by-this-spec) row 13). (c) Metric allowlist 6 → 8. Keeps the `viewWillDisappear` swizzle alive after `screen.duration` is gone. |
| **Sources** | [W23 — screen readiness][w23], [W9][w9] |
| **Size** | S |
| **Why here** | Zero value until a host adopts it. **Pull forward on demand** — the rank prices adoption, not engineering. |
| **Depends on** | 3 |
| **Unblocks** | — |
| **Acceptance** | A mark after navigation has moved on is a no-op. A marked screen left before ready emits `screen.ready_outcome = abandoned`. A second `markInteractive()` is a no-op. Hole on record: the first appear of a screen in each process, before its first mark, is not judged. |
| **Backend / RN delta** | Processor: two new metric names (unit ms, unpromoted, in the bag); censored `abandoned` rows must not be averaged with ready rows. RN: expose both methods. |

---

## 4. Rules fixed by this ranking

From [W14 — rank the tranches][w14]. Normative.

| rule | statement |
|---|---|
| **Breaking-batch scope = names, not values** | Deleted keys, renamed keys, renamed or split event names, and unit changes ship in tranche 4. A **value correction** — same name, same unit, the value becomes true (W12 frame windows and pressure, W19 hang duration / `long_task` cap / `frame.dropped_count`, W9 anchor and clamp) — ships with its feature tranche plus one release-note line. |
| **Processor delta lead time** | The tranche-4 Processor delta is **handed over when tranche 0 starts**, not when tranche 4 starts. The backend gets the lead time; SDK work never idles on it. |
| **D13 deferred** | `resource_timing`'s restated `resource.host`, `resource.redirect_count`, `resource.protocol` stay on the wire after tranche 11 gives it a `span.id` join key. Their deletion is a deferred item for the **next** breaking batch after tracing — redundancy, not a defect, and not worth a second breaking release. (`resource.url` goes in tranche 4 on privacy grounds.) |
| **Symbolication is unranked** | The upload tooling and symbol store are a backend-dependent epic, listed in [§5](#5-unranked-symbolication-pipeline) but not ranked; the SDK half is entirely inside tranche 4. |
| **Sampled `page_load` is not a gap** | Launch duration is a distribution; a 10% sample of it is fine. Not priced. |
| **Units frozen with names** | `resource_timing` / `long_task` / `frame_render_time` / `custom_timer` / `screen_ready` / `launch_interactive` = ms; `memory_usage` = MB; `cpu_usage` = percent. Changing a unit means a new name. ([W16][w16]) |
| **Forward-only style** | New event names are dotted; new attribute keys are snake_case. Legacy spellings (`page_load`, `custom_event`, `app_lifecycle`, `network_change`, D10's camelCase keys, `device.os`) are frozen and marked `legacy-spelled` in the catalogue. Rename only to fix iOS's own incoherence, never to match the Processor. ([W13][w13]) |

---

## 5. Unranked: symbolication pipeline

Backend-dependent epic, **listed, not ranked**. Upload does nothing until a store exists.

| | |
|---|---|
| **Scope** | dSYM upload tooling (host build-phase or CI script, keyed by Mach-O UUID via `dwarfdump --uuid`) and a symbol store. Host adoption required. |
| **Source** | [W20 — symbolication pipeline][w20] |
| **Size** | L, backend-dependent |
| **SDK half** | Entirely inside tranche 4: image-relative frames, `<prefix>.binary_images`, C10 markers, referenced-first fallback. Has value alone — it is what makes the pipeline *possible* for hangs, long tasks and errors. |
| **Backend hand-off** | Lookup `(uuid, image-relative offset)` → `function, file:line`; for `NativeCrash`, offset = address − `base_address` from `crash.report_json`. Retention keyed by UUID, at least as long as the oldest app version still emitting. A missing dSYM degrades to the on-device hint, never an error. **Recommend ingest-time** symbolication — grouping and fingerprinting need symbols. |
| **Moot** | Bitcode — deprecated since Xcode 14; on Xcode 16+ dSYMs exist at archive time. |

---

## 6. Volume and retention budget

**Status: still open.** Carried verbatim in substance from the map's *Not yet specified* section.
No acceptable per-session number exists yet; this section prices what each tranche does to the
budget and names where the first real numbers come from.

### 6.1 Line items

| tranche | line item | shape | magnitude |
|---|---|---|---|
| 0 | sidecar write | **I/O removed** | every event → 3–5 per session + 1 per ACKed batch |
| 1 | un-armed `flushInterval` | **loss removed** | up to 29 events per quiet session at process death |
| 1 | queue cap counts events | **retention tightened** | offline ceiling ~6,000 → 200 events |
| 2 | identity keys off sidecar | disk surface | −3 keys per sidecar write |
| 3 | `device.orientation`, `app.state` | **unbounded per event** (first) | two short enums on every event |
| 3 | `screen.name` | **unbounded per event** (second, larger) | ~15–60 B typical, ≤128 B, every event and metric |
| 3 | `device.family` | per batch | one key per batch (context) |
| 4 | `http.url`, `resource.url` deleted | per request | −2 content-class URLs per HTTP request |
| 4 | `<prefix>.binary_images` | per stack signal | UUID paid once per image, not per frame |
| 4 | hangs and handled errors stop forcing flushes | flush count | one fewer network call per error / hang |
| 5 | sampler cut | **volume cut** | ~3,960 → ~350–550 periodic events per foreground hour, with `cpu_usage` included; pressure-aware gate |
| 6 | breadcrumb ring | bounded | ~10 KB rewritten ≤ 1/s while crumbs arrive, nothing when idle; ~10 KB attribute per crash, ≤1 per session on live errors |
| 7 | health counters | per upload | envelope fields, sampled sessions only; zero new events |
| 8 | previous-session evidence | per session | a few lifecycle writes; six keys on `session.started` |
| 9 | launch attributes | per launch | two attributes on once-per-launch events; one `sysctl` already paid by trace v3 |
| 10 | radio handover | per handover | one `network_change`, same order as today's path transitions |
| 11 | D13 deferral | per request | −4 keys per HTTP request when the deferred deletion ships |
| 12 | actions | per action + per event | two events per action; `action.id` rider on every event while one is open |
| 13 | readiness metrics | per screen appear (adopting hosts) | one metric per marked screen appear |

### 6.2 What the fog established

- **The first real numbers** come from tranche 0's before/after `sdk.thread_time_ms` measurement,
  then tranche 7's `sdk.events_generated`, `sdk.events_dropped.*`, `sdk.queue_depth_max` and
  `sdk.storage_bytes_max`. Tranche 0's measurement should also carry tranche 3's per-event riders and
  tranche 5's frame-window estimate (a guess at gesture rate).
- **The loss side is far larger than first counted:** 101 drop sites, ~94 undocumented, against
  C15's seven ([W8][w8]).
- **Per-session cost is the wrong unit for statistical signals** ([W9][w9]): `page_load` reaching
  10% of launches is fine, where crash context nine-tenths absent is not ([W6][w6]).
- **Per event vs per batch** ([W10][w10]): context keys cost once per batch; riders cost once per
  event. The catalogue's `scope` column is that distinction; the budget still has no number for it.
- **Riders are the first cost that grows as other tranches succeed** — breadcrumbs, actions and SDK
  health all raise event volume, and every event pays the riders.
- **Cost is device-state-aware** after tranche 5: the gate silences all periodic sampling on low
  power or `serious` thermal state.
- **Retention is a second axis** ([W7][w7]): `content` is the largest class and carries a
  shortest-retention obligation; `identity` follows the host's policy; `pseudonymous` is deleted on
  erasure. Cost is no longer one number per session.
- **A launch cost no budget can see:** the crash-replay flush is an I/O during launch, not volume
  ([§3 tranche 9](#tranche-9--launch)).

---

## 7. Registry of absences

Declined signals, each with its reason. "Never collected" rows are defended by
`PrivacyContractTests` greps (tranche 2); the rest are rulings recorded so they are not
rediscovered as gaps.

| signal | ruling | reason | ticket |
|---|---|---|---|
| IDFA / `ASIdentifierManager`, ATT prompt | never collected | ATT-neutral SDK; `device.id` is SDK-owned | [W7][w7] |
| IDFV / `identifierForVendor` | never collected | a persistent vendor identifier the SDK does not need | [W7][w7] |
| IMEI, serial number, MAC address | never collected | hardware identifiers | [W7][w7] |
| Keychain contents (other than the SDK's own `device.id` item) | never collected | — | [W7][w7] |
| Request / response headers, cookies, bodies | never collected, **at any configuration** | "we cannot capture it" beats "we default to not capturing it"; no allowlist, denylist or closure | [W7][w7] |
| IP geolocation (`resolveLocation`) | config deleted (tranche 4) | dead config — no IP ever reached the third party; the promise is retracted | [W7][w7] |
| Carrier name | not collected | `CTCarrier` deprecated iOS 16; returns `"--"` from 16.4 | [W10][w10] |
| Hardware `UIDevice.orientation` | not collected | describes the device (`faceUp`), not what is on screen | [W10][w10] |
| `ui.*` namespace | deliberately unclaimed | `ui.interaction` is the Processor's live mis-switch; a real `ui.*` would make that bug ambiguous | [W10][w10] |
| Memory as context | not collected | a second, staler number beside `MemorySampler`; no change notification to make it a rider | [W10][w10] |
| Pre-main time | declined | only reachable by running SDK code during dyld — measuring launch by slowing it | [W9][w9] |
| TTFF as its own attribute | declined | equals `launch.pre_sdk_duration_ms + page_load.duration_ms`; the catalogue states the identity | [W9][w9] |
| `launch.type` | declined | `page_load` is per-process one-shot, so the key would be constant `cold` | [W9][w9] |
| Warm launch | declined | indistinguishable from cold inside the process | [W9][w9] |
| Resume latency | declined | renders in a frame or two; the slow part is the request burst, modelled better as a trace root | [W9][w9] |
| TTI idle heuristic | declined | a quiet main thread is equally true of a spinner; host marks it (tranche 13) | [W9][w9] |
| `render_complete` (host-free) | declined | ≈ one vsync after appear on every screen — a constant | [W23][w23] |
| OOM verdict | declined | force-quit is indistinguishable from foreground OOM; the SDK ships evidence, the backend infers | [W11][w11] |
| `crash.kind` | declined | derivable from key presence; precedence is a catalogue rule (exception wins) | [W11][w11] |
| SDK-classified `error_type` enum | declined | the SDK cannot classify a host's `Error`; host-supplied free string instead | [W11][w11] |
| `network_error` / `timeout` / `server_error` as error events | declined | already `http.request` + `http.error_*`; duplication double-counts | [W11][w11] |
| SDK-attributed CPU (`sdk_cpu_usage`) | declined | not honestly separable on iOS; replaced by `sdk.thread_time_ms` | [W8][w8] |
| `sdk_memory_usage` | declined | bound structures by design constants instead (cap `_buffer`) | [W8][w8] |
| `events_queued` | declined | derivable | [W8][w8] |
| Periodic `sdk.health` event | declined | volume measuring volume; blind when the queue is full | [W8][w8] |
| Runtime health API / overhead receipt | declined | the per-app number cannot be defended | [W8][w8] |
| Session rollup counters (`crash_count`, `error_count`, `screen_count`, `action_count`) | analytics-layer | `session.finalized` is absent for crashed and never-resumed sessions | [W18][w18] |
| `session.duration`, per-event ordinal | declined | derived from `session.end_time`; gaps come from `sdk.events_generated` | [W18][w18] |
| Slow / frozen frame labels, hang tiers on device | analytics-layer | thresholds in a binary freeze per release; only `hang.terminated` is asserted | [W19][w19] |
| Offline duration | declined | backend pairs lost→restored by `device.id`; a persisted "offline since" would overstate | [W21][w21] |
| Speculative abandonment (backgrounding, screen exit) | declined | false positives corrupt the completion rate | [W5][w5] |
| Auto-promotion of taps to actions | declined | the checklist's own rule; taps answer *what was touched* | [W5][w5] |
| On-device Apdex / Experience Score | out of scope | pushes a business threshold into a shipped binary | [map][m188] |
| `value.unit` attribute | declined | restates what the name already fixes | [W16][w16] |
| NavigationStack / sheet introspection | declined | fragile across iOS releases; hosting-root name is the floor | [W17][w17] |
| Breadcrumb privacy kill-switch | declined | `l` inherits classes from its sources; `captureBreadcrumbs` is the off switch | [W7][w7] |
| mmap breadcrumb ring | deferred, upgrade path named | needs fixed-width slots | [W6][w6] |

---

## 8. Residual gaps

Checklist items that **no ticket ruled on** and that no tranche closes. Listed so the
classification is honest; each is a candidate for a future epic, not part of this roadmap.

| area | gap | note |
|---|---|---|
| §1 | install / first-launch markers (`app.first_launch`, `app.previous_version`) | partly answered by tranche 8's `previous_session.app_version` on `session.started` |
| §1 / §7 | memory or CPU denominator (`physicalMemory`, `processorCount`) | "percent of available memory" is still uncomputable |
| §10 | automatic error capture (beyond host `captureError`) | no ticket |
| §12 | global-attributes API | no ticket |

---

## 9. Amendment to `distributed-trace-v3-ios`

Owed by [W3 — O1][w3], landing here so the amended paragraph and the tranche that implements it
cannot disagree. **Trace v3's decisions are untouched**; only two claims that O1 makes false change.
Where `distributed-trace-v3-ios.md` and this section disagree, this section wins.

**§12.1, "Cross-process survival — zero new I/O" — replaced.** The paragraph claiming the
annotation rides an existing per-event sidecar write is withdrawn: tranche 0 deletes that write.
Normative replacement:

- Mint stores the root into a **latest-wins atomic box** and schedules a flush **only if none is
  already pending**. A burst of N mints collapses to one or two writes, with no timer and no
  background wakeup while idle.
- A **serial queue** merges the box into the sidecar's volatile zone under the write lock tranche 0
  adds. This is tranche 3's writer; tracing is a consumer, not its builder.
- Cost stays off the pre-dispatch tap path §4.2 protects — mint still does only a lock and two id
  generations before `sendEvent` dispatches.
- Price: the volatile zone is **best-effort**. A crash inside the drain window lands unannotated,
  which `CrashSidecarReader.parse`'s absent-`extras` path already models (live identity fallback).
- The hang path is unaffected — it reads `lastRoot.load()` in-process, never through the file.

§12's decision — annotate `app.crash` and the hang with `trace.id` + `rum.action.id`, no `span.id` /
`parent.span.id`, always-stamp `trace.root_expired` — stands. After tranche 4 the hang annotation
lands on `app.hang`.

**§13, row O1 — replaced.** "Not fixed (SDK code; this map merges none)" becomes: *fixed by
tranche 0 of `rum-coverage-roadmap.md`; the per-event write no longer exists.*

---

## 10. Conflicts resolved by this spec

| # | disagreement | ruling |
|---|---|---|
| 1 | Trace v3 §12.1 / §13 assume the per-event sidecar write; [W3][w3] deletes it | [§9](#9-amendment-to-distributed-trace-v3-ios) |
| 2 | `interaction.name_source` values: trace v3 / [trace v3 backend delta][i168] / [W7][w7] say `accessibility_identifier \| button_title \| none`; [W13][w13] wrote `accessibility_id \| title \| host` | Trace v3's spellings stand (already filed with the Processor; trace v3 is not reopened). [W13][w13]'s new case ships as a fourth value, **`host`**, for `.edgeRumTrackTap`, in tranche 4. `none` means no label was sent. |
| 3 | `hang.cpu_usage`: [W22][w22] put it in W12's tranche; [W14][w14] put it in doc-truth, before the reader exists | The CPU reader is built in **tranche 1** and reused by tranche 5. Unit: **per-core percent, may exceed 100** — the same unit as `cpu.percent`, so the SDK has one CPU unit. The encoder's never-true "0.0–1.0" doc comment is amended (the key has never reached the wire, so nothing breaks). |
| 4 | [W20][w20] classes `<prefix>.binary_images` as `technical`, not in [W7][w7]'s closed four-class vocabulary | Class **`none`**: image names and UUIDs are fixed at build time. The vocabulary stays four classes. |
| 5 | [W11][w11] says error correlation rides "W5's `rum.action.id`" | The action rider is **`action.id`** ([W5][w5]); `rum.action.id` is the trace-root id ([W13][w13] keeps it). |
| 6 | [W7][w7] points hosts at "W6's own `captureBreadcrumbs`"; [W6][w6] made nothing configurable | W6's four constants stay unconfigurable; one **`captureBreadcrumbs: Bool = true`** ships in tranche 6, matching the existing `capture*` family. It is a capture switch, not a privacy redaction toggle. |
| 7 | [W16][w16] folds the D13 `resource.*` deletion into the breaking batch, gated on #169; [W14][w14] defers it | Deferred to the next breaking batch after tranche 11 ([§4](#4-rules-fixed-by-this-ranking)). |
| 8 | [W7][w7] / [W13][w13] list identity-keys-off-sidecar and `button_title` default-off in the breaking batch; [W14][w14] puts them in privacy | **Tranche 2.** Neither is a name change; the key `interaction.target_id` is renamed separately in tranche 4. |
| 9 | [W9][w9] asks [W13][w13] to rename `page_load.duration_ms` to say what it excludes; W13's resolution does not | **Not renamed** — W13's rule (no rename for description alone). The catalogue documents the anchor; `launch.pre_sdk_duration_ms` makes the exclusion visible. |
| 10 | [W9][w9] sends the clamp removal to the breaking batch; [W14][w14] puts it in launch | **Tranche 9** — omitting an unreadable value is a value correction under the same name and unit. |
| 11 | [W19][w19] left `crash.timestamp` / `crash.thread.main_stack` on `app.hang` to [W13][w13], which resolved before the question was asked | Renamed on `app.hang` only to **`hang.timestamp`** (threshold-crossing time; the event's own timestamp is stall end after tranche 8) and **`hang.stack`** (aligning with `long_task.stack`, `error.stack` and [W20][w20]'s `hang.binary_images`). A `crash.*` key on a non-crash event is iOS's own incoherence, created by the split, so W13's rule permits it. Tranche 4. |
| 12 | [W7][w7] reshaped `http.error` to "domain + code, taxonomy pending W11"; [W11][w11] added no taxonomy and fixed no spelling | Free-text `http.error` is **deleted**; **`http.error_domain`** (string, class `none`) and **`http.error_code`** (int) are added. Typed, so no consumer re-parses an int out of a string ([W6][w6]'s rule). No bounded kind above them; the backend classifies. Tranche 4. |
| 13 | [W9][w9] specified `EdgeRum.markInteractive()` with no wire shape | A `metric`, **`metricName = launch_interactive`**, ms from `launchStart` — the same anchor as `page_load.duration_ms`, so `launch.pre_sdk_duration_ms + launch_interactive` is process-to-interactive. A metric because `page_load` has already left ([W23][w23]'s argument). Tranche 13. |
| 14 | [W23][w23]'s `screen_ready` is not in [W16][w16]'s 6-name metric allowlist | Tranche 13 adds `screen_ready` and `launch_interactive` → 8 names. |
| 15 | [W6][w6]'s premise "this SDK already streams everything within 5 s" | False ([W8][w8]: `flushInterval` never armed). W6's conclusion stands on the forced-emit asymmetry; the timer is fixed in tranche 1. |
| 16 | [W11][w11] persists the screen for the crash path at lifecycle transitions only | Amended by [W17][w17]: screen (and every rider) persists **on change** through the volatile contract. Previous-session evidence keeps the lifecycle-only write. |
| 17 | [W5][w5] spells its name-cap marker `action.name_capped` | `action.name.dropped`, distinct names discarded — [W8][w8]'s convention. |
| 18 | [W1][w1]'s attribute row has no `scope` column | Amended by [W10][w10]: `scope = context \| rider \| event`, and the header's flush-time clause gains a rider sentence. Catalogue content. |
| 19 | [W7][w7] names `disable()` the consent lever; it is inoperative in `1.0.0-alpha.2` | Fixed in **tranche 0**; the catalogue carries a dated correction, not a merge gate. |
| 20 | Epic [#169][e169] and its tasks are closed `NOT_PLANNED` | Reopened as tranche 11. |
| 21 | ADR-014 records *iOS conforms to the Processor of record* | Superseded for naming outside trace v3 by ADR-016 (iOS-native naming, catalogue as contract). |

---

## 11. Backend and RN delta

Every Processor and `edge_telemetry_react_native` delta this map produced is collected, by tranche,
in [Backend and RN delta for iOS RUM coverage](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/225), in the shape of [trace v3 backend delta][i168], handed to the driver to file.
**No agent writes to another repository.** The tranche-4 section is the one handed over when
tranche 0 starts. Per-tranche summaries are in each tranche's last row above.

---

## 12. Ticket map

| ticket | lands in |
|---|---|
| [W1 — catalogue schema][w1] | catalogue; [§10](#10-conflicts-resolved-by-this-spec) row 18 |
| [W2 — wire inventory][w2] | catalogue; D1–D13 cited throughout |
| [W3 — O1][w3] | tranche 0; [§9](#9-amendment-to-distributed-trace-v3-ios) |
| [W4 — classification][w4] | [§1](#1-the-16-areas) |
| [W5 — action lifecycle][w5] | tranche 12 |
| [W6 — breadcrumbs][w6] | tranche 6 |
| [W7 — PII and redaction][w7] | tranche 2; tranche 4 strips; catalogue PII section; [§7](#7-registry-of-absences) |
| [W8 — SDK self-monitoring][w8] | tranche 0 (`sdk.thread_time_ms`), tranche 7; marker convention (catalogue) |
| [W9 — launch][w9] | tranche 9; tranche 13 (`markInteractive`); tranche 4 (`cold_start`) |
| [W10 — context gaps][w10] | tranche 3 |
| [W11 — error taxonomy][w11] | tranche 4 (split); tranche 8 |
| [W12 — sampling policy][w12] | tranche 5 |
| [W13 — rename batch][w13] | tranche 4; [§4](#4-rules-fixed-by-this-ranking) |
| [W14 — ranking][w14] | [§2](#2-the-order-at-a-glance), [§3](#3-tranches), [§4](#4-rules-fixed-by-this-ranking) |
| [W15 — this spec][w15] | this document, the catalogue, ADR-016, the delta issue |
| [W16 — metric wire row][w16] | tranche 4; [§4](#4-rules-fixed-by-this-ranking) units |
| [W17 — screen attribution][w17] | tranche 3; tranche 4 (`interaction.screen`) |
| [W18 — session boundaries][w18] | tranche 4 |
| [W19 — frame and hang vocabulary][w19] | tranche 8; tranche 4 (`hang.*` renames) |
| [W20 — symbolication][w20] | tranche 4 (SDK half); [§5](#5-unranked-symbolication-pipeline) |
| [W21 — connectivity values][w21] | tranche 10 |
| [W22 — docs vs code][w22] | tranche 0 (row 5), tranche 1 (rows 1–4), tranche 7 (row 6) |
| [W23 — screen readiness][w23] | tranche 13 |

[m188]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/188
[m153]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/153
[e169]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/169
[i168]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/168
[w1]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/189
[w2]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/190
[w3]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/191
[w4]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/192
[w5]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/193
[w6]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/194
[w7]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/195
[w8]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/196
[w9]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/197
[w10]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/198
[w11]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/199
[w12]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/200
[w13]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/201
[w14]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/202
[w15]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/203
[w16]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/204
[w17]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/205
[w18]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/206
[w19]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/207
[w20]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/208
[w21]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/209
[w22]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/210
[w23]: https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/211
