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
