# Data Flow & Schema Reference — `edge-rum-ios`

**Audience.** EdgeTelemetryProcessor / ingest team and SDK contributors.

**Purpose.** Single source of truth for what the iOS SDK will send to
`POST /collector/telemetry`, ordered both chronologically (when each
datapoint fires at runtime) and as a flat schema catalog (for storage
planning). Covers signal we capture today, signal we propose to add,
and signal we have deliberately deferred.

**Status conventions.** Every event, metric, and attribute is marked
with one of:

| Marker          | Meaning                                                                  |
|-----------------|--------------------------------------------------------------------------|
| **`v1.0`**      | Shipping in v1.0. Backend must accept and store.                         |
| **`v1.0+`**     | Additive in v1.0 — pure context-bag enrichment, no new event type.       |
| **`v1.1`**      | Proposed for v1.1. Requires backend confirmation before code lands.      |
| **`v1.2+`**     | Proposed for v1.2 or later. Requires backend confirmation and host opt-in. |
| **`deferred`**  | Available but blocked on ADR, permission grant, or scope decision.       |

Backend asks — items the processor team needs to sign off — are listed
in § 11.

Cross-references:

- `CLAUDE.md` — hard wire-format rules (envelope, identity, terminology
  firewall).
- `payload-schema.json` — machine-readable attribute catalog (kept in
  sync with this document).
- `PLAN-iOS.md` § 6 / § 8 — capture-site and identity internals.
- `decisions.md` ADR-001 — iOS 14.0 floor rationale.

---

## 1. Pipeline overview

```
┌────────────────────────────────────────────────────────────────────┐
│  Capture sites (EdgeRumCapture / EdgeRumCrash / OTel bridge)       │
│  swizzles · samplers · observers · MetricKit subscriber · sidecar  │
└──────────────────────────┬─────────────────────────────────────────┘
                           │  AttributeBag (flat, primitives only)
                           ▼
┌────────────────────────────────────────────────────────────────────┐
│  Recorder (EdgeRumCore)                                            │
│  ─ allowlist check (eventName ∈ Recorder.allowedEventNames)        │
│  ─ merge ContextProvider snapshot (app / device / network /        │
│    session / user / sdk / power / storage) — event attrs win       │
│  ─ apply Sampler (per-session)                                     │
│  ─ stamp ISO 8601 timestamp                                        │
└──────────────────────────┬─────────────────────────────────────────┘
                           │  EventEnvelope
                           ▼
┌────────────────────────────────────────────────────────────────────┐
│  BatchTransport                                                    │
│  ─ accumulate up to batchSize (30) or flushInterval (5 s)          │
│  ─ wrap in {"type":"telemetry_batch", timestamp, location,         │
│    batch_size, events:[…]}                                         │
│  ─ POST <endpoint>/collector/telemetry  (X-API-Key: edge_…)        │
│  ─ retry 0/429/503 with backoff 0 s · 2 s · 8 s · 30 s             │
│  ─ on attempt 4 failure → OfflineQueue (Library/Caches)            │
└──────────────────────────┬─────────────────────────────────────────┘
                           │
                           ▼
                EdgeTelemetryProcessor (Kafka ingest)
```

Three invariants hold for every event that reaches the wire:

1. **Identity is complete.** App, device, network, session, user, and
   SDK attributes are merged in by `ContextProvider` — capture sites
   only set event-specific keys.
2. **Attributes are flat primitives.** `String`, `Int`, `Double`, or
   `Bool`. The `AttributeValue` enum enforces this at the type level.
3. **Timestamps are ISO 8601 strings** with fractional seconds, never
   Unix milliseconds.

---

## 2. Wire format

### 2.1 Batch envelope

```jsonc
{
  "type": "telemetry_batch",
  "timestamp": "2026-06-15T08:00:00.512Z",
  "location": "Nairobi/Kenya",
  "batch_size": 4,
  "events": [ /* event or metric items */ ]
}
```

| Field        | Type            | Required | Notes                                                  |
|--------------|-----------------|----------|--------------------------------------------------------|
| `type`       | string          | yes      | Always `"telemetry_batch"`.                            |
| `timestamp`  | ISO 8601 string | yes      | Batch flush time, fractional seconds.                  |
| `location`   | string          | no       | From `EdgeRumConfig.location` or IP geo if opted in.   |
| `batch_size` | int             | yes      | Equals `events.count`.                                 |
| `events`     | array           | yes      | One or more event/metric items (§ 2.3).                |

### 2.2 Transport

| Header         | Value                                                  |
|----------------|--------------------------------------------------------|
| `X-API-Key`    | Tenant API key, must start with `edge_`.               |
| `Content-Type` | `application/json`                                     |
| `User-Agent`   | `EdgeRum-iOS/<sdk.version> (<device.model>; iOS <os>)` |

Path: `POST <endpoint>/collector/telemetry`.

### 2.3 Per-item structure

**Event item:**

```jsonc
{
  "type": "event",
  "eventName": "navigation",
  "timestamp": "2026-06-15T08:00:00.123Z",
  "attributes": { /* flat key-value, primitives only */ }
}
```

**Metric item:**

```jsonc
{
  "type": "metric",
  "metricName": "frame_render_time",
  "value": 18.4,
  "timestamp": "2026-06-15T08:00:07.000Z",
  "attributes": { /* flat key-value, primitives only */ }
}
```

| Field        | Type            | Required | Notes                                                  |
|--------------|-----------------|----------|--------------------------------------------------------|
| `type`       | string          | yes      | `"event"` or `"metric"`.                               |
| `eventName`  | string          | yes (event) | Drawn from § 4.1 allowlist.                         |
| `metricName` | string          | yes (metric) | Drawn from § 4.2 allowlist.                        |
| `value`      | number          | yes (metric) | Numeric value, units depend on `metricName`.        |
| `timestamp`  | ISO 8601 string | yes      | Capture time, fractional seconds.                      |
| `attributes` | object          | yes      | Flat, primitives only. Identity context + event-specific. |

### 2.4 ID formats

```
device.id:  "device_{epochMs}_{16 hex chars}_ios"
session.id: "session_{epochMs}_{16 hex chars}_ios"
user.id:    "user_{epochMs}_{16 hex chars}"
```

The 16 hex chars are 64 bits from `SecRandomCopyBytes`. **Not `UUID()`**
— `UUID` produces 128 hex chars and would break parity with the web /
Android SDKs. Persisted IDs that fail the format regex on launch are
regenerated transparently.

---

## 3. Identity attributes (on every event and metric)

Merged in by `ContextProvider`. The backend drops items missing the
required identity attributes.

### 3.1 App

| Key                       | Type   | Required | Status   | Source                                |
|---------------------------|--------|----------|----------|---------------------------------------|
| `app.name`                | string | yes      | v1.0     | `EdgeRumConfig.appName`               |
| `app.version`             | string | yes      | v1.0     | `EdgeRumConfig.appVersion`            |
| `app.package_name`        | string | yes      | v1.0     | `EdgeRumConfig.appPackage`            |
| `app.build_number`        | string | no       | v1.0     | `EdgeRumConfig.appBuild`              |
| `app.environment`         | string | yes      | v1.0     | `production` / `staging` / `development` |
| `app.background_refresh`  | string | no       | v1.0+    | `UIApplication.backgroundRefreshStatus` |

### 3.2 Device

| Key                          | Type   | Required | Status | Source                                 |
|------------------------------|--------|----------|--------|----------------------------------------|
| `device.id`                  | string | yes      | v1.0   | Keychain (`device_<epochMs>_<hex>_ios`)|
| `device.platform`            | string | yes      | v1.0   | Constant `"ios"`                       |
| `device.model`               | string | yes      | v1.0   | `utsname.machine` (e.g. `iPhone15,3`)  |
| `device.manufacturer`        | string | yes      | v1.0   | Constant `"Apple"`                     |
| `device.os`                  | string | yes      | v1.0   | Constant `"ios"`                       |
| `device.platform_version`    | string | yes      | v1.0   | `UIDevice.systemVersion`               |
| `device.isVirtual`           | bool   | yes      | v1.0   | Simulator detection                    |
| `device.screenWidth`         | int    | yes      | v1.0   | `UIScreen` pixel width                 |
| `device.screenHeight`        | int    | yes      | v1.0   | `UIScreen` pixel height                |
| `device.pixelRatio`          | double | yes      | v1.0   | `UIScreen.scale`                       |
| `device.batteryLevel`        | double | yes      | v1.0   | `UIDevice.batteryLevel` (0.0–1.0)      |
| `device.batteryCharging`     | bool   | yes      | v1.0   | `UIDevice.batteryState`                |
| `device.thermal_state`       | string | no       | v1.0+  | `ProcessInfo.thermalState`             |
| `device.low_power_mode`      | bool   | no       | v1.0+  | `ProcessInfo.isLowPowerModeEnabled`    |
| `device.dynamic_type`        | string | no       | v1.0+  | `preferredContentSizeCategory`         |
| `device.reduce_motion`       | bool   | no       | v1.0+  | `UIAccessibility`                      |
| `device.bold_text`           | bool   | no       | v1.0+  | `UIAccessibility`                      |
| `device.voiceover`           | bool   | no       | v1.0+  | `UIAccessibility`                      |
| `device.increase_contrast`   | bool   | no       | v1.0+  | `UIAccessibility`                      |
| `device.locale`              | string | no       | v1.0+  | `Locale.current.identifier`            |
| `device.timezone`            | string | no       | v1.0+  | `TimeZone.current.identifier`          |
| `device.timezone_offset_min` | int    | no       | v1.0+  | `TimeZone.current.secondsFromGMT()/60` |
| `device.disk_free_mb`        | int    | no       | v1.0+  | `FileManager.attributesOfFileSystem`   |
| `device.disk_total_mb`       | int    | no       | v1.0+  | `FileManager.attributesOfFileSystem`   |

`device.thermal_state` values: `nominal` · `fair` · `serious` · `critical`.
`device.dynamic_type` values: `XS` · `S` · `M` · `L` · `XL` · `XXL` ·
`XXXL` · `AX1` · `AX2` · `AX3` · `AX4` · `AX5`.

### 3.3 Network

| Key                       | Type   | Required | Status | Source                       |
|---------------------------|--------|----------|--------|------------------------------|
| `network.type`            | string | yes      | v1.0   | `NWPathMonitor`              |
| `network.effectiveType`   | string | no       | v1.0   | Best-effort (`4g`, `5g`, …)  |
| `network.expensive`       | bool   | no       | v1.0+  | `NWPath.isExpensive`         |
| `network.constrained`     | bool   | no       | v1.0+  | `NWPath.isConstrained`       |
| `network.interface`       | string | no       | v1.0+  | `NWPath.availableInterfaces` |

`network.type` values: `wifi` · `cellular` · `ethernet` · `none` ·
`unknown`.

### 3.4 Session

| Key                  | Type            | Required | Status | Source                                  |
|----------------------|-----------------|----------|--------|-----------------------------------------|
| `session.id`         | string          | yes      | v1.0   | UserDefaults (`session_<epochMs>_<hex>_ios`) |
| `session.start_time` | ISO 8601 string | yes      | v1.0   | Session creation time                   |
| `session.sequence`   | int             | yes      | v1.0   | Increments on each successful batch ACK |

### 3.5 User

| Key          | Type   | Required | Status | Source                                  |
|--------------|--------|----------|--------|-----------------------------------------|
| `user.id`    | string | yes      | v1.0   | SDK-owned (`user_<epochMs>_<hex>`)      |
| `user.name`  | string | no       | v1.0   | Set via `EdgeRum.identify()`            |
| `user.email` | string | no       | v1.0   | Set via `EdgeRum.identify()`            |
| `user.phone` | string | no       | v1.0   | Set via `EdgeRum.identify()`            |

`EdgeRum.identify()` attaches host-app identifiers as additional
attributes — it does **not** change `user.id`.

### 3.6 SDK

| Key            | Type   | Required | Status | Source                       |
|----------------|--------|----------|--------|------------------------------|
| `sdk.version`  | string | yes      | v1.0   | SDK constant                 |
| `sdk.platform` | string | yes      | v1.0   | Constant `"ios-native"` (new value vs. web / Android) |

`sdk.platform = "ios-native"` is a **new value** the backend has not
seen before — see § 11 backend asks.

---

## 4. Complete event and metric catalog

### 4.1 Events (`type = "event"`)

| `eventName`                  | Status | Capture site                                            | Purpose                                       |
|------------------------------|--------|---------------------------------------------------------|-----------------------------------------------|
| `session.started`            | v1.0   | `EdgeRum.start()` + `didBecomeActive`                   | Session begins                                |
| `session.finalized`          | v1.0   | `willResignActive` + 30-min idle rotation               | Session ends (immediate flush)                |
| `app_lifecycle`              | v1.0   | `LifecycleCapture.swift`                                | Foreground / background transitions           |
| `page_load`                  | v1.0   | `PageLoadCapture.swift` + MetricKit (v1.1)              | App launch → first frame                      |
| `navigation`                 | v1.0   | `UIViewControllerCapture.swift` + SwiftUI modifier      | Screen entry (UIKit or SwiftUI)               |
| `screen.duration`            | v1.0   | `UIViewControllerCapture.swift`                         | Screen exit with dwell time                   |
| `http.request`               | v1.0   | `HTTPCapture.swift` (URLProtocol + delegate swizzle)    | HTTP request lifecycle                        |
| `user.interaction`           | v1.0   | `InteractionCapture.swift` (`UIWindow.sendEvent`)       | Tap / control interaction                     |
| `network_change`             | v1.0   | `NetworkPathCapture.swift` (`NWPathMonitor`)            | Connectivity change                           |
| `user.profile.update`        | v1.0   | `EdgeRum.identify()`                                    | Host attaches user identifiers                |
| `custom_event`               | v1.0   | `EdgeRum.track()`                                       | Host-app custom event                         |
| `app.crash`                  | v1.0   | `EdgeRum.captureError()` + PLCrashReporter + MetricKit  | Error / native crash / hang (cause discriminator) |
| `memory_warning`             | v1.1   | `applicationDidReceiveMemoryWarning`                    | iOS asked the app to free memory              |
| `background_task`            | v1.2+  | `BGTaskScheduler` (host-opt-in)                         | Background refresh / processing task outcome  |
| `notification_interaction`   | v1.2+  | `UNUserNotificationCenter` (host-opt-in)                | Push notification open / dismiss              |

### 4.2 Metrics (`type = "metric"`)

| `metricName`            | Status | `value` units            | Capture site                                |
|-------------------------|--------|--------------------------|---------------------------------------------|
| `frame_render_time`     | v1.0   | milliseconds (mean)      | `FrameSampler.swift` (`CADisplayLink`)      |
| `memory_usage`          | v1.0   | megabytes (resident)     | `MemorySampler.swift`                       |
| `long_task`             | v1.0   | milliseconds (block)     | `RunLoopObserverCapture.swift`              |
| `resource_timing`       | v1.0   | milliseconds (total)     | `HTTPCapture.swift` (URLSessionTaskMetrics) |
| (custom)                | v1.0   | host-supplied            | `EdgeRum.time(name).end()`                  |
| `scroll_hitch_ratio`    | v1.1   | ratio (0.0–1.0)          | MetricKit `MXAnimationMetric`               |
| `system_exception`      | v1.1   | duration ms or bytes     | MetricKit `MXCPU/DiskWriteExceptionDiagnostic` |
| `energy_impact`         | v1.1   | kilowatt-hours           | MetricKit `MXEnergyMetric`                  |

### 4.3 Explicitly not emitted on iOS

`LCP`, `FCP`, `CLS`, `INP`, `TTFB`. iOS has no native analogue to Web
Vitals. Backend must tolerate iOS batches without any of these metrics.

Any `eventName` outside § 4.1 is rejected at `Recorder.recordEvent`
ingress (logged when `debug == true`). The backend may silently drop
unknown names as a second line of defence.

---

## 5. Runtime data flow

What fires when, in chronological order from process launch through
session end.

### Stage 0 — Process launch, before `EdgeRum.start()`

Nothing is captured. Any framework-level events that fire before
`start()` are not observed.

### Stage 1 — `EdgeRum.start(_:)`

Triggered explicitly by the host app. Runs synchronously, <50 ms on a
cold cache.

1. Validate config (`apiKey` non-empty, prefixed `edge_`; `endpoint`
   is `https://` unless `debug == true`).
2. Resolve identity: `device.id` (Keychain), `user.id` (UserDefaults),
   `session.id` (new session if absent or last-active > 30 min ago).
3. Snapshot context: `AppContext`, `DeviceContext`, `NetworkContext`,
   `PowerContext` (v1.0+), `StorageContext` (v1.0+).
4. Install capture (swizzles, samplers, observers, `NWPathMonitor`,
   accessibility notification subscribers).
5. Register PLCrashReporter; replay any prior-launch crash report
   (Stage 9).
6. Subscribe to MetricKit (v1.1).
7. Emit `session.started`.
8. Begin page-load timing.

**Emits.**

```jsonc
{
  "type": "event",
  "eventName": "session.started",
  "timestamp": "2026-06-15T08:00:00.124Z",
  "attributes": {
    // …full identity context (§ 3)…
    "session.trigger": "cold_start",       // "cold_start" | "warm_resume" | "rotation"
    "session.previous_id": null             // or the rotated-out session.id
  }
}
```

### Stage 2 — First screen appears

UIKit swizzle on `viewDidAppear` fires for the first
`UIViewController` (or `UIHostingController`). `PageLoadCapture` closes
its launch window.

**Emits `page_load` (v1.0 — `CADisplayLink` path).**

```jsonc
{
  "type": "event",
  "eventName": "page_load",
  "timestamp": "2026-06-15T08:00:00.482Z",
  "attributes": {
    "page_load.source": "displaylink",     // "displaylink" | "metrickit" (v1.1)
    "page_load.cold_start": true,
    "page_load.duration_ms": 358,
    "page_load.first_screen": "HomeViewController"
  }
}
```

**v1.1 MetricKit augmentation.** On the next launch after a MetricKit
delivery, an additional `page_load` may fire with
`page_load.source = "metrickit"` carrying aggregate launch data:

```jsonc
{
  "type": "event",
  "eventName": "page_load",
  "attributes": {
    "page_load.source": "metrickit",
    "page_load.cold_start": true,
    "page_load.prewarmed": false,
    "page_load.first_draw_avg_ms": 412,
    "page_load.resume_avg_ms": 89,
    "page_load.optimized_avg_ms": 124,     // iOS 16+
    "page_load.sample_count": 14
  }
}
```

**Emits `navigation`.**

```jsonc
{
  "type": "event",
  "eventName": "navigation",
  "timestamp": "2026-06-15T08:00:00.484Z",
  "attributes": {
    "navigation.screen": "HomeViewController",
    "navigation.previous_screen": null,
    "navigation.type": "viewDidAppear",
    "navigation.kind": "uikit"             // "uikit" | "swiftui"
  }
}
```

### Stage 3 — Steady-state foreground

Multiple independent capture sites fan in.

#### 3.1 Screen-to-screen navigation

Every later `viewDidAppear` emits `navigation`; each
`viewWillDisappear` pair emits `screen.duration`.

```jsonc
{
  "type": "event",
  "eventName": "screen.duration",
  "timestamp": "2026-06-15T08:00:14.700Z",
  "attributes": {
    "screen.name": "HomeViewController",
    "screen.duration_ms": 14216,
    "screen.exit_method": "viewWillDisappear"
  }
}
```

#### 3.2 Taps and interactions

`UIWindow.sendEvent` swizzle resolves touches to `UIControl` targets or
`UITableViewCell` / `UICollectionViewCell` taps.

```jsonc
{
  "type": "event",
  "eventName": "user.interaction",
  "timestamp": "2026-06-15T08:00:05.011Z",
  "attributes": {
    "interaction.kind": "tap",
    "interaction.target": "UIButton",
    "interaction.accessibility_id": "checkout_button",
    "interaction.screen": "CartViewController"
  }
}
```

The SDK never reads visible text from controls — only the accessibility
identifier.

#### 3.3 HTTP traffic

`URLProtocol` + `URLSessionTaskDelegate` swizzles. Internal SDK requests
(carrying `X-Edge-Rum-Internal: 1` and
`taskDescription = "edge-rum-internal"`) are filtered out before record.

```jsonc
{
  "type": "event",
  "eventName": "http.request",
  "timestamp": "2026-06-15T08:00:06.456Z",
  "attributes": {
    "http.url": "https://api.example.com/products",
    "http.method": "GET",
    "http.host": "api.example.com",
    "http.path": "/products",
    "http.status_code": 200,
    "http.duration_ms": 342,
    "http.request_size": 0,
    "http.response_size": 18244,
    "http.from_cache": false,
    // v1.0 URLSessionTaskMetrics enrichment:
    "http.redirect_count": 0,
    "http.tls_protocol": "1.3",            // "1.0" | "1.1" | "1.2" | "1.3"
    "http.tls_cipher": "TLS_AES_128_GCM_SHA256",
    "http.reused_connection": true,
    "http.proxy_connection": false,
    "http.network_protocol": "h2",         // "h1.1" | "h2" | "h3"
    "http.request_body_bytes_before_encoding": 0,
    "http.cellular_fallback": false        // iOS 17+
  }
}
```

`resource_timing` follows as a metric in the same correlation window:

```jsonc
{
  "type": "metric",
  "metricName": "resource_timing",
  "value": 342.0,
  "timestamp": "2026-06-15T08:00:06.798Z",
  "attributes": {
    "resource.url": "https://api.example.com/products",
    "resource.dns_ms": 11,
    "resource.connect_ms": 38,
    "resource.tls_ms": 47,
    "resource.ttfb_ms": 196,
    "resource.download_ms": 50,
    "resource.protocol": "h2",
    // v1.0 enrichment:
    "resource.redirect_count": 0,
    "resource.transaction_count": 1,
    "resource.fetch_start_to_response_end_ms": 392
  }
}
```

Hosts on `config.ignoreUrls` are skipped before any of this fires.
`config.sanitizeUrl` runs on the URL just before record.

#### 3.4 Frame rendering

`FrameSampler` runs a `CADisplayLink` callback, batching per-second
windows.

```jsonc
{
  "type": "metric",
  "metricName": "frame_render_time",
  "value": 18.4,
  "timestamp": "2026-06-15T08:00:07.000Z",
  "attributes": {
    "frame.max_ms": 33,
    "frame.p95_ms": 28,
    "frame.dropped_count": 1,
    "frame.target_hz": 60,                  // 120 on ProMotion (iOS 15+)
    "frame.source": "displaylink"
  }
}
```

#### 3.5 Memory

`MemorySampler` polls `mach_task_basic_info` and listens to
`DISPATCH_SOURCE_TYPE_MEMORYPRESSURE`. Reports every 10 s and on every
pressure transition.

```jsonc
{
  "type": "metric",
  "metricName": "memory_usage",
  "value": 84.7,
  "timestamp": "2026-06-15T08:00:10.000Z",
  "attributes": {
    "memory.resident_mb": 84.7,
    "memory.virtual_mb": 412.3,
    "memory.pressure": "normal"             // "normal" | "warn" | "critical"
  }
}
```

#### 3.6 Long tasks

`CFRunLoopObserver` measures main-thread block between
`kCFRunLoopBeforeWaiting` and `kCFRunLoopAfterWaiting`. >50 ms emits:

```jsonc
{
  "type": "metric",
  "metricName": "long_task",
  "value": 124.0,
  "timestamp": "2026-06-15T08:00:11.220Z",
  "attributes": {
    "long_task.threshold_ms": 50,
    "long_task.screen": "CartViewController"
  }
}
```

#### 3.7 Connectivity changes

`NetworkPathCapture` listens to `NWPathMonitor`. Transitions emit:

```jsonc
{
  "type": "event",
  "eventName": "network_change",
  "timestamp": "2026-06-15T08:00:13.045Z",
  "attributes": {
    "network.previous_type": "wifi",
    "network.type": "cellular",
    "network.effectiveType": "4g"
  }
}
```

A `.satisfied` transition also nudges `OfflineQueue` to drain.

#### 3.8 Host-app custom events

```jsonc
// EdgeRum.track("checkout_completed", attributes: ["cart.total_usd": .double(42.50)])
{
  "type": "event",
  "eventName": "custom_event",
  "timestamp": "2026-06-15T08:00:18.001Z",
  "attributes": {
    "event.name": "checkout_completed",
    "cart.total_usd": 42.50
  }
}

// EdgeRum.time("checkout_flow").end()
{
  "type": "metric",
  "metricName": "checkout_flow",
  "value": 9831.0,
  "timestamp": "2026-06-15T08:00:19.832Z",
  "attributes": {}
}

// EdgeRum.identify(_:)
{
  "type": "event",
  "eventName": "user.profile.update",
  "timestamp": "2026-06-15T08:00:01.510Z",
  "attributes": {
    "user.name": "Jane Doe",
    "user.email": "jane@example.com",
    "user.phone": null
  }
}
```

`user.id` does **not** change on `identify()` — host-app identifiers
travel as `user.name` / `user.email` / `user.phone`.

### Stage 4 — Errors thrown by host-app code

`EdgeRum.captureError(_:context:)` funnels into the shared `app.crash`
envelope with a `cause` discriminator.

```jsonc
{
  "type": "event",
  "eventName": "app.crash",
  "timestamp": "2026-06-15T08:00:21.118Z",
  "attributes": {
    "crash.cause": "AppError",
    "crash.runtime": "swift",
    "crash.source": "captureerror",         // v1.1 discriminator
    "crash.message": "Decoding failed: keyNotFound(\"items\", …)",
    "crash.type": "Swift.DecodingError",
    "crash.fatal": false,
    "crash.screen": "CartViewController",
    "crash.context.cart_id": "c_98231"
  }
}
```

`context:` keys are flattened with a `crash.context.` prefix at the
capture layer — the `Recorder` never sees nested data.

### Stage 5 — Foreground / background transitions

`LifecycleCapture` subscribes to `UIApplication` notifications.

```jsonc
{
  "type": "event",
  "eventName": "app_lifecycle",
  "timestamp": "2026-06-15T08:01:00.000Z",
  "attributes": {
    "lifecycle.state": "background",        // "active" | "inactive" | "background"
    "lifecycle.previous_state": "active",
    // v1.1 scene attribution (iPad multi-window):
    "lifecycle.scene_id": "primary",
    "lifecycle.scene_count": 1,
    "lifecycle.scene_role": "windowApplication"
  }
}
```

Side effects on `willResignActive`:

- `BatchTransport` flushes immediately.
- `session.finalized` emitted (Stage 7).
- Frame/memory samplers pause; `NWPathMonitor` continues.
- Background `URLSession`
  (`URLSessionConfiguration.background(withIdentifier: "com.edge.rum.upload")`)
  takes over.

#### 5a. Memory warning (v1.1)

`applicationDidReceiveMemoryWarning` is distinct from the
`memory_usage` metric: this is iOS *asking* the app to free memory,
not the sampler reporting state.

```jsonc
{
  "type": "event",
  "eventName": "memory_warning",
  "timestamp": "2026-06-15T08:30:00.000Z",
  "attributes": {
    "memory.resident_mb": 312.4,
    "memory.pressure": "warn",
    "memory.screen": "PhotoViewController"
  }
}
```

### Stage 6 — Hangs and native crashes (in-process)

#### Hangs (immediate emit)

`HangDetector` uses a `CFRunLoopObserver` watchdog. Main-thread block
beyond `hangTimeout` (default 5 s) emits `app.crash` with `cause = "Hang"`.
The app keeps running.

```jsonc
{
  "type": "event",
  "eventName": "app.crash",
  "timestamp": "2026-06-15T08:00:24.500Z",
  "attributes": {
    "crash.cause": "Hang",
    "crash.runtime": "native",
    "crash.source": "watchdog",             // v1.1: "watchdog" | "metrickit"
    "crash.fatal": false,
    "crash.duration_ms": 5840,
    "crash.screen": "CheckoutViewController",
    "crash.thread.main_stack": "0 …\n1 …\n2 …"
  }
}
```

#### Native crashes (captured now, emitted next launch)

PLCrashReporter catches `NSException` or Mach signals (`SIGSEGV` /
`SIGABRT` / `SIGBUS` / `SIGILL`) and writes a private report. The
crash sidecar (`Library/Caches/edge-rum/last-session.json`) — rewritten
by `Recorder` on every event — preserves the dying session's identity:

```json
{
  "session.id": "session_1718438400002_ff009988aabbccdd_ios",
  "session.start_time": "2026-06-15T08:00:00.002Z",
  "session.sequence": 7,
  "user.id": "user_1717100000000_deadbeefcafef00d",
  "device.id": "device_1717234876123_a1b2c3d4e5f60718_ios",
  "screen.current": "CheckoutViewController"
}
```

Replay on the next launch is Stage 9.

### Stage 7 — Session finalize

Triggered on `willResignActive` (immediate flush before iOS suspends)
or on 30-minute idle rollover.

1. Stop samplers.
2. Emit `session.finalized`.
3. Flush the in-memory buffer.
4. Anything that doesn't make it goes to `OfflineQueue`.

```jsonc
{
  "type": "event",
  "eventName": "session.finalized",
  "timestamp": "2026-06-15T08:01:00.001Z",
  "attributes": {
    "session.duration_ms": 60001,
    "session.event_count": 24,
    "session.error_count": 1,
    "session.screen_count": 3,
    "session.final_screen": "CartViewController"
  }
}
```

`session.sequence` increments on every **successful** batch send. If
the finalize batch is queued offline, the increment is deferred until
the eventual replay succeeds.

### Stage 8 — Background flushing and offline replay

Once the process is suspended, in-flight uploads continue on the
background `URLSession`. The host app must wire its AppDelegate's
`application(_:handleEventsForBackgroundURLSession:completionHandler:)`
to `EdgeRum.handleBackgroundEvents(identifier:completion:)`. Without
that wiring, background flushing degrades to next-foreground replay.

On the next foreground, on `NWPathMonitor` reporting `.satisfied`, or
on `EdgeRum.enable()`, `OfflineQueue` drains files under
`Library/Caches/edge-rum/queue/<epochMs>-<seq>.json` sequentially. Each
file is a complete batch payload, ready to POST verbatim.

No new event types are emitted by this stage — the payloads are the
original batches captured earlier.

### Stage 9 — Next launch (after a native crash)

`EdgeRum.start()` calls `PLCrashIntegration.replayIfNeeded()` before
samplers install.

1. Load the previous PLCrashReporter report.
2. Load `last-session.json`.
3. Build an `app.crash` event whose identity attributes are the
   **previous** session's:

```jsonc
{
  "type": "event",
  "eventName": "app.crash",
  "timestamp": "2026-06-15T08:30:00.002Z",   // replay time
  "attributes": {
    "crash.cause": "NativeCrash",
    "crash.runtime": "native",
    "crash.source": "plcrashreporter",       // v1.1: "plcrashreporter" | "metrickit"
    "crash.fatal": true,
    "crash.signal": "SIGSEGV",
    "crash.screen": "CheckoutViewController",
    "crash.timestamp": "2026-06-15T08:00:30.998Z",  // when it actually crashed
    "crash.thread.crashed_stack": "0 …\n1 …\n2 …",
    "crash.thread.other_stacks": "… (truncated to N frames per thread) …",

    // PREVIOUS session's identity, not the current process's:
    "session.id": "session_1718438400002_ff009988aabbccdd_ios",
    "session.start_time": "2026-06-15T08:00:00.002Z",
    "session.sequence": 7,
    "user.id": "user_1717100000000_deadbeefcafef00d",
    "device.id": "device_1717234876123_a1b2c3d4e5f60718_ios"
  }
}
```

After replay the report is deleted and the launch proceeds through
Stage 1 normally.

---

## 6. Out-of-band signal (MetricKit, v1.1)

MetricKit delivers `[MXMetricPayload]` and `[MXDiagnosticPayload]`
asynchronously — typically once per day, on app launch. The subscriber
fans payloads into existing and new event/metric envelopes.

### 6.1 Crash and hang diagnostics → existing `app.crash`

`MXCrashDiagnostic` and `MXHangDiagnostic` route through `app.crash`
with `crash.source = "metrickit"`. **Same allowlisted eventName.**

```jsonc
{
  "type": "event",
  "eventName": "app.crash",
  "timestamp": "2026-06-16T08:00:01.000Z",
  "attributes": {
    "crash.cause": "NativeCrash",
    "crash.runtime": "native",
    "crash.source": "metrickit",
    "crash.fatal": true,
    "crash.timestamp": "2026-06-15T14:33:22.000Z",
    "crash.exception_type": "EXC_BAD_ACCESS",
    "crash.exception_code": "0x00000001",
    "crash.signal": "SIGSEGV",
    "crash.virtual_memory_region_info": "…",
    "crash.application_version": "2.1.0",
    "crash.os_version": "17.4.1",
    "crash.metrickit_payload_id": "MX-…"      // backend dedup vs PLCrashReporter
  }
}
```

PLCrashReporter remains the primary path. MetricKit is a backstop and
contributes fields PLCrashReporter doesn't expose. Backend dedup is
keyed on `crash.metrickit_payload_id` when present.

### 6.2 Launch metrics → existing `page_load`

Covered in Stage 2 above. `MXAppLaunchMetric` distinguishes cold /
resume / **prewarm**, which `CADisplayLink` cannot.

### 6.3 New metric: `scroll_hitch_ratio` (v1.1)

`MXAnimationMetric.scrollHitchTimeRatio` — the cleanest single number
for "scrolling feels janky."

```jsonc
{
  "type": "metric",
  "metricName": "scroll_hitch_ratio",
  "value": 0.0134,
  "timestamp": "2026-06-16T08:00:03.000Z",
  "attributes": {
    "scroll.source": "metrickit",
    "scroll.aggregation_window_hours": 24
  }
}
```

### 6.4 New metric: `system_exception` (v1.1)

Folds `MXCPUExceptionDiagnostic` + `MXDiskWriteExceptionDiagnostic`
under one metric with a discriminator.

```jsonc
{
  "type": "metric",
  "metricName": "system_exception",
  "value": 2940.0,                            // duration ms (CPU) or bytes (disk)
  "timestamp": "2026-06-16T08:00:04.000Z",
  "attributes": {
    "exception.kind": "cpu",                  // "cpu" | "disk_write"
    "exception.duration_ms": 2940,
    "exception.total_cpu_time_ms": 5910,
    "exception.callstack_root": "…"            // top frame, truncated
  }
}
```

### 6.5 New metric: `energy_impact` (v1.1)

`MXEnergyMetric` summarises energy consumption — better than inferring
from battery deltas.

```jsonc
{
  "type": "metric",
  "metricName": "energy_impact",
  "value": 0.0421,                            // kilowatt-hours over window
  "timestamp": "2026-06-16T08:00:05.000Z",
  "attributes": {
    "energy.aggregation_window_hours": 24,
    "energy.foreground_seconds": 1843,
    "energy.background_seconds": 401
  }
}
```

---

## 7. Host-opt-in signal (v1.2+)

These require the host app to call new SDK APIs that forward platform
callbacks. Documented here so storage planning accounts for them.

### 7.1 `background_task` (v1.2+)

If the host wires `BGTaskScheduler` handlers through
`EdgeRum.observeBackgroundTask(_:)`:

```jsonc
{
  "type": "event",
  "eventName": "background_task",
  "timestamp": "2026-06-16T08:35:00.000Z",
  "attributes": {
    "bgtask.identifier": "com.example.shop.refresh",
    "bgtask.kind": "app_refresh",              // "app_refresh" | "processing"
    "bgtask.outcome": "completed",             // "completed" | "expired" | "failed"
    "bgtask.duration_ms": 4120
  }
}
```

### 7.2 `notification_interaction` (v1.2+)

If the host forwards `UNUserNotificationCenterDelegate` callbacks to
`EdgeRum.handleNotificationResponse(_:)`:

```jsonc
{
  "type": "event",
  "eventName": "notification_interaction",
  "timestamp": "2026-06-16T09:00:00.000Z",
  "attributes": {
    "notification.id": "promo_2026_06",
    "notification.action": "open",             // "open" | "dismiss" | "custom_<id>"
    "notification.category": "promotion",
    "notification.foreground": false
  }
}
```

---

## 8. Deferred signal (not in any current milestone)

Available natively but each carries a tradeoff that needs sign-off
before adoption. Listed for completeness so the processor team knows
what to expect if ADRs land.

| Signal                          | Source                                  | Why deferred                                                       |
|---------------------------------|------------------------------------------|---------------------------------------------------------------------|
| Precise geo via Core Location   | `CLLocationManager`                     | Needs `NSLocationWhenInUseUsageDescription`; privacy-significant.    |
| StoreKit transactions           | `StoreKit.Transaction.updates`          | Commerce-app-specific; scope creep for a general RUM SDK.            |
| Pedometer / motion              | `CoreMotion`                            | Needs `NSMotionUsageDescription`.                                    |
| Microphone / camera activity    | `AVCaptureSession`                      | Privacy-sensitive even at "activity" level.                          |
| Carrier name                    | `CTCarrier`                             | Deprecated iOS 16+; returns placeholder values.                      |
| ViewController transition time  | `UIViewControllerTransitionCoordinator` | Redundant with `frame_render_time` + `navigation` dwell.            |
| Audio session interruption      | `AVAudioSession`                        | Useful for media apps; defer to ADR before adoption.                 |
| Jailbreak heuristics            | Heuristic                               | Brittle; false-positive prone; abuse-detection scope.                |
| WKWebView traffic               | `WKWebView` content-rule callbacks      | Out of scope; native + web are separate SDKs.                        |

---

## 9. Per-stage summary

Compact view of which name fires at which stage. Identity attributes
(§ 3) are present on every row and omitted here.

| Stage                         | `type`  | name / metricName                | Status | Key event-specific attributes                                                                  |
|-------------------------------|---------|----------------------------------|--------|------------------------------------------------------------------------------------------------|
| 1. `start()`                  | event   | `session.started`                | v1.0   | `session.trigger`, `session.previous_id`                                                       |
| 2. First screen               | event   | `page_load`                      | v1.0   | `page_load.source`, `page_load.cold_start`, `page_load.duration_ms`, `page_load.first_screen`  |
| 2. First screen               | event   | `navigation`                     | v1.0   | `navigation.screen`, `navigation.previous_screen`, `navigation.type`, `navigation.kind`        |
| 3.1 Subsequent screens        | event   | `navigation`                     | v1.0   | as above                                                                                       |
| 3.1 Screen exit               | event   | `screen.duration`                | v1.0   | `screen.name`, `screen.duration_ms`, `screen.exit_method`                                      |
| 3.2 Tap                       | event   | `user.interaction`               | v1.0   | `interaction.kind`, `interaction.target`, `interaction.accessibility_id`, `interaction.screen` |
| 3.3 HTTP                      | event   | `http.request`                   | v1.0   | `http.url`, `http.method`, `http.status_code`, `http.duration_ms`, TLS / protocol enrichment   |
| 3.3 HTTP timings              | metric  | `resource_timing`                | v1.0   | `resource.dns_ms`, `resource.connect_ms`, `resource.tls_ms`, `resource.ttfb_ms`                |
| 3.4 Frames                    | metric  | `frame_render_time`              | v1.0   | `frame.max_ms`, `frame.p95_ms`, `frame.dropped_count`, `frame.target_hz`                       |
| 3.5 Memory                    | metric  | `memory_usage`                   | v1.0   | `memory.resident_mb`, `memory.virtual_mb`, `memory.pressure`                                   |
| 3.6 Long task                 | metric  | `long_task`                      | v1.0   | `long_task.threshold_ms`, `long_task.screen`                                                   |
| 3.7 Connectivity              | event   | `network_change`                 | v1.0   | `network.previous_type`                                                                        |
| 3.8 `identify()`              | event   | `user.profile.update`            | v1.0   | `user.name`, `user.email`, `user.phone`                                                        |
| 3.8 `track()`                 | event   | `custom_event`                   | v1.0   | `event.name`, host-supplied keys                                                               |
| 3.8 `time().end()`            | metric  | (custom)                         | v1.0   | host-supplied keys                                                                             |
| 4. `captureError()`           | event   | `app.crash` (cause=AppError)     | v1.0   | `crash.message`, `crash.type`, `crash.fatal=false`, `crash.context.*`                          |
| 5. Foreground/background      | event   | `app_lifecycle`                  | v1.0   | `lifecycle.state`, `lifecycle.previous_state`, scene attribution (v1.1)                        |
| 5a. Memory warning            | event   | `memory_warning`                 | v1.1   | `memory.resident_mb`, `memory.pressure`, `memory.screen`                                       |
| 6. Hang                       | event   | `app.crash` (cause=Hang)         | v1.0   | `crash.duration_ms`, `crash.thread.main_stack`, `crash.fatal=false`                            |
| 6. Native crash (captured)    | —       | —                                | v1.0   | written to sidecar; nothing sent until next launch                                             |
| 6.x MetricKit crash/hang      | event   | `app.crash` (source=metrickit)   | v1.1   | `crash.virtual_memory_region_info`, `crash.metrickit_payload_id`                               |
| 6.x MetricKit scroll hitch    | metric  | `scroll_hitch_ratio`             | v1.1   | `scroll.source`, `scroll.aggregation_window_hours`                                             |
| 6.x MetricKit CPU/disk excp.  | metric  | `system_exception`               | v1.1   | `exception.kind`, `exception.duration_ms`, `exception.callstack_root`                          |
| 6.x MetricKit energy          | metric  | `energy_impact`                  | v1.1   | `energy.aggregation_window_hours`, `energy.foreground_seconds`                                 |
| 7. Session end                | event   | `session.finalized`              | v1.0   | `session.duration_ms`, `session.event_count`, `session.error_count`, `session.screen_count`    |
| 9. Native crash (replayed)    | event   | `app.crash` (cause=NativeCrash)  | v1.0   | `crash.signal`, `crash.fatal=true`, `crash.thread.crashed_stack`, previous-session identity    |
| 7.1 BG task (host-opt-in)     | event   | `background_task`                | v1.2+  | `bgtask.identifier`, `bgtask.kind`, `bgtask.outcome`, `bgtask.duration_ms`                     |
| 7.2 Notification (host-opt-in)| event   | `notification_interaction`       | v1.2+  | `notification.id`, `notification.action`, `notification.category`, `notification.foreground`   |

---

## 10. Complete attribute dictionary

Every attribute the iOS SDK can emit, alphabetised by key.

### 10.1 Identity (§ 3)

See § 3 tables — `app.*`, `device.*`, `network.*`, `session.*`,
`user.*`, `sdk.*`.

### 10.2 Event-specific

| Key                                          | Type   | Status | On event/metric                |
|----------------------------------------------|--------|--------|--------------------------------|
| `bgtask.duration_ms`                         | int    | v1.2+  | `background_task`              |
| `bgtask.identifier`                          | string | v1.2+  | `background_task`              |
| `bgtask.kind`                                | string | v1.2+  | `background_task`              |
| `bgtask.outcome`                             | string | v1.2+  | `background_task`              |
| `cart.total_usd` (example custom)            | double | v1.0   | `custom_event`                 |
| `crash.application_version`                  | string | v1.1   | `app.crash`                    |
| `crash.cause`                                | string | v1.0   | `app.crash`                    |
| `crash.context.*` (host-supplied)            | any primitive | v1.0 | `app.crash`               |
| `crash.duration_ms`                          | int    | v1.0   | `app.crash` (Hang)             |
| `crash.exception_code`                       | string | v1.1   | `app.crash`                    |
| `crash.exception_type`                       | string | v1.1   | `app.crash`                    |
| `crash.fatal`                                | bool   | v1.0   | `app.crash`                    |
| `crash.message`                              | string | v1.0   | `app.crash` (AppError)         |
| `crash.metrickit_payload_id`                 | string | v1.1   | `app.crash` (MetricKit)        |
| `crash.os_version`                           | string | v1.1   | `app.crash`                    |
| `crash.runtime`                              | string | v1.0   | `app.crash`                    |
| `crash.screen`                               | string | v1.0   | `app.crash`                    |
| `crash.signal`                               | string | v1.0   | `app.crash` (NativeCrash)      |
| `crash.source`                               | string | v1.1   | `app.crash`                    |
| `crash.thread.crashed_stack`                 | string | v1.0   | `app.crash` (NativeCrash)      |
| `crash.thread.main_stack`                    | string | v1.0   | `app.crash` (Hang)             |
| `crash.thread.other_stacks`                  | string | v1.0   | `app.crash` (NativeCrash)      |
| `crash.timestamp`                            | ISO 8601 | v1.0 | `app.crash` (NativeCrash replay) |
| `crash.type`                                 | string | v1.0   | `app.crash` (AppError)         |
| `crash.virtual_memory_region_info`           | string | v1.1   | `app.crash` (MetricKit)        |
| `energy.aggregation_window_hours`            | int    | v1.1   | `energy_impact`                |
| `energy.background_seconds`                  | int    | v1.1   | `energy_impact`                |
| `energy.foreground_seconds`                  | int    | v1.1   | `energy_impact`                |
| `event.name`                                 | string | v1.0   | `custom_event`                 |
| `exception.callstack_root`                   | string | v1.1   | `system_exception`             |
| `exception.duration_ms`                      | int    | v1.1   | `system_exception`             |
| `exception.kind`                             | string | v1.1   | `system_exception`             |
| `exception.total_cpu_time_ms`                | int    | v1.1   | `system_exception`             |
| `frame.dropped_count`                        | int    | v1.0   | `frame_render_time`            |
| `frame.max_ms`                               | int    | v1.0   | `frame_render_time`            |
| `frame.p95_ms`                               | int    | v1.0   | `frame_render_time`            |
| `frame.source`                               | string | v1.0   | `frame_render_time`            |
| `frame.target_hz`                            | int    | v1.0   | `frame_render_time`            |
| `http.cellular_fallback`                     | bool   | v1.0   | `http.request` (iOS 17+)       |
| `http.duration_ms`                           | int    | v1.0   | `http.request`                 |
| `http.from_cache`                            | bool   | v1.0   | `http.request`                 |
| `http.host`                                  | string | v1.0   | `http.request`                 |
| `http.method`                                | string | v1.0   | `http.request`                 |
| `http.network_protocol`                      | string | v1.0   | `http.request`                 |
| `http.path`                                  | string | v1.0   | `http.request`                 |
| `http.proxy_connection`                      | bool   | v1.0   | `http.request`                 |
| `http.redirect_count`                        | int    | v1.0   | `http.request`                 |
| `http.request_body_bytes_before_encoding`    | int    | v1.0   | `http.request`                 |
| `http.request_size`                          | int    | v1.0   | `http.request`                 |
| `http.response_size`                         | int    | v1.0   | `http.request`                 |
| `http.reused_connection`                     | bool   | v1.0   | `http.request`                 |
| `http.status_code`                           | int    | v1.0   | `http.request`                 |
| `http.tls_cipher`                            | string | v1.0   | `http.request`                 |
| `http.tls_protocol`                          | string | v1.0   | `http.request`                 |
| `http.url`                                   | string | v1.0   | `http.request`                 |
| `interaction.accessibility_id`               | string | v1.0   | `user.interaction`             |
| `interaction.kind`                           | string | v1.0   | `user.interaction`             |
| `interaction.screen`                         | string | v1.0   | `user.interaction`             |
| `interaction.target`                         | string | v1.0   | `user.interaction`             |
| `lifecycle.previous_state`                   | string | v1.0   | `app_lifecycle`                |
| `lifecycle.scene_count`                      | int    | v1.1   | `app_lifecycle`                |
| `lifecycle.scene_id`                         | string | v1.1   | `app_lifecycle`                |
| `lifecycle.scene_role`                       | string | v1.1   | `app_lifecycle`                |
| `lifecycle.state`                            | string | v1.0   | `app_lifecycle`                |
| `long_task.screen`                           | string | v1.0   | `long_task`                    |
| `long_task.threshold_ms`                     | int    | v1.0   | `long_task`                    |
| `memory.pressure`                            | string | v1.0   | `memory_usage`, `memory_warning` |
| `memory.resident_mb`                         | double | v1.0   | `memory_usage`, `memory_warning` |
| `memory.screen`                              | string | v1.1   | `memory_warning`               |
| `memory.virtual_mb`                          | double | v1.0   | `memory_usage`                 |
| `navigation.kind`                            | string | v1.0   | `navigation`                   |
| `navigation.previous_screen`                 | string | v1.0   | `navigation`                   |
| `navigation.screen`                          | string | v1.0   | `navigation`                   |
| `navigation.type`                            | string | v1.0   | `navigation`                   |
| `network.previous_type`                      | string | v1.0   | `network_change`               |
| `notification.action`                        | string | v1.2+  | `notification_interaction`     |
| `notification.category`                      | string | v1.2+  | `notification_interaction`     |
| `notification.foreground`                    | bool   | v1.2+  | `notification_interaction`     |
| `notification.id`                            | string | v1.2+  | `notification_interaction`     |
| `page_load.cold_start`                       | bool   | v1.0   | `page_load`                    |
| `page_load.duration_ms`                      | int    | v1.0   | `page_load`                    |
| `page_load.first_draw_avg_ms`                | int    | v1.1   | `page_load` (MetricKit)        |
| `page_load.first_screen`                     | string | v1.0   | `page_load`                    |
| `page_load.optimized_avg_ms`                 | int    | v1.1   | `page_load` (MetricKit, iOS 16+) |
| `page_load.prewarmed`                        | bool   | v1.1   | `page_load` (MetricKit)        |
| `page_load.resume_avg_ms`                    | int    | v1.1   | `page_load` (MetricKit)        |
| `page_load.sample_count`                     | int    | v1.1   | `page_load` (MetricKit)        |
| `page_load.source`                           | string | v1.0   | `page_load`                    |
| `resource.connect_ms`                        | int    | v1.0   | `resource_timing`              |
| `resource.dns_ms`                            | int    | v1.0   | `resource_timing`              |
| `resource.download_ms`                       | int    | v1.0   | `resource_timing`              |
| `resource.fetch_start_to_response_end_ms`    | int    | v1.0   | `resource_timing`              |
| `resource.protocol`                          | string | v1.0   | `resource_timing`              |
| `resource.redirect_count`                    | int    | v1.0   | `resource_timing`              |
| `resource.tls_ms`                            | int    | v1.0   | `resource_timing`              |
| `resource.transaction_count`                 | int    | v1.0   | `resource_timing`              |
| `resource.ttfb_ms`                           | int    | v1.0   | `resource_timing`              |
| `resource.url`                               | string | v1.0   | `resource_timing`              |
| `screen.duration_ms`                         | int    | v1.0   | `screen.duration`              |
| `screen.exit_method`                         | string | v1.0   | `screen.duration`              |
| `screen.name`                                | string | v1.0   | `screen.duration`              |
| `scroll.aggregation_window_hours`            | int    | v1.1   | `scroll_hitch_ratio`           |
| `scroll.source`                              | string | v1.1   | `scroll_hitch_ratio`           |
| `session.duration_ms`                        | int    | v1.0   | `session.finalized`            |
| `session.error_count`                        | int    | v1.0   | `session.finalized`            |
| `session.event_count`                        | int    | v1.0   | `session.finalized`            |
| `session.final_screen`                       | string | v1.0   | `session.finalized`            |
| `session.previous_id`                        | string | v1.0   | `session.started`              |
| `session.screen_count`                       | int    | v1.0   | `session.finalized`            |
| `session.trigger`                            | string | v1.0   | `session.started`              |

---

## 11. Backend asks

Items the EdgeTelemetryProcessor team must confirm before SDK code
lands.

### v1.0 (blocking ship)

1. **`sdk.platform = "ios-native"`** is a new value. Confirm the
   dispatcher accepts it on every event / metric.
2. **Web Vital metrics absent.** Confirm iOS batches missing `LCP`,
   `FCP`, `CLS`, `INP`, `TTFB` are ingested without error.
3. **Tier 1 / Tier 3 attribute keys** (every `v1.0+` row in § 3 and § 10).
   These are additive and pose no parsing risk, but please confirm
   storage column / index strategy.

### v1.1 (proposed, additive)

4. New `metricName = "scroll_hitch_ratio"` — accept and route?
5. New `metricName = "system_exception"` (single metric, kind
   discriminator for CPU + disk) — accept this shape, or split?
6. New `metricName = "energy_impact"` — accept and route?
7. New `eventName = "memory_warning"` — accept, or fold into
   `app_lifecycle`?
8. New `crash.source` discriminator on `app.crash` (values:
   `plcrashreporter` · `metrickit` · `watchdog` · `captureerror`).
   Dedup keyed on `crash.metrickit_payload_id` when present — confirm
   tolerable.
9. New scene-attribution attributes on `app_lifecycle`
   (`lifecycle.scene_id`, `lifecycle.scene_count`, `lifecycle.scene_role`).

### v1.2+ (host-opt-in)

10. New `eventName = "background_task"` — accept and route?
11. New `eventName = "notification_interaction"` — accept and route?

### Deferred (per-ADR, no current ask)

Every item in § 8 needs a separate backend ask if and when an ADR
greenlights it. Not bundled here.

---

## 12. Sequencing recommendation

Land in this order to minimise risk and backend coordination:

1. **v1.0 ships:** all `v1.0` and `v1.0+` rows. Asks 1–3 must be
   confirmed.
2. **v1.1 ships:** all `v1.1` rows — MetricKit subscriber, memory
   warning event, scene attribution. Asks 4–9 must be confirmed.
3. **v1.2+ ships:** `background_task` and `notification_interaction`
   if and when the host-app integration points land. Asks 10–11
   needed.
4. **Deferred items** stay in § 8 until per-ADR sign-off.
