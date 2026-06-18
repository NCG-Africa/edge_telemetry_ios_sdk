# Versioning and stability

What the SDK considers a breaking change, how deprecations work, and
the minimum-iOS commitment.

## Overview

EdgeRum follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
literally — major / minor / patch carry the exact meanings the spec
ascribes to them. A minor or patch release never breaks an integration
that compiled clean against the previous version.

## Versioning rules

- **Public API additions** — minor. A new method on ``EdgeRum``, a new
  field on ``EdgeRumConfig``, a new SwiftUI modifier; all of these
  ship as minor bumps.
- **Public API removals or signature changes** — major. We never
  silently remove or repurpose a public symbol.
- **Wire-format-affecting changes** — major, coordinated with the
  backend. The wire envelope (`telemetry_batch`, ISO 8601 timestamps,
  flat-primitive attributes, `eventName` allowlist) is part of the
  public contract, even though no Swift type changes.
- **Bug fixes that change observable behaviour** are called out in
  [`CHANGELOG.md`](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/blob/main/CHANGELOG.md)
  under a *Behaviour changes* sub-heading. They do not by themselves
  trigger a major bump unless they violate the wire contract.

## Minimum-iOS commitment

> Minimum-iOS bumps are major.

A consumer on iOS 14 will never wake up to a minor version that won't
compile or run. iOS floor bumps are major releases; they are announced
in the previous major's CHANGELOG release notes and again in the new
major's migration guide.

The current floor is iOS 14.0; see [`Tools/check-supported-ios.sh`](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/blob/main/Tools/check-supported-ios.sh)
for the consistency check that enforces it across `Package.swift`,
`EdgeRum.podspec`, `PLAN-iOS.md`, and the README.

## Deprecation policy

Public symbols slated for removal go through a one-minor-cycle
deprecation window (~three months in practice). The pattern:

1. The symbol is annotated `@available(*, deprecated, renamed: "…")`
   or `@available(*, deprecated, message: "…")` in a minor release.
2. The next major release removes the symbol.

Consumers see a compile-time warning during the deprecation window so
the upgrade path is visible from Xcode without reading release notes.

## Migration guides

Every major has a dedicated migration document at
`docs/migration/v{OLD}-to-v{NEW}.md` based on
[`docs/migration/TEMPLATE.md`](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/blob/main/docs/migration/TEMPLATE.md).
The template covers what's changing, why, wire-format impact, public
API diff, auto-mappable changes, manual changes needed, and minimum
iOS impact.

The v1 alpha ships no migration document because there is no prior
major to migrate from. The template stays in the repo as the muscle-
memory anchor for the next major.
