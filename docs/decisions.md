# Architectural Decision Records — `edge-rum-ios`

This file is the running log of load-bearing architectural choices for
the iOS SDK. Each entry is a short rationale paired with the date the
decision was taken and the alternatives that were considered. Entries
are append-only — superseded decisions stay in the file and are marked
`Superseded by: ADR-NNN`.

---

## ADR-001 — iOS floor at 14.0; depend only on `opentelemetry-swift-core`

**Date:** 2026-06-15

**Status:** Accepted.

**Context.** The original `PLAN-iOS.md` committed to an iOS 12.0 floor
while `CLAUDE.md` already said iOS 14.0+; the two project documents
were internally inconsistent. Upstream `open-telemetry/opentelemetry-swift`
also changed materially: it split into a core package
(`opentelemetry-swift-core`, iOS 12 floor) and an umbrella package
(`opentelemetry-swift`, iOS 13 floor) that ships maintained
instrumentations (`URLSessionInstrumentation`, `NetworkStatus`,
`MetricKitInstrumentation`, `Sessions`, `ResourceExtension`,
`SignPostIntegration`, `PersistenceExporter`). Both upstream packages
now declare `swift-tools-version: 6.0`, forcing a toolchain decision
on us as well.

**Decision.**

1. **Minimum iOS = 14.0.** Aligns `PLAN-iOS.md` with `CLAUDE.md`,
   covers ~98% of currently active iOS devices in 2026, removes
   nearly every `@available` fallback we would otherwise have to
   write, and unlocks `MXCrashDiagnostic` / `MXHangDiagnostic`
   / `PrivacyInfo.xcprivacy` as base behaviour rather than guarded
   special cases.
2. **Depend only on `opentelemetry-swift-core` 2.x** (pinned at
   `from: "2.4.1"`), imported as `OpenTelemetryApi` and
   `OpenTelemetrySdk` from `EdgeRumOTelBridge` and marked
   `@_implementationOnly`. Do **not** depend on the umbrella
   `opentelemetry-swift` package; do not adopt any upstream
   instrumentation library.
3. **`swift-tools-version: 6.0`** in `Package.swift`, build with
   Xcode 16+. Public source surface remains Swift-5-compatible so
   consumer apps need not adopt Swift 6 strict concurrency.

**Rationale.**

- Our wire contract (`telemetry_batch`, flat-attribute JSON, exact
  `eventName` allowlist) forces us to rewrite every OTel span/log
  before send, so upstream instrumentations save little work and
  pay a measurable code-gen cost.
- The upstream `Sessions` instrumentation persists its own
  UserDefaults-keyed session IDs and emits OTel log records — wire-
  incompatible with our `session_<epochMs>_<hex>_ios` /
  `session.sequence` semantics. Adopting it would be more code than
  rebuilding session management ourselves.
- Even though SPM does not link unused targets, pulling the umbrella
  resolves `grpc-swift`, `swift-nio`, `swift-protobuf`,
  `Thrift-Swift`, and `opentracing-objc` into the dependency graph,
  bloating SBOM and CI resolve time.

**Alternatives considered.**

- **iOS 13.0 floor with the umbrella.** Would enable upstream
  `URLSessionInstrumentation` and `NetworkStatus`, saving ~600 LOC
  of capture code. Rejected because (a) the wire mismatch above
  still applies, (b) we still have to write the bridge anyway, and
  (c) it locks us into the umbrella's iOS 13 floor permanently.
- **iOS 12.0 floor with `opentelemetry-swift-core` only.** Maximum
  device coverage but forces extensive `@available` ladders for
  MetricKit, PrivacyInfo behaviour, and async URLSession. Negligible
  install-base gain over iOS 14 (<2% in 2026).
- **Pin to pre-2.x OTel.** Avoids the Swift-6 toolchain bump but
  locks us to an end-of-life upstream branch.

**Consequences.**

- `Package.swift`, `EdgeRum.podspec`, and the XCFramework build all
  target iOS 14.
- CI runs three simulator slices: iPhone SE 2 / iOS 14.5, iPhone 11
  / iOS 16.x, iPhone 15 Pro / iOS 17.x.
- The single remaining `@available(iOS 15, *)` gate (ProMotion
  observation in §6.10) carries a documented 60 Hz fallback.
- `PLAN-iOS.md` §5.4 holds the "why no umbrella" explanation in the
  architecture document; this ADR holds the dated decision.

---

## ADR-002 — F2 public API shape: sealed `AttributeValue`, idempotent `RumTimer`, no-op Recorder seam

**Date:** 2026-06-16

**Status:** Accepted.

**Context.** F2 lands the entire consumer-facing Swift surface for
`edge-rum-ios` (`PLAN-iOS.md` §F2 / §3). Three design choices on that
surface deserve a dated rationale because each has a more obvious
"obvious" alternative we deliberately turned down. F3 — the real
Recorder — lands after F2, so F2 also has to decide how the public
surface couples to the (not yet built) Recorder.

**Decision.**

1. **`AttributeValue` is a sealed enum (`.string` / `.int` / `.double`
   / `.bool`), not `Any` or `Encodable`.** Every public method that
   accepts attributes is typed as `[String: AttributeValue]?`,
   including `EdgeRum.captureError(_:context:)`.
2. **`RumTimer` is a `final class`, not a `struct`.** `end()` and
   `cancel()` are idempotent under an internal `NSLock`; second
   calls are silent no-ops rather than crashes.
3. **The public namespace routes every call through an internal
   `Recording` protocol with a swappable shared instance**
   (`Recorder.shared` in `EdgeRumCore`). F2 ships a no-op
   implementation that buffers calls in memory; F3 swaps in the
   real fan-in/transport implementation behind the same protocol
   without touching `Sources/EdgeRum/`.

**Rationale.**

1. The JSON wire contract documented in `CLAUDE.md` allows only
   `String`, `Int`, `Double`, `Bool` in `attributes`. A sealed enum
   makes the compiler enforce that — there is no path by which a
   caller can hand the SDK an `[String: Any]` containing a `Date`,
   nested dictionary, or array of objects and have the encoder
   silently produce a malformed payload. The four
   `ExpressibleBy…Literal` conformances keep the call sites tidy.
2. `RumTimer` consumers always come from `EdgeRum.time(_:)` — they
   never construct one. A class with internal mutable state lets
   `end()` mark itself "settled" once, regardless of how many copies
   of the reference the host app holds. With a struct we would either
   have to require `inout` (awkward) or accept that copying a timer
   silently splits its identity. Either is a worse failure mode than
   "second `end()` is a no-op".
3. F2 acceptance demands the public surface compile, ship, and route
   correctly without F3's transport in place. Wiring the surface
   directly to a stub Recorder behind an `internal protocol Recording`
   keeps the F2 → F3 transition a one-file edit (the implementation
   of `Recorder`), keeps the surface fully testable today via a
   probe Recorder, and means the firewall check examines a stable
   target (`Sources/EdgeRum/`) that will not churn when F3 lands.

**Alternatives considered.**

- **`[String: Encodable]` or `[String: Any]` for attributes.** Web
  and Android SDKs work this way; consumers find it natural. Rejected
  because the type system would no longer catch wire-incompatible
  values at call sites — and the wire contract is the constraint
  that matters most.
- **`RumTimer` as a `struct` with `mutating end()`.** Briefer; no
  reference semantics. Rejected because `EdgeRum.time(_:)` returning
  a struct then stored in a `let` would forbid `end()` entirely.
- **Public methods that take a closure or builder.** More flexible,
  fits Swift idiom. Out of scope — we'd be designing for hypothetical
  use cases.
- **Defer F2 until F3 lands so the public surface routes to a real
  Recorder from day one.** Rejected because it blocks every other
  feature on F3 and removes the integration-test feedback loop for
  the public shape.

**Consequences.**

- The public `AttributeValue` enum lives in `EdgeRumCore` (not
  `EdgeRum`) so the internal `Recording` protocol can take
  `[String: AttributeValue]` without a back-edge on the public
  module. `EdgeRum` re-exports it as a `public typealias` so the
  consumer name stays `AttributeValue`.
- `EdgeRumCore` is not a SwiftPM product; promoting its types to
  `public` exposes them only to other internal targets that depend
  on `EdgeRumCore`, never to outside consumers. Outside consumers
  see only what `Sources/EdgeRum/` declares public.
- `EdgeRum.start(_:)` is idempotent: same `apiKey` + `endpoint`
  re-entry is a silent no-op; a different identity logs a warning
  and is ignored. Misuse on input (empty `apiKey`, missing `edge_`
  prefix, non-`https` endpoint in non-debug builds) hits
  `preconditionFailure` so debug and release behaviour match.
- `Tools/firewall-check.sh` runs on every PR (audit job) and
  policies `Sources/EdgeRum/`, the public symbol graph, `README.md`,
  and consumer-facing `docs/*.md` against Rule 1's banned-token list.

---

## ADR-003 — F3 core pipeline: strict allowlist, in-memory seams, manual ISO 8601 encoding

**Date:** 2026-06-16

**Status:** Accepted.

**Context.** F2 stood up the public API surface and the internal
`Recording` protocol with a no-op stub Recorder. F3 lands the real
pipeline behind that seam — context merging, batching, payload
assembly — without touching transport, persistence, or the offline
queue (those are F4–F5). Issue #8 lists five tasks: T3.1 (Recorder
façade), T3.2 (EventEnvelope + AttributeBag), T3.3 (ContextProvider),
T3.4 (Sampler + Clock), T3.5 (PayloadBuilder). Five design choices
during implementation were load-bearing enough to record.

**Decisions.**

1. **Keep the `Recording` protocol shape stable; remap `track()` →
   `custom_event` in the public surface.** `EdgeRum.track(name, attrs)`
   now sets `attrs["event.name"] = name` and calls
   `Recorder.recordEvent(name: "custom_event", attributes: attrs)`.
   The Recorder's `allowedEventNames` set stays strict (12 wire-spec
   values) and rejects everything else.
2. **`AttributeBag` merge semantics: event attrs win on conflict.**
   `context.merging(event)` always lets event-supplied keys overwrite
   context-supplied keys. Matches CLAUDE.md's `{ _, new in new }`
   spec literally and prevents stale context attributes from masking
   intentional event-site overrides.
3. **Manual ISO 8601 encoding via `ISO8601DateFormatter` with
   `[.withInternetDateTime, .withFractionalSeconds]`.** Not
   `JSONEncoder.dateEncodingStrategy = .iso8601` because the strategy
   omits fractional seconds on some Apple runtimes, and the backend
   dispatcher relies on the `.SSS` precision for ordering events
   within a session.
4. **In-memory `TransportSink` (`NoopTransportSink`) + in-memory
   `SessionStore` (`InMemorySessionStore`) as F3 defaults.** Both are
   protocols so F4 can layer `HTTPTransportSink` (POST to
   `<endpoint>/collector/telemetry`) and `UserDefaultsSessionStore`
   (suite `com.edge.rum.session`) on top without touching the
   Recorder.
5. **`SecRandomCopyBytes(8)` everywhere for ID entropy.** Not
   `UUID()`. The `UUID` hex section is 128 bits and breaks the
   `^(session|device|user)_\d+_[0-9a-f]{16}(_ios)?$` format the
   Android/web/iOS dispatcher all share.

**Alternatives considered.**

- **Permissive `allowedEventNames`** — let `recordEvent(name: "foo")`
  pass through as a `custom_event`. Rejected because it shifts the
  custom-event mapping into the Recorder, where it's harder to test
  in isolation and one capture-layer typo silently lands an unknown
  `eventName` on the wire (the backend drops these without warning).
- **`JSONEncoder.dateEncodingStrategy = .iso8601`** — one less
  formatter to keep alive. Rejected because the strategy drops
  fractional seconds on older runtimes and would silently degrade
  precision once a host app ships on an older iOS minor.
- **A single F3 commit that also ships `HTTPTransportSink` so events
  reach the backend on day one.** Rejected — the issue boundary
  (issue #8 = "Recorder, context, payload"; issue #14 = transport)
  is clean, and conflating them would block CI on a working backend
  endpoint we don't have yet.

**Consequences.**

- F2's single test `testTrackRoutesNameAndAttributes` flips one
  assertion from `name == "checkout_started"` to
  `name == "custom_event"` plus
  `attributes["event.name"] == "checkout_started"`. This is the only
  F2 test edit; everything else routes unchanged.
- `Recorder.shared` continues to be the singleton entry point;
  `installShared(_:)` still swaps in test probes. F3 adds
  `configure(_:)` to the `Recording` protocol with a default no-op,
  so existing probes (`ProbeRecorder`) compile unchanged.
- `Recorder.flush(reason:)` and `Recorder.shutdown()` are concrete
  methods on the `Recorder` class (not on `Recording`). F4 calls
  them directly via `Recorder.shared as? Recorder`.
- `ContextProvider` snapshots app/device/network/session/user/sdk
  bags. Battery monitoring is read whenever
  `UIDevice.isBatteryMonitoringEnabled` is `true`; F3 does not toggle
  it on the host's behalf. Cellular `network.effectiveType` is
  reported as `"cellular"` only — `CTTelephonyNetworkInfo`-derived
  refinement (`"4g"`/`"5g"`) lands in F8.
- `Tests/EdgeRumContractTests/WireAssertions.swift` is the new
  reusable helper. Every transport-touching test in F4+ runs every
  envelope through `assertValidEnvelope(_:)` before further
  assertions.

---

## ADR-004 — F4 persistent identity: Keychain `device.id`, UserDefaults `user.id` + session triple, sidecar mirror

**Date:** 2026-06-16

**Status:** Accepted.

**Context.** F3 shipped in-memory identity stores so the Recorder
pipeline could be exercised end-to-end without touching disk. The
backend dispatcher routes by `(device.id, session.id, user.id)`
attributes on every event; without persistence, each app launch would
look like a brand-new device to the backend and the cross-platform
analytics joins (web/Android/iOS) would break. F4's job is to make
the three identifiers survive across launches while keeping the
testing seams F3 set up unchanged.

**Decision.**

1. **`device.id` lives in the Keychain** under
   `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. Service name
   `com.edge.rum.identity`; account name `device.id`. The
   "ThisDeviceOnly" variant keeps the value out of iCloud Keychain so
   a restored device gets a fresh `device.id` — which matches the
   web/Android SDK semantics where `device.id` is per-install, not
   per-iCloud-identity. Modern iOS clears the Keychain on uninstall
   on most installs, so reinstalling rotates `device.id`
   transparently. Documented in the README "Identity & session
   model" section.

2. **`user.id` and the session triple live in the UserDefaults
   suite `com.edge.rum.session`.** UserDefaults is faster than the
   Keychain for the per-event write hot path (the session
   `lastActiveAt` field updates on every `recordEvent`), and the
   session is short-lived so its accessibility classification matters
   less. The suite name is reserved across the SDK — every persisted
   key in F4 (`edge.rum.device.id.fallback`, `edge.rum.user.id`,
   `edge.rum.session.state`) lives under it so future tooling can
   wipe the whole namespace in one call.

3. **Keychain failure falls back to UserDefaults.** A `SecItemAdd`
   failure is rare on iOS but observed on locked-down enterprise
   profiles. On failure, the IdentityProvider writes `device.id` to
   `edge.rum.device.id.fallback` in the same UserDefaults suite. On
   subsequent reads the IdentityProvider checks the Keychain first,
   then the fallback. When the Keychain becomes writable again, the
   next `regenerateDeviceId()` re-persists to the Keychain and clears
   the fallback. The fallback is observable via
   `IdentitySnapshot.deviceIdFromFallback` so the Recorder can emit
   one diagnostic `os_log` line at startup when it kicks in.

4. **Sidecar location `Library/Caches/edge-rum/last-session.json`.**
   The Caches directory is preserved across app terminations but iOS
   may purge it under disk pressure. That's acceptable for the
   sidecar because it is only load-bearing while a crash report from
   the PRIOR launch is still pending. Anything more durable
   (Documents) would persist crash-replay attribution into
   indefinitely many launches, which is wrong. The mirror is
   restricted to the identity triple plus `sdk.version` /
   `sdk.platform` (`SessionSidecar.mirroredKeys`) — transient values
   like battery level and network type are deliberately omitted so
   the replayed crash event carries the prior session's *identity*,
   not its environment.

5. **`identify()` does not persist `external_id`.** Only the
   SDK-owned anonymous `user.id` is persistent. Host-app identifiers
   passed through `EdgeRum.identify(_:)` ride on events as
   `user.external_id` / `user.name` / `user.email` / `user.phone`
   attributes (via `ContextProvider.setUser`) but the SDK does not
   write them to disk. Rationale: the host app already manages its
   own user record and re-identifies on launch; persisting our copy
   would risk a stale identifier surviving a host-app logout.

6. **`Recorder.installPersistedStores(...)` is the integration
   point** — called once by `EdgeRum.start()` against the shared
   Recorder via an `as? Recorder` cast. This means test probes
   (`ProbeRecorder`) are not affected by `start()` and existing F2/F3
   tests continue to pass unchanged. The shared default Recorder
   keeps its in-memory backing until the host opts in by calling
   `EdgeRum.start(_:)`, which is also the only path on which
   real-Keychain writes happen at all.

7. **Mid-event idle rotation emits a `session.finalized` +
   `session.started` pair.** When `recordEvent` / `recordPerformance`
   detects the touch crossed the 30-minute idle threshold, the prior
   session id is written as event attributes on the finalized event
   (they win over the context bag at flush time), the context
   refreshes to the new session, and the started event is emitted.
   A re-entrancy flag (`_insideRotationEmission`) blocks the
   synthetic emissions from re-triggering the same rotation path.
   The originating event then proceeds normally.

8. **`Recorder.didAckBatch()` is the public hook for sequence
   increments.** F5's transport layer calls it after every 2xx
   response — three consecutive ACKed batches yield
   `session.sequence == 3` on the next emitted event. Issue #43
   acceptance.

**Alternatives considered.**

- **`device.id` in UserDefaults instead of the Keychain.** Simpler,
  faster, no `SecItem*` calls. Rejected: UserDefaults is wiped on
  uninstall AND on `removePersistentDomain(forName:)`; the Keychain
  is the only iOS-supplied store that survives the latter while
  still being purged on uninstall on modern installs. Matches the
  Android SDK's `EncryptedSharedPreferences` choice for the analogous
  field.

- **iCloud-synced `device.id` for cross-device continuity.**
  Rejected: the backend treats every install as a distinct device for
  analytics purposes. Cross-device joining is a `user.id` problem,
  not a `device.id` problem.

- **Sidecar in `Library/Application Support/`.** Rejected: that
  directory is included in iOS backups and would carry the previous
  install's session state into a fresh install — exactly the
  cross-launch attribution bug the sidecar exists to prevent.

- **Closing the F4 scope at T4.3 and deferring the sidecar entirely
  to F14.** Rejected: the sidecar *writer* is a single file with no
  cross-target dependency on PLCrashReporter, and writing it now
  lets F14 land the reader side without first having to also wire
  the writer. The reader/replay side is the carry-over noted on
  issue #44.

**Consequences.**

- One new public surface in `EdgeRumCore`:
  `Recorder.installPersistedStores(identityProvider:sessionStore:sidecar:)`.
  Still internal from `import EdgeRum`'s perspective because
  `EdgeRumCore` is not in `Package.swift`'s `products:`. Locked in by
  `PackageProductsTests`.
- The shared `Recorder()` default keeps in-memory backing; tests that
  predate F4 keep passing without modification. F4's new tests
  inject `InMemoryKeychainStore` / `InMemoryUserDefaultsStore` so the
  CI host doesn't need real Keychain access.
- `EdgeRum.start(_:)` gains a single line that does the
  `as? Recorder` cast and calls `installPersistedStores`. Misuse
  protection: if the cast fails (probe installed), persistence is
  silently skipped — the probe handles its own state.
- F5's transport layer must call `Recorder.didAckBatch()` after every
  successful POST. The F4 contract test
  `IdentityPersistenceConformanceTests` pins this requirement: any
  future regression that loses the increment will fail the test.

---

## ADR-005 — F5 transport: file-backed offline queue, default + background URLSession pair, sampler re-roll on rotation

**Date:** 2026-06-16

**Status:** Accepted.

**Context.** F4 carried two open contracts into F5: the production
`Recorder` still pointed at `NoopTransportSink`, and `Recorder.didAckBatch()`
had no caller. F5 implements `HTTPTransportSink` to close both — and lands
the §9 transport behaviour (retry, offline queue, background uploader,
per-session sampling) in one go. Four design choices during implementation
were load-bearing enough to record.

**Decisions.**

1. **One file per batch on the offline queue, named
   `<epochMs>-<seq>.json`.** No index file, no SQLite, no `QueueFile`
   port from the Android SDK. Lexicographic ordering of the filenames
   matches chronological ordering — `FileManager.contentsOfDirectory`
   sorted by `lastPathComponent` is the FIFO oracle. `seq` is a
   monotonically increasing in-process counter that disambiguates
   enqueues inside the same millisecond. `%013lld-%06llu.json` (not
   `%d`) so 64-bit epoch values are not silently truncated by C's
   `int`-width default.

2. **Two parallel `URLSession`s — default + background.** The live
   `BatchTransport` uses `URLSessionConfiguration.default`; a
   `BackgroundUploader` holds a `URLSessionConfiguration.background(
   withIdentifier: "com.edge.rum.upload")` for the after-suspend
   drain path. We considered routing every batch through the
   background session so a single configuration handles both — but
   the background configuration requires `uploadTask(with:fromFile:)`,
   forcing a temp-file write on the live happy path that the default
   session avoids. Two sessions is one extra ivar and zero performance
   regression on the hot path; one session is meaningfully slower.

3. **Sampler re-rolls on every session rotation.** F3's `Sampler`
   was constructed once per `Recorder.configure(_:)`. PLAN-iOS.md §9.6
   says "per-session uniform random vs `sampleRate`" — the F3 wiring
   technically violated this on idle rotation because a session born
   30 minutes into a paused app inherited the prior session's roll.
   F5 re-rolls in `start()` and inside
   `bumpLastActiveAndEmitRotationIfNeeded()`. The forced-emit
   allowlist still bypasses, so the user-visible behaviour on
   `sampleRate = 0` is unchanged.

4. **`HTTPTransportSink` owns its own `NetworkPathObserver` for the
   drain trigger.** We considered piping the `NWPathMonitor` callback
   through `ContextProvider` (which already needs network transition
   notifications to refresh `network.type` / `network.effectiveType`)
   so there is one `NWPathMonitor` per process. Rejected because
   it would have coupled F5's drain behaviour to F8's
   `network_change` event emission, and starting a second monitor is
   measured at <100 µs / launch. The two observers will be merged in
   F8 when the network-context refresh path lands; for now keeping
   them separate makes each layer testable in isolation.

**Alternatives considered.**

- **Single-file QueueFile port from the Android SDK.** Rejected:
  iOS `Library/Caches/` purge semantics are file-granular, so a
  single-file queue would lose every queued batch on disk pressure
  instead of just the oldest few. The file-per-batch layout maps
  naturally onto Apple's cache eviction.
- **Synchronous retry loop on the URLSession callback thread.**
  Rejected — `URLSession`'s delegate queue is shared with all the
  app's `default` configuration traffic; blocking it during a 30 s
  backoff would delay every other request in the host app.
  `DispatchQueue.asyncAfter` on a dedicated serial queue is the
  right primitive.
- **Sampler re-roll on EVERY event instead of every session.**
  Rejected: contradicts the "per-session" wording in §9.6 and would
  produce statistical garbage at sub-rate values (a `sampleRate = 0.5`
  session with 1000 events would emit ≈500 of them rather than all or
  none).
- **Closing F5 without the background uploader.** Tempting because
  the manual smoke test ("suspend mid-upload, relaunch, observe
  drain") requires a host app and can't run in CI. Rejected because
  `EdgeRum.handleBackgroundEvents(identifier:completion:)` is already
  on the public surface (F2 #25) and host apps wiring it up before
  F5 lands would get a misleading no-op.

**Consequences.**

- New internal directory `Sources/EdgeRumCore/Transport/` holds
  `BatchTransport`, `RetryPolicy`, `OfflineQueue`,
  `BackgroundUploader`, `HTTPTransportSink`, and a small
  `TransportEnvironment` helper. None are exposed by the public
  `EdgeRum` umbrella — terminology firewall verifies clean.
- `TransportSink` gained `drainOfflineQueue()` with a default no-op
  implementation; existing `NoopTransportSink` / `RecordingTransportSink`
  test seams compile unchanged.
- `Recorder.installTransport(_:)` is the F5 mirror of F4's
  `installPersistedStores(...)`. `EdgeRum.start()` calls it once after
  identity persistence, immediately after `installPersistedStores`.
- `EdgeRum.enable()` now drains the offline queue as one of the three
  documented trigger points. The other two — `NWPathMonitor.satisfied`
  and `didBecomeActive` — are wired by the sink directly and by F11
  respectively.
- Coverage of the new transport directory sits at the F5 acceptance
  bar via `BatchTransportTests`, `RetryPolicyTests`, `OfflineQueueTests`,
  `HTTPTransportSinkTests`, `BackgroundUploaderTests`, plus the
  end-to-end `TransportConformanceTests` that pins the
  `Recorder → didAckBatch` integration F4 #43 left open.

---

## ADR-006 — UIKit screen capture via base-class method swizzling

**Date:** 2026-06-16

**Status:** Accepted.

**Context.** F6 needs every UIKit screen entry / exit to emit a
`navigation` event and `screen.duration` metric without consumer-side
code. The host app can be UIKit, SwiftUI-via-`UIHostingController`, or
mixed. The wire shape (`navigation`, `screen.duration`, attribute
keys) is already pinned by §6.1 and `Recorder.allowedEventNames`.

**Decision.**

1. **Swizzle base `UIViewController`, not subclasses.** Exchange the
   IMPs for `viewDidAppear(_:)` and `viewWillDisappear(_:)` on
   `UIViewController` itself. Subclass overrides keep their own IMPs
   and reach the base via `super.viewDidAppear(animated)`, which
   resolves to our injected body. One install site, one IMP swap per
   selector, no per-subclass bookkeeping.
2. **Install is one-shot and never undone.** A small
   `os_unfair_lock`-backed flag guarantees idempotency under
   concurrent install calls. `EdgeRum.disable()` does not un-swizzle —
   the Objective-C runtime cannot safely undo IMP exchanges on a
   class that may already be subclassed by the host app at unknown
   depths. Runtime opt-out instead checks `Recorder.isEnabled` at
   emit time.
3. **Screen-name fallback order — accessibility identifier → reflected
   type name.** `accessibilityIdentifier` is the right primary because
   host apps already set it for UI tests and it survives refactors
   that rename the underlying type. The reflected type name
   (`String(reflecting: type(of: vc))`) is the deterministic fallback
   when no identifier is set.
4. **`UIHostingController` is detected by reflected type-name match,
   not by `is UIHostingController<…>` casts.** The Swift cast requires
   spelling out the generic parameter, which we don't know at the
   capture site. The reflected type name is what the runtime hands
   us and is stable across iOS versions.
5. **Per-controller state lives on the controller via
   `objc_setAssociatedObject`.** A Swift-side
   `[ObjectIdentifier: ScreenState]` map would leak entries for any
   controller that deallocates between appear and disappear. The
   associated object is freed automatically when the controller is.
6. **`navigation.previous_screen` is a single global pointer, not a
   stack.** UIKit's navigation stack model already maintains
   ordering — re-deriving it inside the SDK would duplicate work.
   The previous-screen pointer mirrors the user's mental model
   ("which screen was I just on?") and matches the web/Android SDKs'
   behaviour for the same attribute.

**Alternatives considered.**

- **Subscribing to `UIWindow.didBecomeKey` + traversing the responder
  chain.** Rejected — misses presented modals, child controllers, and
  navigation stack pushes; would require a polling fallback.
- **`@objc dynamic` override of `viewDidAppear` injected by a
  consumer-side category.** Rejected — only works in mixed
  Objective-C / Swift host apps and requires per-consumer setup,
  violating "zero-code capture".
- **Swizzling on `UIHostingController` directly for SwiftUI screens.**
  Rejected — the host might present a SwiftUI view via a
  `UIViewControllerRepresentable` wrapper, not `UIHostingController`,
  so single-point detection on the hosting class is incomplete. The
  base-class swizzle plus `String(reflecting:)` detection catches
  every path UIKit drives.
- **Storing per-controller `appearedAt` in a thread-safe dictionary
  keyed by `ObjectIdentifier`.** Rejected — leaks on disappear-less
  deallocation (sheet dismissal, system kills). Associated objects
  are the right primitive.

**Consequences.**

- `Sources/EdgeRumCapture/UIViewControllerCapture.swift` replaces the
  F1 stub as the module's first real surface. The umbrella `EdgeRum`
  imports `EdgeRumCapture` so `EdgeRum.start(_:)` can call
  `UIViewControllerCapture.install(debug:)` once, gated on
  `config.captureScreens`.
- The Objective-C-visible swizzle entry points
  (`edgerum_swizzled_viewDidAppear:` / `edgerum_swizzled_viewWillDisappear:`)
  live as `internal extension UIViewController` so they sit on the
  base class and never leak into the public umbrella module.
- Tests cover the pure-Swift helpers (`extractHostedContent`,
  `isHostingControllerTypeName`, the previous-screen pointer) on
  every platform; the UIKit-driven tests are gated behind
  `#if canImport(UIKit) && os(iOS)` and run on the iOS simulator
  job in CI.
- `EdgeRum.disable()` halts emission while the swizzle stays
  installed; re-enabling resumes capture without a re-install. The
  `previousScreen` pointer is not reset on disable — the next emit
  on enable chains correctly off the last screen seen.

---

## ADR-007 — F7 SwiftUI sample app uses a checked-in `.xcodeproj`

**Date:** 2026-06-16

**Status:** Accepted.

**Context.** F7's `T7.3` requires a working SwiftUI sample app under
`Samples/EdgeRumSwiftUISampleApp/` that builds against the in-repo SDK
and exercises both public view modifiers. CI must build this sample on
every PR so a future change in the public surface that breaks
consumers fails before merge.

Three project shapes were considered:

1. A hand-rolled, checked-in `.xcodeproj` whose `project.pbxproj`
   lives in version control verbatim.
2. An XcodeGen `project.yml` regenerated from a declarative spec at
   build time (CI installs XcodeGen via Homebrew).
3. A Tuist `Project.swift` evaluated by the Tuist CLI at build time.

**Decision.** Take option (1). The sample target is small (three Swift
files, one Info.plist, one asset catalog, one scheme) and stable
enough that pbxproj churn is bounded.

**Why not XcodeGen or Tuist.** Both introduce a tool dependency on
every CI run and on every contributor's machine. XcodeGen's spec is
short but the manifest format is one more thing reviewers must learn,
and a regenerated pbxproj can drift silently from what Xcode-the-IDE
would produce when contributors add files. Tuist is overkill for a
single sample target. The pbxproj diff noise inherent in option (1)
is a real but acceptable cost — the sample's footprint is unlikely
to change often.

**Consequences.**

- `Samples/EdgeRumSwiftUISampleApp/EdgeRumSwiftUISampleApp.xcodeproj`
  is checked into the repo with its shared scheme under
  `xcshareddata/xcschemes/`. Without the shared scheme, `xcodebuild
  -scheme EdgeRumSwiftUISampleApp` would fail in CI because user
  schemes live under `xcuserdata/` (gitignored).
- The SDK dep is resolved via an `XCLocalSwiftPackageReference` to
  `../..`, the repo root. The first CI run on a fresh runner still
  pulls `opentelemetry-swift-core` from network, but the SDK targets
  themselves resolve from the checkout — no GitHub release is needed.
- `.github/workflows/ci.yml` gains a `sample-build` job that runs
  `xcodebuild ... -destination 'generic/platform=iOS Simulator' build`
  on every PR. Generic-simulator destination avoids the macos-15
  runner's iOS-runtime-version drift.
- Contributors who add files to the sample MUST add them to the
  pbxproj — `swift build` does not touch the sample, so a missing
  reference is not caught until CI's sample-build job fires.
- A future migration to XcodeGen is not blocked. The spec can be
  written from the checked-in pbxproj at any time; the ADR stays in
  the file marked `Superseded by: ADR-NNN` if that happens.

---

## ADR-008 — F8 HTTP capture: URLProtocol + `protocolClasses` instance-getter swizzle

**Date:** 2026-06-17

**Status:** Accepted.

**Context.** F8 needs every outbound `URLSession` request to produce
an `http.request` event and a paired `resource_timing` metric without
consumer-side wiring. The wire keys are pinned by PLAN-iOS.md §6.3.
Three concrete iOS surfaces have to be covered: `URLSession.shared`,
`URLSession(configuration: .default, …)` and the equivalent
`.ephemeral`, and a custom-delegate session built from one of those
configurations. Background-identified configurations are out of scope
per §6.3 (no in-process delegate window for `URLSessionTaskMetrics`).

**Decisions.**

1. **`EdgeRumURLProtocol` is the only interception primitive.** A
   `URLProtocol` subclass is registered globally via
   `URLProtocol.registerClass(_:)` so `URLSession.shared` (and any
   session whose `protocolClasses` includes it) routes through us.
   Inside `startLoading()` we mark the request with a private
   `URLProtocol.setProperty(_:forKey:in:)` flag so the inner session's
   re-issued task does not re-enter `canInit(with:)` recursively.
2. **`URLSessionTaskMetrics` are collected by the internal session's
   own delegate, not by wrapping the consumer's delegate.** The
   protocol owns a private `URLSession(configuration:
   .ephemeral, delegate: EdgeRumMetricsDelegate, …)` whose delegate
   forwards data + response + metrics back into the protocol
   instance. The consumer's own delegate never sees our internal
   traffic — which avoids the "double-call the consumer's
   `didFinishCollecting`" trap that a session-level delegate-proxy
   approach falls into.
3. **For custom-configured sessions, swizzle the instance getter for
   `URLSessionConfiguration.protocolClasses`, not the class-method
   getters for `default`/`ephemeral`.** The class-method-swizzle
   approach (preferred by older SDK patterns) crashes with SIGILL on
   modern Foundation because Swift-imported class methods do not
   tolerate IMP swapping via `method_exchangeImplementations`. The
   instance getter swizzle is the Datadog/Sentry pattern and works
   across iOS 14+ and the macOS test runner. Every URLSession that
   reads its config's `protocolClasses` (which is what happens at
   URL-loading setup time) gets back an array prefixed with
   `EdgeRumURLProtocol`.
4. **Background-identified configurations return their original
   `protocolClasses` array unchanged.** The swizzled getter checks
   `self.identifier != nil` and skips the prepend — background
   uploads (the host's, and our own
   `com.edge.rum.upload` session) never enter our recording path.
5. **Defense-in-depth filter is three independent checks.** The
   `X-Edge-Rum-Internal: 1` header and `taskDescription =
   "edge-rum-internal"` markers — both set by `BatchTransport` on
   every internal request — are the primary gates. The host-prefix
   check against `config.endpoint.host` is the safety net for cases
   where a future refactor strips one of the markers. `canInit(with:)`
   re-runs the same filter at intercept time and `recordOutcome`
   re-runs it again at emit time so a regression in either layer is
   caught by the other.
6. **`sanitizeUrl` runs synchronously, on the caller thread.** Per
   PLAN-iOS.md §6.3. The sanitised URL is reflected on both the
   `http.request` event and the companion `resource_timing` metric
   so query-string redactions stay consistent across both signals.
7. **`ignoreUrls` regex is matched against the sanitised URL string
   (not the original).** Consumers who use `sanitizeUrl` to strip
   secrets and then `ignoreUrls` to drop the sanitised form get the
   intuitive behaviour; matching against the original would force
   them to write two regex variants.

**Alternatives considered.**

- **Class-method swizzle on `URLSessionConfiguration.default` /
  `.ephemeral` getters.** The "obvious" pattern — every other SDK
  doc shows it. Empirically crashes with SIGILL on the macOS Swift 6
  Foundation runtime when `method_exchangeImplementations` swaps a
  Swift-imported class method's IMP. Standalone reproduction in
  `/tmp/swiz_test.swift`. Switched to instance getter swizzle.
- **Wrap the consumer's session delegate.** Lets us also intercept
  WebSocket / upload-task callbacks. Rejected: doubles the surface,
  requires `NSProxy`-style forwarding for every URLSessionDelegate
  selector, and the URLProtocol path already covers data + download
  tasks (the only ones F8 emits for). WebSocket telemetry is not a
  v1.0 signal.
- **Background-configuration support.** Would let the host's
  background uploads emit `http.request` too. Rejected per PLAN-iOS.md
  §6.3 edge case — background tasks have no live delegate window
  for `URLSessionTaskMetrics`, so we'd emit an event with empty
  resource timing. Better to document the gap than emit half-shaped
  events. Future enhancement could store metrics in
  `urlSessionDidFinishEvents(forBackgroundURLSession:)` and replay
  on next launch.
- **Skip `URLSessionConfiguration` swizzle entirely; rely on
  `URLProtocol.registerClass` alone.** Works for `URLSession.shared`
  on iOS but does NOT cover `URLSession(configuration: .default, …)`
  — custom configs ignore globally-registered protocols. Would fail
  T8.2's acceptance criterion ("`URLSession(configuration: .default,
  delegate: customDelegate, ...)` still produces `http.request`").

**Consequences.**

- One new file `Sources/EdgeRumCapture/HTTPCapture.swift` holds the
  installer, URLProtocol subclass, internal metrics delegate, and
  `protocolClasses` swizzle. No public types added.
- `EdgeRum.start(_:)` gains a `captureHTTP`-gated block that calls
  `HTTPCapture.configure(_:)` (passing `ignoreUrls`, `sanitizeUrl`,
  and the collector endpoint host) and `HTTPCapture.install(debug:)`.
- `HTTPCapture.currentConfig` is read on every recorded request so
  hot-swapping config via a follow-up `configure(_:)` works without
  re-installing the swizzle.
- The SDK's own collector POST is filtered three times before any
  capture: by `canInit` (header + endpoint host), by `recordOutcome`
  (header + endpoint host + task description), and by the user's
  own `ignoreUrls` if they configure it.
- Tests cover the filter pipeline (`HTTPCaptureTests`), the wire
  shape of both signals (`HTTPCaptureWireConformanceTests`), and
  the swizzle install path (idempotency + concurrent install). A
  live-network smoke against `https://httpbin.org` is documented in
  the F8 PR body as a manual verification step — CI sandboxes block
  outbound traffic, so the synthetic-metrics test path is the only
  programmatic check of `resource_timing` shape.

---

## ADR-009 — F10 performance samplers: 1 s frame windows, 10 s memory polls, 50 ms `long_task` threshold

**Date:** 2026-06-17

**Status:** Accepted.

**Context.** F10 needs three continuous performance signals —
`frame_render_time`, `memory_usage`, `long_task` — to land on the
wire on a steady cadence without any consumer wiring. PLAN-iOS.md
§6.10/§6.11/§6.12 pin the attribute keys, the threshold for the
long-task signal, and the choice of `CADisplayLink` / mach /
`CFRunLoopObserver` as the data sources. The remaining design
questions are cadence, aggregation, and the placement of the
`long_task` observer relative to F14's hang detector.

**Decisions.**

1. **One `CADisplayLink` attached to `.common` modes drives a single
   1 s `FrameWindowAggregator`.** A per-tick aggregator sums the
   inter-frame delta (`targetTimestamp` − previous `targetTimestamp`),
   and on every 1 s boundary emits one metric with `max`, `p95`, and a
   dropped-count derived from `target_hz * 1 s − samples.count`. A
   shorter window (250 ms) would balloon emit volume; a longer window
   (5 s) hides bursts that a UX dashboard cares about. 1 s also
   matches the cadence the Android and web SDKs use for the same
   signal.
2. **ProMotion is detected from `UIScreen.main.maximumFramesPerSecond`
   on iOS 15+; iOS 14 reports 60 unconditionally.** `CADisplayLink`
   exposes `preferredFrameRateRange` on iOS 15+ which we set to
   `(minimum: 30, maximum: target, preferred: target)` so the link
   matches the panel's native refresh rate; on iOS 14 we pass
   `preferredFramesPerSecond = 0` and report 60 Hz, matching the
   non-ProMotion device floor for that OS version.
3. **Memory is sampled every 10 s and on every memory-pressure
   transition.** The periodic poll covers the steady-state envelope;
   the pressure source surfaces the spikes that matter. `mach_task_basic_info`
   gives RSS + virtual; `task_vm_info.phys_footprint` is the value
   the kernel uses to decide whether to terminate the app under
   memory pressure, so we emit all three rather than collapse them.
   Values are reported in kB (Int) per the existing wire contract.
4. **`long_task` is a metric, not an `app.crash`.** PLAN-iOS.md §6.8
   reserves `app.crash` with `cause = "Hang"` for F14's dedicated
   watchdog (multi-second stalls with a separate threshold). F10's
   `RunLoopObserverCapture` only emits when the
   `.afterWaiting → .beforeWaiting` span clears 50 ms — a long task
   on the dashboard, not a paging event for an on-call rotation.
   The 50 ms threshold matches PerformanceObserver's `longtask` API
   on the web and the same value used by the web SDK so the
   dashboards align.
5. **The captured stack is `Thread.callStackSymbols` at the
   `.beforeWaiting` tick.** It's the main thread's current frame, not
   the frame that was hot during the stall. A frame-accurate sample
   would require `task_threads` + symbol resolution off the main
   thread, which costs more than the metric itself. The truncation
   budget (`4 KiB`) drops trailing frames whole so we don't ship a
   mid-symbol fragment downstream.
6. **All three samplers gate behind the existing
   `EdgeRumConfig.captureRenderingPerformance` toggle.** Splitting
   into three per-signal flags would surface implementation detail to
   the host app. v1.0 ships them as one feature; if there's pressure
   to disable a single sampler the toggle can be split later without
   breaking the existing flag's documented contract (defaults stay
   `true`).

**Alternatives considered.**

- **Use MetricKit only.** `MXMetricPayload` arrives once per 24 h, so
  there's no real-time signal during the session. We deliberately
  pair the on-device sampler with a future MetricKit augmentation
  (deferred per PLAN-iOS §6.10) — the SDK ships both signals over
  time.
- **Per-tick emission for `frame_render_time` (no window).** Would
  multiply emit volume by 60–120× and produce a metric stream the
  backend can't dashboard usefully. Window aggregation is what every
  RUM SDK does for the same reason.
- **Reuse F14's hang `CFRunLoopObserver` for `long_task`.** F14's
  watchdog runs on a dedicated thread with a multi-second timeout;
  bolting a 50 ms threshold onto the same observer would double the
  emit volume on every short stall and complicate the F14
  `cause = "Hang"` filter. Two observers cost negligible CPU and keep
  the two signals' semantics independent.
- **Wall-clock `Date` instead of `mach_absolute_time` for the long-task
  span.** `Date` is subject to NTP adjustment and time-zone changes;
  `mach_absolute_time` is monotonic from boot. The conversion via
  `mach_timebase_info` is a single divide on every Apple platform.

**Consequences.**

- Three new files under `Sources/EdgeRumCapture/` —
  `FrameSampler.swift`, `MemorySampler.swift`,
  `RunLoopObserverCapture.swift`. No public types added; everything
  is `internal` (`public` on internal targets only to make
  the test bundle compile).
- `EdgeRum.start(_:)` gains a `captureRenderingPerformance`-gated
  block that calls `FrameSampler.install`, `MemorySampler.install`,
  and `RunLoopObserverCapture.install` in that order.
- Tests cover the pure aggregator (`FrameWindowAggregator`), the
  attribute-bag builders (`makeAttributes` on every sampler), and a
  real `Thread.sleep(forTimeInterval: 0.2)` integration test for the
  long-task path that drives the main runloop briefly to flush the
  observer (PLAN-iOS §F10/T10.3 acceptance verbatim). The wire
  contract test
  (`PerformanceMetricsWireConformanceTests`) pipes the canonical
  attribute bag for every metric through a real `Recorder` and
  asserts the envelope clears `WireAssertions`.
- `EdgeRum.disable()` halts emission via the same `Recorder.isEnabled`
  gate every other sampler uses. The display link pauses on
  `willResignActive` to save battery while suspended; the memory and
  long-task drivers stay armed (the runloop simply doesn't tick when
  the app is suspended, so they naturally idle).

---

## ADR-010 — F14 native crash payload: SDK-owned `crash.report_json` schema, sidecar identity override, top-30 stack truncation

**Status.** Accepted, F14 (v1.0).

**Context.** Native crashes — Mach signals and uncaught `NSException`s
— have to travel as a single `app.crash` event on the same JSON wire
the web and Android SDKs use. The wire contract forbids nested objects
inside `attributes` (CLAUDE.md "EdgeTelemetryProcessor contract"), but
a PLCrashReporter report is inherently nested: signal info, register
dumps, per-thread backtraces, and a binary-image table. We need a way
to ship the full report without violating the contract, and a stable
way to identify "the report sent by this SDK version" so the backend's
symbolication pipeline can route it deterministically. Separately:
PLAN-iOS §F14/T14.4 caps stack truncation at top-30 frames per thread,
but doesn't define the wire shape that carries the dropped tail.

**Decision.**

1. **Embed the full report as a single JSON-string attribute.** The
   encoder (`Sources/EdgeRumCrash/CrashReportEncoder.swift`) builds a
   Swift dictionary from the parsed `PLCrashReport`, serialises it via
   `JSONSerialization` with `[.sortedKeys]`, and assigns the string to
   `crash.report_json`. Backend re-parses on ingest. Round-trip is
   lossless for primitives — and the wire stays primitives-only.
2. **Stamp `crash.report_format_version = "edgerum.crash.v1"` on every
   `app.crash` event** at the *attribute* level AND inside
   `crash.report_json`. Bumps to the schema (adding fields, changing
   field semantics, dropping fields) MUST bump this version and add an
   ADR entry. The backend MAY validate the embedded JSON against the
   declared version.
3. **Replay event identity is the *crashed* session, not the live
   one.** `PLCrashIntegration.replayIfNeeded` reads
   `Library/Caches/edge-rum/last-session.json` (the F4 sidecar) and
   folds `session.id`, `session.start_time`, `session.sequence`,
   `device.id`, and `user.id` into the `app.crash` attribute bag
   *before* handing it to `Recorder.recordEvent`. The Recorder's
   `PayloadBuilder` uses event-wins merge semantics, so these override
   the live `ContextProvider` snapshot at flush time.
4. **Top-30 frames per thread, marker for the rest.** Frames beyond
   the cap are dropped from the per-thread `stack` array and replaced
   by a sibling `other_stacks = "…N more…"` string. The marker shape
   (`omissionPrefix = "…"`, `omissionSuffix = " more…"`) is part of
   the wire contract and is checked by
   `Tests/EdgeRumCrashTests/CrashStackTruncatorTests`.
5. **Event-size cap with deterministic strip order.** If the encoded
   event would exceed `eventSizeCapBytes` (default 200 KB), the
   encoder strips per-thread register dumps first; if still over,
   drops `binary_images`. Both are detectable on the backend (an
   `app.crash` event with `crash.report_json` but no registers / no
   images means the cap kicked in). Stacks are never truncated past
   the top-30 cap to satisfy the size budget — symbolication of the
   crashed thread's top frames matters more than register state.
6. **Mach exception handler.** `PLCrashReporterConfig` is constructed
   with `signalHandlerType: .mach` and
   `shouldRegisterUncaughtExceptionHandler: true`. The Mach path is
   PLCR's own recommendation and catches more crash classes than the
   BSD `sigaction(2)` path, at the cost of in-Simulator behaviour
   (Apple's debugger intercepts Mach exceptions before PLCR sees
   them). Manual QA of the crash sample app should happen on device.

**Alternatives considered.**

- **Multiple top-level attributes** (`crash.thread.0.stack`,
  `crash.thread.1.stack`, …). Pollutes the attribute namespace,
  doesn't bound payload size, and forces the backend to reassemble.
- **Base64 of the raw PLCR protobuf.** Opaque to anything except a
  symbolicator that already knows PLCR's binary format; impossible
  to debug in a JSON log viewer.
- **Drop the report entirely and ship only thread / register
  summaries.** Defeats the point — the backend needs the full image
  table for dSYM symbolication.
- **Wire `app.crash` with `cause = "NativeCrash"` UNDER the new
  session's identity** (post-rotation, post-replay). Counter-intuitive
  on dashboards: a crash dashboard segmented by session would show
  the crash under a session that started AFTER the crash, which means
  every crash count would be off-by-one against any other RUM SDK.

**Consequences.**

- Five new files under `Sources/EdgeRumCrash/` —
  `PLCrashIntegration.swift`, `PLCrashIntegrationConfig.swift`,
  `CrashReportEncoder.swift`, `CrashStackTruncator.swift`,
  `CrashSidecarReader.swift` — plus a test-only
  `CrashFixtureGenerator.swift` that wraps PLCR's
  `generateLiveReport()` so the encoder is unit-testable end-to-end
  on the macOS test slice.
- `EdgeRum.start(_:)` gains two `captureNativeCrashes`-gated blocks:
  `PLCrashIntegration.replayIfNeeded(...)` *before*
  `Recorder.shared.start(...)` (so the replayed event lands on the
  prior session) and `PLCrashIntegration.install(...)` *after* every
  other capture is wired.
- `PLCrashIntegration` and `PLCrashIntegrationConfig` are `public` on
  the internal `EdgeRumCrash` target — needed so the EdgeRum public
  module can call them, but they DO NOT appear in EdgeRum's exported
  symbol graph (the firewall check only scans EdgeRum). The
  `CrashReporter` framework remains `@_implementationOnly` so no
  PLCR type ever crosses the public module boundary.
- A new test target `EdgeRumCrashTests` covers encoder, truncator,
  sidecar reader, install idempotency, and replay end-to-end. Wire
  conformance lives alongside the rest in
  `Tests/EdgeRumContractTests/CrashWireConformanceTests.swift`.
- Backend ask (PLAN-iOS §13 "Backend asks" item 6 — the negotiated
  size cap): this ADR pins the soft cap at 200 KB. Tighten or relax
  in lockstep with backend telemetry.

---

## ADR-011 — F15 hang detection: hybrid CFRunLoopObserver heartbeat + Mach-based main-thread stack walk

**Date:** 2026-06-17

**Status:** Accepted.

**Context.** F15 adds main-thread hang detection. The watchdog must
record one `app.crash` event with `cause = "Hang"` when the host
app's main runloop stalls for longer than
`EdgeRumConfig.hangTimeout`. Two specification artefacts disagree on
sub-details:

1. **Attribute key for the captured stack.** PLAN-iOS.md §6.8 names
   it `hang.stack`; the §F15/T15.2 acceptance criterion calls for
   `crash.thread.main_stack`.
2. **Heartbeat source.** §6.8 prescribes a hybrid
   `CFRunLoopObserver` + dedicated `Thread`; T15.1 only mentions a
   dedicated `Thread` "sampling main-runloop heartbeat".

The main thread is, by definition, blocked when a hang fires, so a
plain `Thread.callStackSymbols` dispatched to main won't return. We
need to walk the stack of a *suspended* main thread from a
background scheduler, using public APIs only (T15.2 — no
`_pthread_*` private calls).

**Decision.**

1. **Use `crash.thread.main_stack`** (not `hang.stack`). This is the
   explicit T15.2 acceptance criterion, matches the existing
   `CrashReportEncoder` namespace (`Sources/EdgeRumCrash/
   CrashReportEncoder.swift` lines 73-94), and lets future crash +
   hang dashboards share a single column.
2. **Hybrid heartbeat.** A `CFRunLoopObserver` on
   `CFRunLoopGetMain()` (`.commonModes`,
   `.entry | .beforeWaiting | .afterWaiting | .exit`) bumps an
   atomic `UInt64` counter every time the main runloop turns. A
   dedicated `HangWatchdogThread` (`.userInitiated` QoS) polls the
   counter every 250 ms and fires the hang event when the counter
   has not advanced for `hangTimeout` consecutive seconds. Pure
   wall-clock sampling on its own can't distinguish "main is busy
   but advancing" from "main is stuck".
3. **Mach-based stack walk.** `MainThreadStackSnapshot.swift`
   captures the main thread's Mach port at install time via
   `pthread_mach_thread_np(pthread_self())` — a public, non-`_np`
   POSIX call that returns a port whose lifetime is bound to the
   pthread (no `mach_port_deallocate` needed). On detection the
   watchdog thread runs:

   `thread_suspend` → `thread_get_state` (ARM64 / x86_64) →
   frame-pointer chain walk via `vm_read_overwrite` (safe — invalid
   reads return `KERN_INVALID_ADDRESS` instead of trapping) → strip
   PAC bits with a 48-bit mask → `dladdr` symbolicate → `thread_resume`.

   Symbolication happens **after** resume so `dladdr` (which takes
   dyld's lock) can't deadlock against the suspended main thread.
   On any Mach failure, `capture()` returns `[]` and
   `HangEventEncoder` substitutes a single placeholder frame
   (`"<hang-stack-unavailable>"`) so the T15.2 "non-empty stack"
   acceptance criterion still holds.
4. **Threshold floor of 2 seconds.** Per PLAN-iOS.md §17 risk #5,
   sub-2 s thresholds cause false positives on iPhone 8 / SE 2
   hardware. `HangDetector.install(...)` clamps the host-supplied
   `hangTimeout` to `max(2.0, requested)`.
5. **No `Thread.callStackSymbols` from a dispatched main-thread
   block.** A dispatched block can't run until main is unstuck — by
   then the hang is already over and we'd be sampling the wrong
   stack. Rejected outright.
6. **MetricKit `MXHangDiagnostic` enrichment deferred.** §6.8
   mentions MetricKit as a 24-hour-delayed augmentation. The F15
   tasks (T15.1/T15.2) do not include it, and the daily MXMetric
   payload arrives long after the live hang event has shipped.
   Tracked as a v1.0+ follow-up.

**Alternatives considered.**

- **Plain `CADisplayLink` sampler.** Would only catch hangs longer
  than one display frame and would itself be paused if the main
  thread blocks for long enough — degrades exactly when we need
  detection most.
- **`backtrace(3)` from `execinfo.h`.** Walks the **current**
  thread, not an arbitrary thread. Useless for cross-thread main
  thread sampling.
- **Signal-based snapshot.** Send a signal to the main thread,
  capture stack in the handler. Async-signal-safe but the signal
  handler can't run if main is fully blocked inside a kernel call,
  and signal delivery on suspended threads is undefined.
- **Use `KSCrash` / `SentrySDK` source directly.** Adds a
  dependency we already chose not to take in F14.

**Consequences.**

- Three new files under `Sources/EdgeRumCrash/` —
  `HangDetector.swift` (orchestrator + watchdog state machine),
  `HangEventEncoder.swift` (pure attribute-bag encoder), and
  `MainThreadStackSnapshot.swift` (Mach-based stack walker).
- `EdgeRum.start(_:)` gains one `enableHangDetection`-gated block
  that calls `HangDetector.install(threshold:debug:)` immediately
  after the F14 `PLCrashIntegration.install(...)`. `EdgeRum.disable()`
  calls `HangDetector.uninstall()` so a paused SDK has no live
  timers.
- Wire shape: `cause = "Hang"`, `runtime = "native"`,
  `crash.fatal = false` (distinct from native crash's
  `crash.fatal = true`), plus `hang.duration_ms`,
  `hang.threshold_ms`, optional `hang.cpu_usage`, and
  `crash.thread.main_stack`.
- A 5th test file lands in `Tests/EdgeRumCrashTests/`
  (`HangDetectorInstallTests`, `HangDetectorDetectionTests`,
  `HangEventEncoderTests`, `MainThreadStackSnapshotTests`) plus a
  contract test in `Tests/EdgeRumContractTests/
  HangWireConformanceTests.swift`. Detection tests drive the
  watchdog state machine directly with a `FixedClock` rather than
  blocking the test runner's main thread for real seconds, so the
  suite stays fast and deterministic.
- Backend ask (PLAN-iOS §13 "Backend asks" — new): confirm crash
  dashboards do not double-count `cause = "Hang"` rows as fatal
  crashes. Backend should segment by `cause` (the two ride under
  the same `eventName = "app.crash"`).

## ADR-012 — F16 context-enrichment observers live in `EdgeRumCore`, not `EdgeRumCapture`

**Date:** 2026-06-17

**Status:** Accepted.

**Context.** F16 adds 16 new identity attributes (`device.thermal_state`,
`device.low_power_mode`, the five `device.*` accessibility flags,
`device.locale`/`timezone`/`timezone_offset_min`,
`device.disk_free_mb`/`disk_total_mb`, `app.background_refresh`, and
`network.expensive`/`constrained`/`interface`). Three new context
structs (`PowerContext`, `AccessibilityContext`, `StorageContext`)
join the existing identity groups merged by `ContextProvider`.

Each new attribute must be refreshed when its underlying source
changes — `ProcessInfo` thermal/power state notifications,
`UIAccessibility.*DidChangeNotification` toggles, `NSLocale`'s region
change, and a periodic disk-capacity poll. Two homes for those
observers were viable:

1. `Sources/EdgeRumCapture/ContextObservers.swift` — alongside the
   existing F11 `LifecycleCapture` / `NetworkPathCapture` swizzles
   and notification hooks.
2. `Sources/EdgeRumCore/Context/ContextObservers.swift` — alongside
   the snapshots they refresh.

**Decision.** Land `ContextObservers.swift` in `EdgeRumCore`.

**Rationale.**

1. The observers neither swizzle anything nor emit any events. Their
   single side-effect is `ContextProvider.refresh*(_:)`. Capture
   modules touch the public-event pipeline; these observers do not.
2. Keeping the observers next to the structs they refresh shortens
   the cognitive distance between "where the attribute is defined"
   and "where it is refreshed". A future contributor extending
   `AccessibilityContext` reads exactly two files.
3. `EdgeRumCapture` already depends on `EdgeRumCore`, not the other
   way around. Putting the observers in `Core` keeps the dependency
   graph one-directional and lets `EdgeRumCore`'s own tests exercise
   the install path without pulling in `EdgeRumCapture` as a test
   dep.
4. The `LifecycleCapture` install pattern (os_unfair_lock-guarded
   `_installed` flag + token array + `#if DEBUG` reset helper) is
   copied verbatim — there's no novel mechanism in this file, only a
   different home.

**Implementation notes.**

- Always-on per `EdgeRumConfig` consensus; no new public toggle. The
  attributes ride alongside existing identity keys (battery, screen,
  network type) which are also unconditional.
- Storage refresh uses `DispatchSource.makeTimerSource(queue:)` with
  a 5-minute schedule mirroring `MemorySampler.swift:240`. Suspend
  on `willResignActive`, resume on `didBecomeActive` so we don't run
  `statfs` while the app is backgrounded.
- Wire keys snake_case (`device.thermal_state`, `device.low_power_mode`,
  `device.timezone_offset_min`) to match the pre-existing
  `app.package_name` / `session.start_time` convention rather than
  the camelCase `device.screenWidth` legacy.

**Consequences.**

- Five new files under `Sources/EdgeRumCore/Context/` —
  `PowerContext.swift`, `AccessibilityContext.swift`,
  `StorageContext.swift`, `ContextObservers.swift`, plus extensions
  to `DeviceContext.swift` and `NetworkContext.swift`.
- `ContextProvider` gains three stored properties + three refresh
  hooks + three read accessors. Existing tests that pass partial
  `init(...)` arguments still compile because every new parameter
  defaults to an empty struct.
- `Recorder` gains one public computed property,
  `currentContextProvider`, so `EdgeRum.start(_:)` can pass the live
  provider to `ContextObservers.install(provider:debug:)` without
  threading it through the `Recording` protocol (which would force
  every existing test probe to adopt the new requirement).
- Six new test files under `Tests/EdgeRumTests/` plus one
  `F16ContextEnrichmentConformanceTests.swift` in the contract
  suite. Adds ~25 test cases; full suite stays at <6 s wall-clock.
- No new `eventName`. No transport change. No public-surface change
  visible to consumers — the attributes appear automatically on
  every event emitted after `EdgeRum.start(_:)` is called.
- Pre-existing test isolation bug surfaced: `NetworkPathCaptureTests`
  had no `setUp` reset, and earlier tests (e.g. `EdgeRumAPITests`
  via `EdgeRum.start → NetworkPathCapture.install`) left a stale
  `lastFingerprint`. F16 adds a `setUp` reset to that class
  symmetrically with its `tearDown`.
