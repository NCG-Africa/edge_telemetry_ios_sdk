# Trace v3 — swizzled task-creation family: coverage audit

**Ticket:** T10 (#163) · **Map:** #153 · **Date:** 2026-09-15
**SDK read at:** `896b406` (`docs/trace-v3-path-audit` branch tip; `Sources/` unchanged since `b90a869`)

## How this was produced

Unlike T3 (#156), which was a static read, **every row below marked "measured" was run.**
Nine standalone Swift programs against Darwin Foundation (Swift 6.2.3, macOS 26.6.2 /
`arm64-apple-macosx26.0`, Xcode 26.2 SDK) plus a local HTTP echo server, reproducing
`EdgeRumURLProtocol.startLoading()`'s exact shape (`HTTPCapture.swift:713-735`:
`mutableCopy` → mark processed → ephemeral config with our class stripped → re-issue as
a `dataTask`).

**Platform caveat, stated once and applying to every measured row.** These ran on macOS,
not on an iOS device. The Swift concurrency overlay, `URLProtocol`, and CFNetwork are the
same Darwin implementation on both, so the selector-routing and body-preservation results
carry across with high confidence. Two rows do **not**: WKWebView's process model and
background-session daemon handoff differ materially on iOS, and both are called out
in place. Nothing here is an Instruments measurement — no allocation or latency numbers
are claimed.

---

## Verdict table

| # | Call-site class | Reached by T1's capture point? | `traceparent.outcome` today | Evidence |
|---|---|---|---|---|
| 1 | `URLSession.data(for:)` / `data(from:)` / `upload(for:from:)` / `download(for:)` / `bytes(for:)` — **async/await** | **NO** as T1 enumerated it — **YES** after the amendment in §1 | `injected_unwired` on every async request | measured |
| 2 | Legacy closure/`resume()` API (`dataTask(with:)`, `uploadTask`, `downloadTask`, all overloads) | **YES** | `injected_attributed` / `injected_unattributed` | measured |
| 3 | `background` configurations | **YES at the capture point, NO at the recording layer** | *no outcome at all* — header on the wire, **no client span** | measured |
| 4 | `WKWebView` | **NO** — no in-process `URLSession` task exists | nothing emitted | measured (creation swizzle: 0 hits) |
| 5 | Third-party on `URLSession` (Alamofire, Apollo, GTMSessionFetcher, RN `RCTNetworking`) | **YES** | as row 2 | mechanism |
| 6 | Third-party off `URLSession` (Flutter `dart:io`, gRPC-Swift/NIO, Cronet, raw `CFNetwork`) | **NO** | nothing emitted | mechanism |
| 7 | Requests issued before `EdgeRum.start()` | **NO** (not yet installed) | nothing emitted | mechanism |
| 8 | Sessions **created** before `EdgeRum.start()`, requests issued after | **YES at the capture point, NO at the recording layer** | same as row 3 — header on the wire, **no client span** | measured |

---

## 1. async/await — the re-open trigger, and why it resolves to an amendment

**Measured.** Swizzling the entire public creation family and calling each async API:

```
async data(for:)              -> *** NO SWIZZLE HIT ***
async data(from:)             -> *** NO SWIZZLE HIT ***
async upload(for:from:)       -> *** NO SWIZZLE HIT ***
async download(for:)          -> *** NO SWIZZLE HIT ***
async bytes(for:)             -> *** NO SWIZZLE HIT ***
legacy dataTask(with:Request) -> dataTaskWithRequest:completionHandler:
```

The async overlay does **not** build on the public selectors. It dispatches to a
**parallel private family** that carries the per-task delegate the async API supports
(`class_copyMethodList` on `URLSession` lists all of them). Measured routing:

| Async API | Selector actually sent |
|---|---|
| `data(for:)` | `_dataTaskWithRequest:delegate:completionHandler:` |
| `data(from:)` | `_dataTaskWithURL:delegate:completionHandler:` |
| `upload(for:from:)` | `_uploadTaskWithRequest:fromData:delegate:completionHandler:` |
| `download(for:)` | `_downloadTaskWithRequest:delegate:completionHandler:` |
| `bytes(for:)` | `_dataTaskWithRequest:delegate:` |

The two families are **disjoint, not layered**: swizzling the public selectors logged
nothing for async calls, and the legacy calls logged only the public selector — neither
funnels into the other. So T1 as written puts **100 % of async/await traffic into
`injected_unwired`**, which is the ticket's stated re-open trigger.

It resolves to an **amendment, not a re-open.** T1's *mechanism* — instance-swizzle the
task-creation family, capture on the caller's thread — is exactly right and unharmed. Its
*enumeration* was incomplete: the family is **ten** selectors, not five.

**Do not hardcode the private selector strings.** Discover them at install time by
enumerating `class_copyMethodList(URLSession.self)` and matching
`^_(data|upload|download)TaskWith.*[Dd]elegate:` — which keeps no private-API literal in
the binary, and survives a rename. Rules that follow:

- Missing selector must **degrade, never trap**: `class_getInstanceMethod` returning `nil`
  means that arm is uninstrumented, not a crash.
- Every arm is a pure pass-through; the per-task `delegate` argument is forwarded untouched.
- Coverage must be **observable**: if the private family resolves to zero matches on some
  future OS, async traffic silently reverts to `injected_unwired`. The install result
  needs to say how many arms it bound.

**Residual risk (unverifiable here):** these selectors could not be checked on iOS 15/16/17
— no device, no older SDK. Runtime discovery plus the degradation rule contains it; a
device pass on the minimum supported iOS is the remaining confirmation.

## 2. `background` configurations — a new failure class

**Measured, two independent runs.** The task-creation swizzle **does** fire for a background
session (`downloadTaskWithRequest:`). `URLProtocol` **never** does: with
`bcfg.protocolClasses = [ReproProtocol.self]` explicitly set and the property reading back
as set, `startLoading` was never called, while the request still reached the server.

With T1's capture point installed, a background request therefore gets a **`traceparent`
header injected and a bag stamped, and then nothing is ever recorded** — the backend sees a
server span whose parent span id was never emitted by any client. That is a **dangling
parent**: strictly worse than a coverage hole, because a hole is visible as
`injected_unwired` and this is invisible.

This is **not** in the outcome enum, and per the map's fidelity rule it must not be — adding
a member diverges from Android's frozen contract. The fix is to **not inject**, which keeps
the wire clean and needs no new vocabulary:

> **Skip injection when `session.configuration.identifier != nil`.**

Measured discriminator: `.default` → `nil`, `.ephemeral` → `nil`, `.background(withIdentifier: "x")`
→ `"x"`. It is public API and reachable from the swizzled instance method via `self`.
The request then carries no header, and the outcome is honest absence.

`HTTPCapture.swift:14-16` already declines to instrument background configs, for the
metrics reason. This extends that exclusion to injection — same decision, one layer up.

## 3. Sessions created before `EdgeRum.start()` — the same failure class, second door

**Measured.** `URLSession` **snapshots** its configuration at creation: mutating
`cfg.protocolClasses` after the session exists has no effect (protocol not consulted), while
setting it before creation does. Separately, a class-wide creation swizzle installed *after*
a session exists **still fires** for that session's later tasks.

Combining the two: the `protocolClasses` **getter** swizzle (`HTTPCapture.swift:842-880`)
can only reach configurations read after install, so any session the host built before
`EdgeRum.start()` is permanently outside the recording layer — but T1's creation swizzle
reaches it retroactively and will inject into it. Identical dangling-parent outcome to row 3,
reached by a different door.

The guard must therefore be **positive, not identifier-only**: inject only when this
session's loading path actually includes `EdgeRumURLProtocol`, i.e. check
`session.configuration.protocolClasses` contains our class (covers both doors, and the
identifier check becomes a subset). This costs one array scan at the capture point.

Worth noting on the upside: T1's swizzle being retroactive **fixes** an ordering hole the
current getter-swizzle design has — once the positive guard is in, a pre-existing session
that *does* carry the protocol is fully covered.

Requests *issued* before `EdgeRum.start()` are simply unreachable by any mechanism. The
window is the host-controlled prefix of `application(_:didFinishLaunchingWithOptions:)`
before the `start(...)` call; it emits nothing, which is honest, and it is the host's to
shrink.

## 4. WKWebView

**Measured:** loading a page in a `WKWebView` produced **zero** `URLSession` task-creation
swizzle hits. No in-process task exists, so the capture point cannot see it, cannot inject,
and cannot attribute — irrespective of anything the `URLProtocol` layer does.

(On macOS the registered `URLProtocol`'s `canInit` *was* consulted for the main-frame load.
Do not carry that to iOS: WKWebView networking runs in a separate process there and
`URLProtocol` is well known not to be consulted. Either way it changes nothing — the capture
point is the thing T1 decided, and it is definitively unreached.)

**Cost in coverage terms:** for a native app with an embedded web view, in-page XHR/fetch is
invisible to trace v3. For a webview-shell app, *all* of it is. The root still mints (the tap
that opened the view is a T6 root) — there are simply no child spans under it. This is a
known ceiling, not a defect to fix inside this map.

## 5. Third-party stacks

Anything that ultimately calls `URLSession`'s task-creation family is reached by
construction — **Alamofire**, **Apollo**, **GTMSessionFetcher** (Firebase), and React
Native's `RCTNetworking` all do.

Not reached, because they never create a `URLSession` task:

- **Flutter** — `dart:io` `HttpClient` runs on Dart's own socket stack. A Flutter host app
  emits **no HTTP spans at all** from this SDK.
- **gRPC-Swift** — SwiftNIO, raw sockets.
- **Cronet** / embedded Chromium net stacks.
- Anything on raw `CFNetwork` / `Network.framework`.

A large host app realistically ships Alamofire or plain `URLSession` plus a Firebase SDK —
all reached. The one that actually bites is **Flutter**, and it fails silently rather than
as `injected_unwired`, for the same reason as §2: nothing is created, so nothing marks itself.

## 6. D9 — **refuted**

T3 flagged (`trace-v3-path-audit.md:39`, *UNVERIFIED, needs a device*) that because
`startLoading` always re-issues as a `dataTask`, `uploadTask(withStreamedRequest:)` bodies
might not survive the `URLProtocol` hop — "stream uploads are **corrupted**, not merely
mis-measured".

**Measured, against a body-counting server, through a faithful repro of `startLoading`:**

| Case | At the protocol layer | Arrived at server |
|---|---|---|
| `uploadTask(withStreamedRequest:)`, 5000 B stream | `httpBodyStream=true`, `httpBody=nil` | **5000 B**, `Transfer-Encoding: chunked` ✅ |
| `uploadTask(with:from:)`, 3000 B `Data` | `httpBodyStream=true` (Foundation converted it) | **3000 B**, `Content-Length: 3000` ✅ |
| `downloadTask(with:)` through the protocol | intercepted | caller still received a **file URL with correct contents** ✅ |

The `mutableCopy()` at `:715` carries `httpBodyStream` across, and the re-issued `dataTask`
transmits it. **No corruption.** D9's high-severity half is closed.

D9's other half — O5, a `downloadTask` being serviced through an in-memory buffer
(`receivedData` accumulating at `HTTPCapture.swift:752`, handed over at `:771`) — **stands as
a mechanism**: the caller's contract is honoured, but a large download is materialised in RAM
inside the protocol before being written out. It is an overhead row, not a correctness row,
and it belongs to the audit, not to this map's spec.

## 7. Correction to T4 (#157): `URLProtocol.task` is the **outer** task

T4 recorded that T3's "associated object on the task" suggestion was *unreachable*, because
"the capture point holds the outer task, `EdgeRumURLProtocol` only ever sees the inner one"
— D4 restated.

**That premise is wrong, and measured to be wrong.** Inside `startLoading`, `self.task` is
the **caller's** task:

```
outer uploadTask id=1, taskDescription="OUTER-MARK"
[protocol] URLProtocol.task = id:1 desc:OUTER-MARK class:__NSCFLocalUploadTask
```

Foundation constructs the protocol via `initWithTask:` and consults **`+canInitWithTask:`**,
not `+canInitWithRequest:`, whenever a `URLSession` task exists — verified directly: with
both overridden, only the task form was ever called.

**This does not change T4's decision.** The `URLProtocol` property bag is still the better
hand-off (dies with the request, no stash, no eviction, presence *is* the marker). What
changes is the *reason*, and one downstream consequence:

- **D4 is fixable and self-exclusion is no longer single-mechanism.** The protocol layer can
  read the outer task's `taskDescription`. Measured: a task whose description is set *after*
  creation and before `resume()` — exactly `BatchTransport.swift:136`, with `resume()` at
  `:137` — reads back as `"edge-rum-internal"` at `canInit(with task:)` time. Overriding
  `canInit(with task:)` and passing `task.taskDescription` into
  `HTTPCapture.shouldCaptureRequest` restores defence check #2, which `:699-702` currently
  passes as `nil` with a comment stating it is unavailable at this layer. **That comment is
  incorrect.**
- T4's note to #162 — "self-exclusion is single-mechanism, resting on `X-Edge-Rum-Internal`
  alone" — should be revised: it is single-mechanism *at the capture point* (where the
  description genuinely is not yet set) and **recoverable at the protocol layer**.
- The inner-task read at `:776` (`dataTask?.taskDescription`) is still always `nil`. D4 as a
  *defect* is confirmed; D4 as a *dead end* is not.

---

## What this obliges

1. **T1 (#154) amendment** — the family is ten selectors; discover the private arm by runtime
   enumeration; degrade, don't trap; report bound-arm count. *Not* a re-open.
2. **New guard at the capture point** — inject only when this session's `protocolClasses`
   include `EdgeRumURLProtocol`. Closes the dangling-parent hazard from background configs
   **and** from pre-`start()` sessions, with no new outcome-enum member.
3. **#162** — carries §1's degradation rule, §2/§3's guard, §7's `canInit(with task:)` fix,
   and the revised self-exclusion note.
4. **#161** — **nothing to file.** No new attribute, no new enum member, no new
   `trace.root_type`. Every finding here is either a coverage fact or an injection guard;
   the wire is unchanged.
5. **Known ceilings, documented not fixed** — WKWebView, and non-`URLSession` stacks
   (Flutter most consequentially). Both fail as silence rather than as `injected_unwired`.

## Reproduction

The nine programs are throwaway; the shapes that matter are described inline above and each
is a ~40-line `swiftc` single file plus a body-counting `http.server`. Re-running them on a
device is the only outstanding confirmation, and only for §1's older-iOS question and §2's
background-daemon handoff.
