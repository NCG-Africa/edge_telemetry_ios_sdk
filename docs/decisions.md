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
