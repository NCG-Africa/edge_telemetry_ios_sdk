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
