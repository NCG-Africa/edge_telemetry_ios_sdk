# Migrating from EdgeRum v{OLD_MAJOR} to v{NEW_MAJOR}

> Replace `{OLD_MAJOR}` and `{NEW_MAJOR}` with the actual major versions
> when copying this template to `docs/migration/v{OLD_MAJOR}-to-v{NEW_MAJOR}.md`.

A short paragraph summarising the spirit of the migration: what motivated it,
who it primarily affects, and roughly how much code an integrator will need to
touch. Keep it honest — if the upgrade is invasive, say so.

---

## What's changing

The full list of behaviour changes, public API changes, and wire-format
changes shipped under this major. Group them by surface (public Swift API,
auto-capture defaults, wire payload, dependency floors). Each row should be
one short sentence.

---

## Why

Why each batch of changes is in this major. One paragraph per substantive
shift. Anchor each "why" to the constraint that drove it — backend contract,
App Store policy, performance budget, a concrete bug — so future readers
understand the load-bearing reason and don't try to revert it casually.

---

## Wire format impact

State **Yes** or **No**, then a short justification.

If **Yes**: list every changed event name, attribute key, or envelope field,
and call out the order in which the backend rollout must happen.

If **No**: confirm that consumers on v{NEW_MAJOR} produce payloads that the
existing backend accepts unchanged.

---

## Public API diff

Before / after Swift snippets per changed symbol. Cover renames, removed
overloads, signature changes, new required arguments, and any breaking
default changes.

```swift
// Before — v{OLD_MAJOR}
EdgeRum.track("checkout_started", attributes: ["cart.size": 3])

// After — v{NEW_MAJOR}
EdgeRum.track("checkout_started", attributes: ["cart.size": 3])
```

If you ship a Swift codemod for any of the above, link to it here and in
the "Auto-mappable changes" section below.

---

## Auto-mappable changes

Changes a tool can apply mechanically — renames, simple argument
reorderings, `@available(*, deprecated, renamed:)` redirects, codemod
patterns. Mention whether the migration tool is shipped with the SDK,
runs via Xcode "Fix-It", or is a one-shot script.

---

## Manual changes needed

Changes that require a human to read code and decide:

- Behaviour changes whose impact depends on what the host app does.
- New configuration knobs that ship with a sensible default but the team
  may want to flip.
- Tests that may need to be updated when expected payload shapes change.

---

## Minimum iOS impact

`Minimum iOS bumps are major.` (PLAN-iOS.md §12.6, README §Versioning.)

State the previous floor, the new floor, and any iOS version-specific code
the host app now needs to drop `@available` guards from or wrap with one.

If the floor did not change, write: *No iOS floor change in v{NEW_MAJOR}.*
