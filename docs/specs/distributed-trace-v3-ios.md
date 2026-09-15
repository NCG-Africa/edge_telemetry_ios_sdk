# Distributed trace v3 — iOS implementation spec

**Status:** frozen. Destination artifact of wayfinder map
[#153](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/153) (T9, #162).
Every decision here was resolved on a ticket; §18 maps each section back to the
ticket that owns its detail. Where this document and a ticket disagree, **this
document wins** — several ticket premises were corrected by later tickets.

**Audited against:** `b90a869` (`main`). Every `file:line` below was verified at
that commit. The backend half is live at `EDGETELEMETRYPROCESSORGO@2874607`.

**Fidelity rule for the whole spec:** *wire-identical, mechanism free.*
Attribute names, `traceparent.outcome` members, and `trace.root_type` values are
frozen to Android's contract (`edge_telemetry_android` →
`docs/specs/backend-wire-contract.md` @ `297757c`). Divergence on the wire is a
defect. *How* iOS produces them is an iOS call, and this spec makes it.

Read §15 (**Prohibitions**) before writing code. Three of its entries fail
**silently** on both sides of the wire, and two of them look like hardening.

---

## 1. The model

Spans are **attributes on events that already exist**. There is no span emitter,
no new event type, no new transport, and no new table.

| Attribute | Type / width | Meaning |
|---|---|---|
| `trace.id` | 32 lowercase hex | The trace. Generated at root mint. |
| `span.id` | 16 lowercase hex | This span. On a root, equals `rum.action.id`. |
| `parent.span.id` | 16 lowercase hex | Parent span. **Absent** on roots and on adopted spans. |
| `rum.action.id` | 16 lowercase hex | The root's `span.id`, denormalized onto every span in the trace. |
| `trace.root_type` | `VARCHAR(16)` | `launch \| interaction \| navigation \| resume \| request`. Denormalized onto every span. |
| `span.start_time` | **ISO-8601 ms UTC string** | Span start. See §3.2 — **never a number**. |
| `span.duration_ms` | double | Child spans only. Roots carry **none**; their envelope is derived server-side. |
| `traceparent.outcome` | string enum | §10. Six values. On `http.request` only. |

Zero trace code exists today — `grep -rE 'traceparent|trace\.id|span|TaskLocal|rum_action|root_type' Sources` returns nothing. All of this is new surface.

**Wire header:** W3C `traceparent`, `00-<trace.id>-<span.id>-<flags>`, where
`<flags>` is `01` when the session is sampled and `00` when it is not (§8.3).
`tracestate` is not emitted.

**Id generation:** 16 cryptographically-random bytes for a trace id, 8 for a span
id, rendered lowercase hex, never all-zero. A root generates both at mint;
`rum.action.id` is a copy of the root's `span.id`, not a third id.

---

## 2. The two references

Two stores, deliberately distinct. Conflating them breaks the guard test in §14.1.

```
mint(root) {
    carrier.store(root)          // ambient root — expires, os_unfair_lock
    lastRoot.store(root.ids)     // annotation ref — never expires, lock-free
}
```

### 2.1 The carrier — what a request may claim

One **process-global ambient root**: `nonisolated(unsafe) static` guarded by an
`os_unfair_lock`. This is the storage idiom already in the codebase
(`PageLoadCapture.swift:64-79`, `InteractionCapture.swift:88-92`,
`HTTPCapture.swift:113-132`) — nothing new is introduced.

Not a thread-local, not `@TaskLocal`, and not a layered read of either. Roots
mint on the **main** thread; requests are issued from background queues, so a
thread-scoped carrier is null at most real capture points and `@TaskLocal` is
null across every GCD hop and every non-async call site.

**What makes an ambient global correct is expiry, not thread scoping.** §5 is a
hard dependency: without it the carrier attributes forever and is worse than
useless.

Lookup is three-valued and **lazy** — expiry is judged at read, and an expired
read returns `.expired` rather than clearing the slot:

```swift
enum RootLookup {
    case live(Root)   // → injected_attributed
    case expired      // → injected_expired      (a root existed and aged out)
    case empty        // → injected_unattributed (no root ever, or already overwritten)
}
```

The next mint overwrites the slot regardless of state (last-writer-wins).

### 2.2 `lastRoot` — what a crash may name

A **second** reference: the last root's `trace.id` + `rum.action.id`,
**non-expiring**, written through at every mint, read only by the crash
annotation path (§12).

iOS does not need a second store for *reachability* (unlike Android, whose
carrier was `ThreadLocal`) — it needs it for **lifetime**. Reading the expiring
carrier would annotate NULL for any hang following 2 s of idle, which is most
hangs, and hangs are where the annotation is worth the most.

**Lock-free is load-bearing, not an optimisation.** If the main thread hangs
*inside* the §7.1 split swizzle while holding the carrier's `os_unfair_lock`, a
watchdog read of that lock blocks forever with no timeout — killing the hang
event in exactly the case hang detection exists for. A separate lock-free store
makes that unreachable by construction.

**Implementation constraint:** `trace.id` + `rum.action.id` exceed one atomic
word, and a torn read fabricates a trace id that never existed — strictly worse
than NULL, because the backend will happily join on it. Publication must be
tear-free **without** a blocking lock. A seqlock (one `UInt64` version counter;
the reader retries and never blocks) preserves the property that justified this
store over the carrier. Any primitive with the same two properties is acceptable.

There is **no async-signal-safety constraint**. PLCrashReporter owns the signal
handler (`PLCrashIntegration.swift:195-197`); every line of our crash code runs
on the *next* launch, in a different process, at `:151`.

---

## 3. Time

### 3.1 The monotonic clock (expiry)

`clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)` — returns `UInt64` nanoseconds
directly, so **no `mach_timebase` conversion** (unlike the existing conversion at
`RunLoopObserverCapture.swift:143-150, 213-216`).

**On Darwin this clock is sleep-*inclusive*** — the inverse of Linux, and the
`elapsedRealtime()` analogue Android's expiry is defined over.
`CLOCK_UPTIME_RAW` / `mach_absolute_time()` / `ProcessInfo.systemUptime` are the
ones that *stop* during sleep and are the wrong clock for a lifetime budget.
`mach_continuous_time()` is the same clock as the chosen one; it is rejected only
because it yields raw ticks and drags the timebase conversion back in.

Because the clock ages through suspension, **no background hook is needed** — a
root minted before a background transition is already expired on return.

**Injection seam** — a plain closure on the root store. `Clock`
(`Sources/EdgeRumCore/Clock.swift:18-20`) is **not** touched:

```swift
// ponytail: closure, not a protocol — one implementation plus a test stub
// doesn't earn an interface. Promote if a 2nd consumer appears.
var uptimeNanos: () -> UInt64 = { clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) }
```

Widening `Clock` would hand a capability to its six consumers
(`Recorder.swift:95`, `Recording.swift:49`, `SessionContext.swift:75`,
`IdentityProvider.swift:48`, `RumTimer.swift:31`, `HangDetector.swift:122,257`)
that none of them use. The decisive argument is testability, not blast radius:
**the two time axes must move independently** — device sleep advances uptime
while `Date` tracks it, and an NTP correction jumps `Date` while uptime does not.
A single `FixedClock.advance(by:)` can express neither.

### 3.2 Wall-clock time (the wire)

`span.start_time` is **ISO-8601 millisecond UTC**, produced by
`WireDateFormatter` (`Sources/EdgeRumCore/EventEnvelope.swift:102-105`,
`ISO8601DateFormatter` with `[.withInternetDateTime, .withFractionalSeconds]`),
exactly like every other timestamp the SDK emits — `Event.encode` routes both the
event and the metric arm through it (`:80, :87`).

Two resolved tickets describe `span.start_time` as "an absolute epoch timestamp".
That is true of the **bag** (§9), which never reaches the wire, and **false of the
wire**. See the prohibition in §15.1 — this is a silent failure on both sides.

---

## 4. Roots

| `trace.root_type` | Minting site | Condition | `span.start_time` anchor | Expiry | Carrying event |
|---|---|---|---|---|---|
| `launch` | `Sources/EdgeRum/EdgeRum.swift`, between `:189` and `:245` | `applicationState != .background` | `kinfo_proc.p_starttime`; `launchStart` when prewarmed | **Exempt** until first frame or background (§4.1) | `page_load` (`PageLoadCapture.swift:224`) |
| `interaction` | `InteractionCapture.swift:319-323`, **before** calling through | at least one ended touch in the event | mint instant | standard | `user.interaction` (`:180`) — **dropped** on a secure-field tap |
| `navigation` | `UIViewControllerCapture.swift:382-386` and `ViewModifiers.swift:41-54` | carrier `.empty` or `.expired` | mint instant | standard | `navigation` (`UIViewControllerCapture.swift:309`) |
| `resume` | `LifecycleCapture.swift:164-171`, **before** `emit(state: "foregrounded")` | carrier `.empty` or `.expired` | resume instant | standard | `app_lifecycle` foregrounded (`:121`) |
| `request` | — | **iOS never mints one** (§4.6) | — | — | — |

**Rule: every root has a minting site and a carrying event holding its ids.** The
single deliberate exception is the secure-field tap (§4.2), justified by PII
rather than convenience. A future root type inherits this rule.

A carrying event carries `trace.id`, `span.id`, `rum.action.id`,
`trace.root_type` and `span.start_time`; `parent.span.id` and `span.duration_ms`
are **absent** (roots derive their envelope server-side). This harmonises the one
inconsistency T8 left open — `page_load` carried `span.id` and `app_lifecycle` did
not. Carrying `span.id` on both is additive and costs nothing: on a root it equals
`rum.action.id`, and the envelope view groups on `rum_action_id` regardless.

### 4.1 `launch`

**Two clock domains, held apart, never converted.**

- **Wire:** `span.start_time` = `kinfo_proc.p_starttime`, read once via
  `sysctl(KERN_PROC_PID)`. Already wall-clock, so it renders through
  `WireDateFormatter` like everything else. No `sysctl` / `kinfo_proc` call exists
  anywhere in `Sources/` today — this is new surface, one call, once per process.
- **Expiry:** a *fresh* `CLOCK_MONOTONIC_RAW` reading at mint, via §3.1's closure.

Converting between them (`mono_now - (wall_now - p_starttime)`) is sound only if
no NTP correction landed since fork — precisely the hazard §3.1 chose that clock
to dodge. A backwards correction during a 3 s launch would make the root appear
already-expired at mint.

**Consequence, stated so it is not rediscovered:** the fork→init gap is visible as
span duration but is **never charged against any expiry budget**. That asymmetry
is correct — the gap is real elapsed time the user waited, but it is time the SDK
was not alive to observe activity in.

**Prewarm (iOS 15+):** `EdgeRum.start()` is host-called from
`didFinishLaunching`, so we wake at the *real* launch, but `p_starttime` still
reports the **prewarm** fork — possibly hours earlier. When prewarmed
(`PageLoadCapture.swift:105`), still mint with `trace.root_type = launch`, but
**fall the anchor back to `launchStart`** (`PageLoadCapture.swift:71`, forced at
`EdgeRum.swift:189`). Attribution is kept; only the anchor degrades, and it
degrades to the anchor that ships today. No new vocabulary is needed to tell the
two apart — `page_load.prewarmed` already rides the same payload and already says
which anchor was used.

`PageLoadCapture.swift:109`'s iOS-14 `return false` is **correct, not a gap** —
prewarming shipped in iOS 15, so a prewarmed launch cannot occur on iOS 14. The
deployment target stays iOS 14 (`Package.swift:15`, `EdgeRum.podspec:33`), so the
branch stays; nothing is decided about it.

**Background-launch guard:** `applicationState == .background` at mint → **no
root**. A `BGTaskScheduler` wake, silent push, or location wake firing three
requests produces `injected_unattributed`, which is honest — there was no launch.
This deliberately diverges from `PageLoadCapture`, which arms and waits for
`didBecomeActive` (`:265-273`): `page_load` measures a *window* and can afford to
wait for one; a root owns a *causal scope* and a background wake has none.
**This guard is `launch`-only — see §15.2.**

**Expiry exemption.** The launch root is exempt from **both** the 2 s idle reap
and the 10 s hard cap until the exemption ends. A 12 s cold start on a cheap
device with a cold disk stays one launch trace. When it ends, both clocks reset
and §5's normal rules take over.

**The exemption ends at the first active `CADisplayLink` tick
(`PageLoadCapture.swift:289-296`) OR `didEnterBackground`
(`LifecycleCapture.swift:157`), whichever comes first.** The tick is the app
literally showing a frame, and it is robust in a way worth recording: the link
`invalidate()`s **unconditionally** at `:311-314`, outside the `emit()` result
check, so the signal fires exactly once per process *even when
`Recorder.isEnabled` is false and no `page_load` is recorded at all*.
`didBecomeActiveNotification` was rejected — it fires *before* the first frame, so
it would start the 2 s idle clock mid-render and a slow first screen's fetches
would mint their own root, which is the exact failure the exemption prevents.

**Spec cost, flagged not hidden:** `Driver.tick` is `private`, so this needs a
seam — a callback or a notification posted at `PageLoadCapture.swift:311`. Small,
but it is a real API addition.

Android's 60 s backstop is **not ported**. It exists because `onActivityResumed`
can genuinely never fire; an `.active` iOS app ticks its display link at 60 Hz, so
the only way the tick never arrives is backgrounding before the first frame —
already the second terminator. No new timer, no new state.

**Mint point is an ordering constraint, not a decision.** The root must be
installed into the carrier **after `EdgeRum.swift:189`** (the prewarm fallback
anchor needs `launchStart` sampled) and **before `:245`** (`HTTPCapture.install`;
a root minted later leaves earlier requests unattributable).
`Recorder.shared.configure(...)` (`:169-182`) and `start(...)` (`:207`) both sit
inside that window, so the root can be minted with full session identity in hand.

### 4.2 `interaction`

`UIWindow.sendEvent(_:)` walks the responder chain **synchronously**, so a
`UIControl` target-action that fires a request runs one stack frame *before*
today's capture point at `InteractionCapture.swift:319-323`. Android's
`onSingleTapConfirmed` misattribution defect **does** have an iOS twin — as
ordering rather than latency, which is why a phase-level reading missed it.
`UIViewControllerCapture.swift:382-386` has the same shape.

**Split the swizzle. Mint before calling through; emit after.**

```swift
func edgerum_swizzled_sendEvent(_ event: UIEvent) {
    let pending = InteractionCapture.mintRoot(event)   // cheap: lock + 2 ids
    edgerum_swizzled_sendEvent(event)                  // app handlers run here
    InteractionCapture.emit(pending)                   // O1 file write, off the path
}
```

**Both halves cannot move together.** §13's O1 — every `recordEvent` doing a
synchronous `JSONEncoder` + atomic file write with no dirty check
(`Recorder.swift:539` → `SessionSidecar.swift:85-102`) — is paid on the main
thread by taps. Hoisting all of `handleSendEvent` above the dispatch would put
that write on the critical path of every tap the user feels, adding SDK latency
to the exact interval this map exists to measure.

The mint half does: the `allTouches` scan and ended-phase filter (today at
`:166-182`), target resolution via `decideEmission` (`:199-226`), one
`os_unfair_lock` acquisition, and two id generations. That is existing work moved
earlier in the same call, not new work — but it now runs **before** dispatch. The
resolved target rides to the emit half on `pending` rather than being re-walked:
one responder-chain walk per ended touch, unchanged from today.

**Secure-field taps: mint the root, drop the event.**
`responderChainContainsSecureField` (`:229-240`) currently drops the tap
wholesale; under the split that decision moves into the mint half and need not
suppress both.

```
mint half:   secureChain ? mintAnonymousRoot() : mintRoot(target)
emit half:   secureChain ? nothing             : recordEvent("user.interaction", …)

wire:  login POST        → rum.action.id = <root>, trace.root_type = interaction
       user.interaction  → absent
       interaction.target / .target_id → never emitted
```

The wire carries **no root-name attribute**, so a root's descriptive identity
rides entirely on its carrying event; suppressing that event suppresses
everything descriptive, and the root itself leaks nothing. Dropping the root as
well was rejected: it blinds the SDK to auth-request latency — the requests whose
timing matters most — and hands `injected_unattributed` a fourth cause the enum
cannot separate.

**Multi-touch:** **one root per `sendEvent` that carries at least one ended
touch**, named from the first ended touch's resolved target. All N
`user.interaction` events still emit (event count unchanged from the `:175`
per-touch loop) and all N carry that one root's ids. The gesture is the causal
unit, not the finger. Three rapid taps on one button legitimately produce three
traces — each in-flight request keeps the root it captured at task creation (§9).

**`interaction.name_source`** (§11.2) is a new attribute this root's emission must
carry.

### 4.3 `navigation`

**`viewDidAppear` mints only when the carrier is `.empty` or `.expired`.**

The overwhelming majority of screen fetches fire in `viewDidLoad` /
`viewWillAppear`, strictly before `viewDidAppear` — so a navigation root minted at
appear is childless for the screen's own fetch, which already captured the tap's
root. On iOS that is **not** a defect: tap → nav → content is the more truthful
causal chain.

```
tap "Buy" → [interaction root R1]
  ├─ user.interaction   rum.action.id=R1
  ├─ navigation         rum.action.id=R1     ← child span, not a root
  └─ GET /checkout      rum.action.id=R1     (fired in viewDidLoad)

deep link → [navigation root R2]             (carrier was empty)
  └─ GET /product/42    rum.action.id=R2
```

`navigation` roots therefore mean exactly what the name says: entries with no user
gesture and no launch behind them — deep links, push opens, programmatic
navigation. Both emitters follow the same rule: the UIKit swizzle
(`UIViewControllerCapture.swift:382-386`) and the SwiftUI `.edgeRumScreen` path
(`SwiftUIEmitter.emitScreenAppear`, `ViewModifiers.swift:41-54`).

Because the launch root is expiry-exempt (§4.1), it is still live at the first
`viewDidAppear`, so the cold-start landing screen joins the **launch** trace
rather than minting its own.

When the `navigation` event does **not** mint (a root was live), it is an ordinary
child span: its own `span.id`, `parent.span.id` = the live root's `span.id`.

**Wire-visible consequence:** iOS emits materially **fewer** `navigation` roots
than Android. No name or enum value differs, so the fidelity rule holds, but the
backend must not read a low iOS `navigation` count as a coverage gap. This is
filed in `EDGETELEMETRYPROCESSORGO#1`.

### 4.4 `resume`

A warm foreground resume **mints**, with `trace.root_type = resume` — a fifth
member of Android's four-member enum, cleared through the backend delta (§17).

Declaring `injected_unattributed` correct for resume traffic was rejected: it
collapses three distinct causes into one enum member (genuine no-live-root,
coverage holes, resume burst), which is the failure the always-stamped marker
exists to prevent. The burst is not marginal traffic either — it is causally
coherent, and it is the burst with the *worst* latency profile in the app (cold
connection pool, cold caches, token refresh), every request of which already pays
a full TLS handshake under §13's O3.

Reusing `navigation` was rejected for a reason that costs more than the saving:
§4.3 makes iOS `navigation` roots *fewer* than Android's, and that delta is
already in the handover — folding in the app's highest-frequency root **reverses
the sign of a difference we are about to tell the backend to expect**, and makes
every resume a phantom screen transition. There is also a mechanical tell: a
`navigation` root's identity comes from a `viewDidAppear`-shaped event carrying a
screen name; a resume root has no screen and its carrying event is
`app_lifecycle`.

**Mint at `LifecycleCapture.swift:164-171`, immediately before the existing
`emit(state: "foregrounded")`.**

- `didBecomeActive` (`:173-180`) is too late by construction: the burst is fired by
  host code hanging off the very notification `willEnterForeground` observes, so
  minting later attributes only the leftovers.
- Minting **before** the emit makes the session interaction free. Rotation is lazy
  and event-driven — `bumpLastActiveAndEmitRotationIfNeeded()` runs at the top of
  `recordEvent` (`Recorder.swift:335`) against a 30-minute `Date` idle
  (`SessionContext.swift:70`), and `SessionManager.rotate()` has no production
  caller. After a >30-minute background, that emit **is** the first touch, so the
  `session.finalized` → `session.started` pair fires from inside
  `willEnterForeground` and the resume root is born into the **new** session with
  its ids leaving on an event that already belongs to it.
- `willEnterForeground` does **not** fire for an inactive-but-not-backgrounded
  interruption (Control Centre, notification shade, cancelled app-switcher swipe),
  which produce only `willResignActive` → `didBecomeActive`. Mounting here means no
  `resume` root is ever minted for an interruption the user never left the app for.

**Conditional on an empty-or-expired carrier** — §4.3's rule reused verbatim, not
a new mechanism. The sub-2-second app-switcher peek returns with the pre-background
root still live under the idle threshold, the condition is false, and nothing
re-mints over it. It also makes `launch` and `resume` mutually exclusive without
depending on which notifications a cold launch posts, since the launch root is
expiry-exempt and therefore live.

**No expiry exemption.** Standard 2 s idle / 10 s cap with extension triggers. A
warm resume renders within a frame or two of `willEnterForeground`, so §4.1's end
condition would fire before the window it exempts — and inheriting it would mean
re-arming a display link that deliberately tore itself down
(`PageLoadCapture.swift:311-314`) to gate a window measured in milliseconds. A slow
**sequential** burst still stays one trace, because each child pushes the idle
deadline out: the 2 s is idle time, not wall time. A burst genuinely exceeding the
10 s cap splits, like every other non-launch root.

**See §15.2 for the `applicationState` do-not-add note. It is load-bearing.**

### 4.5 Clearing the carrier

**There is no clear hook — not on background, not on resign-active.** §3.1's
clock is sleep-inclusive, so any background longer than the 2 s idle window
expires the root with no hook at all:

```
background 0.5 s (app-switcher peek)
   no clear  → tap root still live on resume   ← truthful attribution
   clear     → injected_unattributed

background 10 min
   no clear  → expired by idle (2 s)           ← identical
   clear     → no root                          ← identical
```

The only behavioural difference is the sub-2-second peek, where **keeping** the
root is the better answer. `willResignActive` (`LifecycleCapture.swift:150`) is
worse still — it fires for Control Centre, banners and incoming calls, discarding
live roots mid-flow.

An in-flight request whose completion lands after backgrounding is unaffected:
attribution is stamped into the bag at **task creation** (§9), and completion never
reads the carrier.

### 4.6 `request` — accepted, never minted

`request` is a legal `trace.root_type` value in Android's contract and the backend
accepts it. **No iOS ticket assigned it a minting site**, and §10's ladder sends an
unrooted request to `injected_unattributed` / `injected_expired` with no root ids
rather than minting one. So iOS never emits `trace.root_type = request`.

This is stated as a known gap, not a decision: if a future effort wants
request-initiated roots on iOS, it mints at the §7 capture point and inherits the
§4 carrying-event rule. Do not add it as "completeness" — an implementer minting a
root per unattributed request would destroy the only signal §10 exists to produce.

---

## 5. Expiry

| | |
|---|---|
| Idle | **2 s**, extended on child start **and** on request completion |
| Hard cap | **10 s** from mint, never extended |
| Evaluation | **lazy**, at read (§2.1) |
| Exemption | `launch` only, until first frame or background (§4.1) |

Android's numbers, unchanged. Timings are nominally "mechanism", but divergence
would skew `injected_unattributed` rates between platforms on the same user
journey, defeating cross-platform comparison — so the wire-identical spirit
applies.

**One policy, two consumers.** The carrier (§2.1) and the crash annotation's
`trace.root_expired` flag (§12) are the only readers of these thresholds, and they
must read the **same** policy value. Stated explicitly so a future change to 2 s /
10 s cannot silently desync crash semantics from expiry.

---

## 6. Sampling

`Sampler` is private to `Recorder` (`Recorder.swift:105`), gated at record time
(`:340`), with no accessor, and re-rolled on session rotation (`:274-278`,
`:491-496`). The flip is **per-session, not per-root**, so putting `sampled` on the
ambient root would store the same bit on every root in the session.

**The root carries no `sampled` field.** Instead: **inject always** (subject to the
allowlist), with the `traceparent` flag bits reflecting the session's decision —
`-01` sampled, `-00` not. This needs a read-only `isSampled` accessor on
`Recorder`; suppressing injection entirely costs the same (both need a readable
sampler at the capture point) while throwing away the flag W3C provides for exactly
this purpose.

**This collapses gate ordering.** The allowlist decides *whether a header is
written*; sampling decides *only its flag bits*. They do not race. An unsampled,
off-allowlist request writes nothing and emits nothing.

**No new outcome member.** `http.request` is not in `forcedEmitAllowlist`
(`Sampler.swift:22-28`), so an unsampled session emits **no span at all** — there
is no event left to stamp an outcome on. The wire still carries a trace id with
`-00` flags and no matching client span; that is the documented,
contract-sanctioned shape, not a dangling parent.

**Known ceiling, named not engineered around:** a root spanning a session rotation
could be injected `-01` and recorded under a now-unsampled session, or the reverse.
Root life is capped at 10 s and rotation is 30-minute-idle-driven, so the window is
small.

---

## 7. The capture point

### 7.1 What is swizzled

**Instance-swizzle `URLSession`'s task-creation family.** Not a public wrapper:
this SDK's install is zero-touch (`URLProtocol.registerClass` at
`HTTPCapture.swift:188` plus the `protocolClasses` instance-getter swizzle at
`:844+`), and a wrapper forfeits that for every consumer who never reads our docs.

Swizzling creation puts our code **on the caller's thread**, which is the only
thing a carrier read needs. `canInit(with:)` (`:690`), `canonicalRequest(for:)`
(`:705`) and `startLoading()` (`:713`) all run on the URL loading system's queue
(`delegateQueue: nil`, `:730`) — a carrier read in any of them is null for every
request.

**Capture coverage must equal emission coverage.** `URLProtocol` already intercepts
upload and download traffic, so a `dataTask`-only swizzle would leave those emitting
`http.request` with a permanently null carrier — a silent hole rather than a
measured one.

**The public arms:** every `dataTask(with: URLRequest | URL [, completionHandler:])`,
`uploadTask(with:from:)` / `(with:fromFile:)` / `(withStreamedRequest:)` (with and
without completion handlers), and `downloadTask(with: URLRequest | URL
[, completionHandler:])`.

**The private arms — measured, and non-optional.** async/await misses **every**
public creation selector; it dispatches to a **disjoint private family** carrying
the per-task delegate, and the two families do not funnel into each other in either
direction (verified both ways on Swift 6.2.3 / macOS 26.6.2, Xcode 26.2 SDK):

```
_dataTaskWithRequest:delegate:completionHandler:
_dataTaskWithURL:delegate:completionHandler:
_uploadTaskWithRequest:fromData:delegate:completionHandler:
_downloadTaskWithRequest:delegate:completionHandler:
_dataTaskWithRequest:delegate:               ← URLSession.bytes(for:)
```

Binding only the public arms puts **100% of async/await traffic into
`injected_unwired`**.

**Discovery, not literals.** Enumerate `class_copyMethodList(URLSession.self)` at
install and match `^_(data|upload|download)TaskWith.*[Dd]elegate:`. No private-API
string appears in the binary, and the match survives a rename.

**Degrade, never trap.** A selector that is absent is skipped, not fatal. **Install
must report how many arms it bound** (debug log at minimum, alongside the existing
`HTTPCapture.install(debug:)` reporting) — otherwise a future OS silently reverts
async traffic to `injected_unwired` and it looks exactly like health.

*Residual:* the private family is verified on macOS Foundation only. iOS 15/16/17
confirmation needs a device run and is not blocking.

### 7.2 The positive injection guard

**Inject only when the session's `configuration.protocolClasses` actually contains
`EdgeRumURLProtocol`.** One array scan at the capture point.

Two doors lead to the same failure, and it is worse than a coverage hole:

- **Background configurations** fire the creation swizzle but **never** reach
  `URLProtocol` (measured with `protocolClasses` explicitly set and read back as
  set).
- **Sessions created before `EdgeRum.start()`**: `URLSession` **snapshots** its
  configuration at creation (measured), so the `protocolClasses` getter swizzle at
  `:842-880` can never reach them — while a class-wide creation swizzle installed
  later **does** fire for them retroactively.

Both produce `traceparent` **on the wire with no client span ever recorded** — a
server span whose parent id no client emitted. A **dangling parent** is strictly
worse than a hole, because a hole shows up as `injected_unwired` and this is
invisible. It is not in the outcome enum and, per the fidelity rule, must not be.

`configuration.identifier != nil` discriminates background (measured `nil`/`nil`/`"x"`)
but is only a subset; the positive check closes both doors and needs no new
vocabulary.

**Upside:** with the guard in, the creation swizzle being retroactive *fixes* an
ordering hole the getter swizzle has today — a pre-existing session that *does*
carry the protocol is now fully covered.

Sessions failing the guard emit **nothing** — no header, no span, no outcome. That
is silence, and it is documented in §16.

### 7.3 What runs there

In order, on the caller's thread, inside the swizzled creation call:

1. **Self-exclusion** — `shouldCaptureRequest` (`HTTPCapture.swift:205-228`). Bail
   entirely for our own traffic (§8.5).
2. **Positive injection guard** (§7.2). Fail → return the untouched task.
3. **Carrier read** (§2.1) → `.live` / `.expired` / `.empty`.
4. **Inbound adoption check** (§8.4).
5. **Allowlist** (§8.1).
6. **Stamp `span.start_time`** = now, at task creation (§8.2).
7. **Write the bag** (§9) — always, whatever the outcome.
8. **Write the `traceparent` header** — unless the outcome is
   `skipped_off_allowlist` or `adopted`.

---

## 8. Injection

### 8.1 Allowlist

**Android's, adopted verbatim.** Dot-anchored entries: `.example.com` matches
`api.example.com` and `api-v2.example.com`, but **not** `api.example.com.evil.com`.
A one-time warning when the allowlist is empty (emitted from `EdgeRum.start()`).
Validation rejects entries with fewer than two further labels, so `.com` fails fast.
Validate at `EdgeRumConfig` construction, as `ignoreUrls` regexes already are
(`EdgeRumConfig.swift:83`).

**Empty by default** — no host is injected until the host app opts one in.

Match `URLComponents.host` **case-insensitively**. Never `absoluteString.contains`.

An allowlist is not wire-visible, so strictly an iOS call; it is adopted anyway
because divergence means the two SDKs inject on different traffic for the same
config.

**Keep it separate from the collector self-check.** `HTTPCapture.swift:221-223` is
an **exact** match (`requestHost == collectorHost`) — only the comment at `:218`
says "prefix". It answers a different question (self-request suppression) and must
not be merged into the allowlist.

Off-allowlist **still stamps local ids and writes the bag** — otherwise emission
cannot tell off-allowlist from unwired — and emits `skipped_off_allowlist`.

### 8.2 `span.start_time` on a child span

**Stamped at task creation, inside the §7 swizzle**, carried in the bag. Captured at
request start, never back-computed from a monotonic delta.

This fixes **D6**: `startedAt` is currently stamped in `startLoading()`
(`HTTPCapture.swift:732`), on the URL loading system's queue, so `http.duration_ms`
(`:340`) **excludes caller-side queueing** — the exact interval this map is named
after.

Two consequences:

- **`http.duration_ms` changes meaning on the wire**: it now includes the queueing
  gap. A fix, not a break, but visible — it is in the backend delta.
- **Known ceiling, not engineered around:** a task built and resumed much later
  reports an inflated start. Anchoring at `resume()` would need a selector beyond
  the family §7.1 freezes; the dominant idiom resumes immediately.

### 8.3 Sampling flags

Per §6: flags are `01` when `Recorder.isSampled`, else `00`. Injection is not
suppressed either way.

### 8.4 Inbound adoption

**Adopt read-only: mirror their ids, never rewrite the header, never mint a span
id.** The check runs at the capture point **after** the allowlist, because the
ladder puts `skipped_off_allowlist` above `adopted` — an off-allowlist request
carrying a caller's `traceparent` emits `skipped_off_allowlist` and the header is
left untouched.

In `00-<trace-id>-<parent-id>-<flags>`, `<parent-id>` is the sending span — the
app's own span for this request. So:

| | |
|---|---|
| `trace.id` | ← their trace-id |
| `span.id` | ← their parent-id |
| `parent.span.id` | **absent** — we cannot see their parent |
| `rum.action.id`, `trace.root_type` | still ours |
| `traceparent.outcome` | `adopted` |

Minting our own `span.id` would force rewriting their header to keep the server's
view consistent, which contradicts adopting at all.

**Self-adoption guard:** on a retried request object our own previously-injected
header reads as inbound. The bag settles it — **bag present means the header is
ours**, so it is not an adoption.

### 8.5 Self-request exclusion

Run `shouldCaptureRequest` at the capture point, **before** the allowlist.

Of the three checks at `:205-228`, check #1 (the `X-Edge-Rum-Internal` header) is
the one that fires there: `BatchTransport` sets the header on the **request** at
`:107` and `taskDescription` on the **task** at `:135` — *after* `dataTask(with:)`.
`BackgroundUploader` does the same (`:105` then `:109`, via
`uploadTask(with:fromFile:)`, inside the swizzled family). Check #3 (`endpointHost`,
`:221`) is a no-op whenever the host leaves it nil, which is the default.

**D4 is fixable at the protocol layer, so self-exclusion is no longer
single-mechanism.** `URLProtocol.task` is the **outer** task — Foundation builds the
protocol via `initWithTask:` and consults **`+canInitWithTask:`**, not
`+canInitWithRequest:`, whenever a session task exists (verified directly: with both
overridden, only the task form was called). A task described *after* creation and
before `resume()` — exactly `BatchTransport.swift:136`/`:137` — reads back as
`"edge-rum-internal"` at `canInit(with task:)` time.

**Override `canInit(with task:)`** to restore defence check #2. The comment at
`:699-702` calling task metadata "unavailable at this layer" is **incorrect**; the
inner-task read at `:776` is still always nil, so D4 as a *defect* is confirmed
while D4 as a *dead end* is not.

### 8.6 Redirects — an allowlist bypass, closed

Foundation follows redirects itself (no `willPerformHTTPRedirection` exists on the
internal session's delegate, **D2**), and the outer protocol's `request` stays the
original, so the bag is intact and **emission is unaffected** — one `http.request`
per chain.

**Injection is affected.** The `traceparent` written at the capture point travels
with the redirect. Foundation strips `Authorization` cross-host; arbitrary custom
headers it does not. A request allowlisted for `api.example.com` that 302s to
`cdn.thirdparty.com` ships `traceparent` to a host that was never allowlisted — and
the allowlist is the security gate.

**Implement `willPerformHTTPRedirection` on `EdgeRumMetricsDelegate`: re-run the
allowlist against the new host, strip `traceparent` when it fails, and return the
proposed request otherwise** so redirect behaviour is unchanged. This closes half of
D2; the auth-challenge half stays with #165.

**Retry needs nothing.** An app-level retry is a new task, so a new capture-point
pass — new `span.id`, same trace while the root is live, a fresh root once it is not.

---

## 9. The hand-off — one bag on the request

**One `URLProtocol` property key holding a `[String: String]` bag.** Set at the
capture point via the `(request as NSURLRequest).mutableCopy()` dance the code
already does at `HTTPCapture.swift:715-719`; read in `didComplete` (and in
`stopLoading()`, §11.4) via `URLProtocol.property(forKey:in: request)`.

The capture point already has an in-codebase proof:
`URLProtocol.setProperty(true, forKey: processedKey, in: mutable)` at `:719`
survives into `canInit(with:)` at `:692-694`, and `mutableCopy()` at `:715` carries
request-borne state across the internal-session hop for free.

**Consequence: the `URLProtocol` layer is read-only with respect to trace state.**
It writes nothing and decides nothing.

Rejected alternatives, with the reason each fails *this* boundary:

- **Associated object on the task** — the capture point holds the *outer* task;
  `recordOutcome` only ever sees the *inner* task created at `:733`, so the object is
  unreachable from emission. (The protocol *instance* can see the outer task — §8.5 —
  but the emission path cannot.)
- **A `(session, taskIdentifier)` stash** — `taskIdentifier` is unique per *session*,
  so outer and inner tasks collide, and **D5** leaks one entry per cancelled request,
  forever.
- **A private header stripped in `startLoading()`** — leaks onto the wire in exactly
  the case we cannot control: a request that bypasses the protocol entirely.

The request is the sole carrier that crosses the hop. `URLProtocol` properties never
reach the wire and die with the request: no eviction, no lifetime, nothing to leak.

**Bag contents:** `trace.id`, `span.id`, `parent.span.id` (absent on adopted),
`rum.action.id`, `trace.root_type`, `span.start_time` (internal epoch form — §15.1),
and the resolved `traceparent.outcome`.

**The bag's presence *is* the marker. There is no second mechanism.** See §10.

**Cost, recorded not fixed:** this rides the same mechanism as `processedKey`, so
**D3** (§13) becomes load-bearing for trace state. If the property bag ever stops
surviving the hop, recursion protection and trace attribution fail *together*.

---

## 10. The outcome ladder

Six values, **in the contract's precedence order** (`backend-wire-contract.md` §6.1),
evaluated top to bottom. This order is not an arbitrary tie-break: `injected_unwired`
is the *absence of the marker*, so when it applies there is nothing left to evaluate
expiry or attribution **with** — it must be checked first among the injected three.

| # | `traceparent.outcome` | Condition |
|---|---|---|
| 1 | `skipped_off_allowlist` | Capture point ran; request host not on the allowlist. No header written. Local ids still stamped; bag written. |
| 2 | `adopted` | Allowlist passed; an inbound `traceparent` was present **and the bag was absent** (so it is not ours). Header left untouched; ids mirrored per §8.4. |
| 3 | `injected_attributed` | Allowlist passed; carrier returned `.live`. Header written with the root's ids. |
| 4 | `injected_unwired` | **No bag at emission.** The request reached `URLProtocol` without passing the capture point — a coverage hole. |
| 5 | `injected_expired` | Bag present; carrier returned `.expired` — a root existed and aged out under §5's 2 s / 10 s rules. Header written, no root ids. |
| 6 | `injected_unattributed` | Bag present; carrier returned `.empty` — genuinely no root. Header written, no root ids. |

**Where each is decided.** Values 1, 2, 3, 5 and 6 are resolved at the capture point
and written into the bag; value 4 is the emission-time conclusion drawn from bag
absence, and is therefore the first thing `recordOutcome` checks. Emission logic is
exactly:

```
no bag                    → injected_unwired
bag present               → bag["traceparent.outcome"]
```

**`injected_expired` must be reachable, and `lastRoot` must not be how.** iOS's
carrier returns `.expired` (§2.1) — that is the whole mechanism, and it costs no new
attribute, no new state and no new lock. Reading `lastRoot` (§2.2) would also
"work", and it would hand §14.1's guard test exactly the route it was written to
forbid. The distinction to hold: **the carrier answers *is there a live root*;
`lastRoot` answers *what was the last root* — and only the first may reach a
request.**

Folding `injected_expired` into `injected_unattributed` would make the *same Android
name carry a different meaning on iOS* — theirs *genuinely no action*, ours *no
action, or one that aged out* — with no field left to separate them. That is worse
than any divergence this map refused, and invisible in exactly the way the
always-stamped marker exists to prevent.

`traceparent.outcome` appears on **`http.request` only** — never on
`resource_timing` (§11.3).

---

## 11. Emission — which events carry what

### 11.1 The event table

iOS emits **two wire types where Android emits one**: `recordEvent` →
`type:"event"` + `event_name`, `recordPerformance` → `type:"metric"` +
`metric_name` (`EventEnvelope.swift:77-89`). Trace is unaffected —
`extractTraceInfo` runs at the processor's `service.go:305`, *before* the metric
branch at `:310`, so metrics get the same seven trace columns on the same parent row.

| iOS event | Wire type | Emitter | Carries |
|---|---|---|---|
| `http.request` | event | `HTTPCapture.swift:350` | full child span + `traceparent.outcome` |
| `resource_timing` | metric | `HTTPCapture.swift:371` | join keys only — §11.3 |
| `navigation` | event | `UIViewControllerCapture.swift:309` | root set when it mints, else child span |
| `screen.duration` | metric | `UIViewControllerCapture.swift:337`, `ViewModifiers.swift:81` | full child span |
| `user.interaction` | event | `InteractionCapture.swift:180` | root set + `interaction.name_source`; **suppressed entirely** on a secure-field tap |
| `page_load` | event | `PageLoadCapture.swift:224` | root set (launch) |
| `app_lifecycle` | event | `LifecycleCapture.swift:121` | root set (resume) — **`foregrounded`-with-mint only** |
| `app.crash` | event | 8 sites | join keys only + `trace.root_expired` when stale — §12 |
| `long_task` | metric | `RunLoopObserverCapture.swift:132` | **not annotated** (§12) |

"Root set" = `trace.id`, `span.id`, `rum.action.id`, `trace.root_type`,
`span.start_time`; `parent.span.id` and `span.duration_ms` absent (§4).
"Child span" = `trace.id`, its own `span.id`, `parent.span.id` = the root's
`span.id`, `rum.action.id`, `trace.root_type`, `span.start_time`,
`span.duration_ms`.

An `app_lifecycle` `foregrounded` event that **skipped** the mint carries none of
these, and **that absence is itself the signal** that the peek was absorbed by a
surviving root. No new attribute is needed to distinguish the two cases.

### 11.2 `interaction.name_source`

`resolveTargetIdentifier` (`InteractionCapture.swift:276-289`) collapses two sources
with opposite privacy profiles into one attribute:

| Value | Source | PII |
|---|---|---|
| `accessibility_identifier` | `target.accessibilityIdentifier`, non-empty (`:277-279`) | developer-authored — safe |
| `button_title` | `UIButton.currentTitle`, else `title(for: .normal)` (`:280-287`) | **rendered UI text** — "Pay Sarah £40", a contact name on a cell button |
| `none` | neither resolved; `interaction.target_id` omitted rather than blank (`:288`) | n/a |

The secure-field carve-out at `:230` catches password fields only; it has never
covered a button *titled* with someone's data, and that text leaves the device
today, unlabelled and unfilterable.

**Emit `interaction.name_source` alongside `interaction.target_id`, always present,
with exactly those three values.** Nothing is dropped — the shipped attribute keeps
its population and meaning — but the PII-bearing class becomes gateable by backend
and host.

The key is **`interaction.`-prefixed, not `ui.`**: the two platforms' interaction
vocabularies share no prefix (Android `ui.type/target/x/y/direction/screen`; iOS
`interaction.kind/target/target_id/screen` at `:215-222` plus `interaction.name`
from `ViewModifiers.swift:96-97`), and Android's seven values are Android platform
concepts that do not exist on iOS. Cleared through the backend delta (§17).

### 11.3 `resource_timing`

Carries **join keys only** — `trace.id`, `span.id` (**the same `span.id` as its own
`http.request`, never a new one**), `rum.action.id` — and deliberately **not**
`span.start_time`, `span.duration_ms` or `traceparent.outcome`.

It is emitted two statements after its `http.request` for the same task
(`HTTPCapture.swift:350` then `:371`), so it is a phase breakdown *of that span*, not
a second span. Duplicating the outcome would bias the contract's §6.5 health query by
exactly the fraction of requests that produce `URLSessionTaskMetrics`, turning the one
health signal this map depends on into a biased one.

### 11.4 Cancelled requests (D5)

`stopLoading()` (`HTTPCapture.swift:738-743`) cancels and invalidates without calling
`recordOutcome`, so every navigate-away and every outer-layer timeout is silently
dropped — no `http.request` at all. That is a third cause of a root with no child,
masquerading as a coverage hole.

**Record from `stopLoading()`** — `recordOutcome(…, error: URLError(.cancelled))`,
`finishedAt` stamped there, outcome read from the bag exactly as on the success path.
`recordOutcome` already takes `error:` (`:255`) and `URLError(.cancelled)` is the
existing representation, so this needs **zero new vocabulary**.

**Requires an idempotence flag** on the protocol instance so a `stopLoading()`
following `didComplete` cannot double-record. Cheap, but it must be implemented or
the first run double-counts.

---

## 12. Crash annotation

**Annotated: `app.crash`, both causes. Excluded: `long_task`.**

Both the PLCrashReporter replay (`PLCrashIntegration.swift:174`) and the hang
watchdog (`HangDetector.swift:333`) emit under the same event name, so the wire rule
is simply "`app.crash` carries the annotation". Only the vehicle differs.

`long_task` is excluded: it fires on the minting thread (`recordPerformance`,
`RunLoopObserverCapture.swift:132`), so "last known root" is the wrong concept for
it, and a run-loop stall is plausibly *part of* the action rather than something that
happened during it. Android annotates crash and hang only.

**Attributes** — Android's, unchanged: **`trace.id` and `rum.action.id` only**.
`span.id` and `parent.span.id` are **absent** — a crash is not a new child span and
has no duration, and that absence is also the structural half of §14.1's guard: there
is no parent attribute on the event to parent *with*. No mint-timestamp attribute is
needed; the join reaches the root's own carrying event, which already has its
`span.start_time`.

### 12.1 Cross-process survival — zero new I/O

`Recorder.enqueue` already calls `sidecar?.write(snapshot: context.snapshot())` on
every event (`Recorder.swift:539`) — §13's O1 cost, already paid. The annotation adds
**no new I/O and no new main-thread cost**:

```swift
// Recorder.swift:539
sidecar?.write(snapshot: context.snapshot(), extra: lastRoot.load())
```

**Widen the sidecar write; do not touch the context.** `PayloadBuilder.swift:39`
merges the context into *every* event (`context.merging(event.attributes)`), so
routing the annotation through the context would put span attributes on non-spans.
`extra` merges **after** `filter(_:)`, so `SessionSidecar.mirroredKeys` keeps its
"identity only" meaning. One signature change, one production call site.

**The crash read path needs no changes at all.** `CrashSidecarReader.parse` already
sweeps unconsumed keys into `extras` (`:83-85`) and `PLCrashIntegration:163-165`
splats them onto the event (`where attrs[key] == nil`, which cannot collide — no
trace code exists today).

The hang path reads `lastRoot.load()` in-process instead, merging into
`HangEventEncoder.encode`'s output at `HangDetector.swift:327-333` — one seam.

### 12.2 `trace.root_expired` — one deliberate divergence

Android stamps **nothing** when the root has aged out. **iOS always stamps**, because
Android's rule would annotate NULL for any hang after 2 s of idle — the common case,
and the reason §2.2's non-expiring ref exists at all.

Always-stamping silently redefines a frozen attribute, so the divergence is made
explicit and **additive**:

```
app.crash:
  trace.id            = last root's trace
  rum.action.id       = last root's action
  trace.root_expired  = true     // iOS-only, present ONLY when stale
```

Absent → the root was live, and the event joins exactly as Android's does. Present →
the backend decides whether the causal claim survives. Android never stamps an
expired root, so the key never appears on their wire and nothing about their contract
changes. Cleared through the backend delta (§17).

Staleness for this flag is evaluated against §5's thresholds — the **same policy
value** the carrier reads. See §5.

---

## 13. Overhead and defects this spec inherits

Evidence: [`docs/audits/trace-v3-path-audit.md`](../audits/trace-v3-path-audit.md)
(static read @ `b90a869` — costs are **mechanism claims, not measurements**) and
[`docs/audits/trace-v3-swizzle-coverage.md`](../audits/trace-v3-swizzle-coverage.md)
(nine programs **run** against Darwin Foundation).

| | Finding | What trace v3 does to it | Mitigation in this spec |
|---|---|---|---|
| **O1** | Every recorded event does a synchronous `JSONEncoder` + atomic file write on the caller's thread with **no dirty check** (`Recorder.swift:539` → `SessionSidecar.swift:85-102`); taps pay it on the main thread | Scales it with **request volume** | Not fixed (SDK code; this map merges none). §4.2's mint/emit split keeps it off the tap critical path; §12.1 rides the existing write rather than adding one. A per-keystroke write to close §16's secure-field gap was **refused** |
| **O3** | A fresh ephemeral `URLSession` per intercepted request (`HTTPCapture.swift:721-731`) destroys connection reuse — every instrumented request pays DNS + TCP + full TLS | **Span durations inherit an SDK-induced latency profile, not the app's** | Not fixable inside the `URLProtocol` design §7.1 keeps. Recorded as a **measurement caveat on every `http.request` duration this map produces**, and as the reason §4.4's resume-burst latency claim is about the SDK's profile too. `http.reused_connection` (`:401`) reads false essentially always |
| **O2** | The tap path does three lock acquisitions and a `Set` allocation per touch *event* — every `.moved` at up to 120 Hz — before the `.ended` filter (`InteractionCapture.swift:166-182`) | Moves that work **before** UIKit's dispatch | No new work per event (§4.2); pre-existing cost, pre-existing frequency |
| **O4** | Every instrumented request is *dispatched* twice (transmitted once) | Adds a third swizzle (creation family) on top of the two existing ones | Accepted; object graph and callback plumbing, not network IO |
| **O5** | `startLoading` always issues a `dataTask` (`:733`), so download bodies are materialised in RAM (`:751-754` → `:771`) | Unchanged | Overhead row only — **D9's corruption half is refuted** (§13.1) |
| **D3** | The recursion guard at `:724-726` is **dead code** — only the getter is swizzled (`:889`), so the swizzled getter (`:898-909`) re-prepends our class right after the filter removed it. Recursion rests on `processedKey` alone (`:719` / `:692-694`) | §9's bag rides the **same** mechanism, so D3 becomes load-bearing for trace state | Do not "fix" D3 without a trace-attribution test in the same change: recursion protection and trace attribution now fail **together** |
| **D4** | `taskDescription` never crosses to the internal task (`:702`, `:776`) | — | **Fixable** — override `canInit(with task:)` (§8.5). The `:699-702` comment is incorrect |
| **D5** | `stopLoading()` never records (`:738-743`) — cancelled requests silently dropped | Would be a third cause of root-with-no-child | **Fixed** by §11.4, zero new vocabulary |
| **D6** | `startedAt` stamped in `startLoading()` (`:732`), so `http.duration_ms` excludes caller-side queueing | It is the interval this map is named after | **Fixed** by §8.2; `http.duration_ms` changes meaning |
| **D7** | The doc comment at `:67-71` claims `sanitizeUrl` runs on the caller; it runs on the internal session's delegate queue (`:730`, `:768`) | — | Docs-accuracy fix, flagged not required |
| — | `HTTPCapture.swift:11-12` still describes install as a **class**-method swizzle; the code at `:844+` swizzles the **instance** getter | — | Docs-accuracy fix; correct it when touching install for §7.1 |

The `nonisolated(unsafe)` + `os_unfair_lock` statics come back **clean** — correct
discipline, uncontended, no nesting, no call-out under lock. `ignoreUrls` regexes are
already precompiled (`EdgeRumConfig.swift:83` → `EdgeRum.swift:241`).

**Off-route, filed standalone, not this map's work:** #164 (`HangWatchdog` measures
hang duration on `Date`), #165 (the internal session discards host session config and
bypasses host TLS pinning).

### 13.1 D9 — refuted

Measured through a faithful `startLoading` repro against a body-counting server:
`uploadTask(withStreamedRequest:)` with a 5000 B stream → **5000 B arrive**, chunked;
`uploadTask(with:from:)` 3000 B → **3000 B arrive**; `downloadTask` → the caller
still gets a file URL with correct contents. `mutableCopy()` at `:715` carries
`httpBodyStream` across and the re-issued `dataTask` transmits it. **No corruption.**

---

## 14. Test seams

### 14.1 The guard — `testExpiredRootIsAnnotatedButNeverParented`

The single most important test in this spec. One test, both halves:

> Mint root A at the capture point. Advance §3.1's injected `() -> UInt64` closure
> past the 10 s cap so the **carrier** expires, while `lastRoot.load()` still returns
> A. Issue a request through the swizzled creation family.
> **Assert:** `traceparent.outcome == injected_expired`; **no attribute on the
> request equals A's `trace.id` or `rum.action.id`**; `parent.span.id` absent.
> Then emit a hang and assert the **same A ids are present** on `app.crash`, with
> `trace.root_expired == true`.

It passes only if the injection path reads the **carrier** and the annotation path
reads the **ref**. The moment anyone wires `lastRoot` into the capture point, the
request inherits A's trace and the first assertion fires. The second half
simultaneously proves the annotation is not silently dropped, so the test cannot be
"fixed" by disabling the feature.

*(The original formulation of this test asserted `injected_unattributed`; §10 makes
the expired case its own value, so the assertion is `injected_expired`. The
forbidden-route half is unchanged and is the point of the test.)*

### 14.2 Expiry, over a frozen clock

Using the injected closure only — wall-clock must never move:

- idle reap at 2 s with no children;
- idle **extension** on child start and on request completion (1.5 s + 1.5 s stays one
  trace);
- hard cap at 10 s, never extended;
- `launch` root survives **both** past 10 s while exempt, and is reaped normally after
  the exemption ends;
- exemption ends on the display-link seam **and** on `didEnterBackground`;
- `resume` root takes standard expiry with **no** exemption.

### 14.3 Coverage — async must not be unwired

A test that issues `try await URLSession.shared.data(for:)` (and one for
`bytes(for:)`) and **fails if the carrier was null on the caller's thread** — i.e.
fails if the private delegate-carrying arms (§7.1) were not bound. Assert the
install-time bound-arm count as well, so a future OS renaming the private family
fails loudly rather than reverting async traffic to `injected_unwired` in silence.

### 14.4 Tap ordering — the iOS twin of Android #131

A `UIControl` target-action that issues a request must capture **that tap's** root,
not the previous one. Fails against an unsplit swizzle (§4.2). This is the regression
guard for the premise correction that produced the split.

### 14.5 Golden batch

Extend `Tests/Fixtures/golden-batch-ios.json` via
`Tests/EdgeRumContractTests/GoldenBatchSnapshotTests.swift` (see #150) with at least
one root-carrying event and one child span, so any rename, reorder or **format**
change on the trace attributes flips the snapshot. Deterministic inputs already exist
(`FixedClock`, frozen identity and device context); add a frozen root id pair and a
frozen `span.start_time`. **This is also the cheapest possible tripwire for §15.1** —
a numeric `span.start_time` shows as a diff instead of a silent NULL in production.

### 14.6 Ladder coverage

One case per §10 row, including `skipped_off_allowlist` still carrying local ids, and
`injected_unwired` produced by a request that never passes the capture point.

---

## 15. Prohibitions

Each of these looks like an improvement and is not. Two fail as silent no-ops; one
fails silently on the backend.

### 15.1 `span.start_time` is never a number on the wire

`parseTime` in the processor (`internal/telemetry/extract.go:118-135`) is a type
switch with two live arms — `time.Time` and `string` via `RFC3339Nano` — and **a
numeric falls to `default: return nil`**. No error, no dead-letter, no log:
`span_start_time` lands **NULL**, and a NULL start is invisible to both
`MIN(span_start_time)` and `MAX(span_start_time + …)` in `rum_action_envelopes`, so
the action's envelope silently narrows or vanishes.

Two resolved tickets say "epoch". That is the **bag's** internal representation only
(§9). The wire rendering goes through `WireDateFormatter` like every other timestamp
(§3.2). **Do not hand a number to the encoder.**

### 15.2 Do not add an `applicationState` guard to the `resume` mint

§4.1's `applicationState == .background` guard is **`launch`-only**. At
`willEnterForeground` the state is **still `.background`** — it moves to `.inactive`,
then `.active`, only after the notification returns. Applied verbatim at §4.4's mint
site it suppresses **100% of resume roots**, and does so as a silent no-op: the
feature ships, the burst stays `injected_unattributed`, and the result is
indistinguishable from the bug it was meant to fix.

**The notification is the guard.** `willEnterForeground` fires only on a genuine
foreground transition and never for a background wake — precisely the discrimination
§4.1 spends a state check to buy.

### 15.3 `lastRoot` must never reach a request

§2.2's reference is annotation-only. The carrier answers *is there a live root*;
`lastRoot` answers *what was the last root*. Only the first may reach the capture
point. §14.1 enforces this.

### 15.4 Do not mint a root per unattributed request

See §4.6. `injected_unattributed` and `injected_expired` are the signal, not a gap to
paper over.

### 15.5 Do not add a carrier-clear hook

See §4.5. It buys nothing over expiry and makes the sub-2-second peek strictly worse.

### 15.6 Backend properties to preserve (for reviewers of the processor)

- **Envelopes key on `trace.id` / `rum_action_id` alone — never `(session.id,
  trace.id)`.** An iOS trace can legally straddle a session rotation, because §4.2's
  secure-field tap and §4.1's launch root both mint without recording an event, so
  rotation can fire on a later child. The shipped view already groups on
  `rum_action_id` alone; adding `session_id` reads as harmless tightening and would
  silently drop children.
- **No new `traceparent.outcome` members**, and no root-name attribute on the wire.

---

## 16. What this spec deliberately does not cover

**Coverage ceilings (§7.1, measured).** These fail as **silence** — no header, no
span, no `injected_unwired` — so they are invisible in the outcome distribution and
must be known rather than discovered:

- **WKWebView: zero creation-swizzle hits.** No in-process task, so no injection and
  no attribution whatever the protocol layer does. In-page XHR/fetch is invisible; a
  §4.2 tap root still mints, with no children under it.
- **Non-`URLSession` stacks** — Flutter's `dart:io` (**such a host emits no HTTP spans
  at all**), gRPC-Swift/NIO, Cronet, raw `CFNetwork`.
- **Background configurations and sessions created before `EdgeRum.start()`** (§7.2)
  — deliberately silent, to avoid dangling parents.

Everything on `URLSession` is reached by construction: Alamofire, Apollo,
GTMSessionFetcher/Firebase, React Native's `RCTNetworking`.

**Known ceilings, named not engineered around:**

- **Deferred-resume start skew** (§8.2) — a task built and resumed much later reports
  an inflated start.
- **Sampling across a rotation** (§6) — a ≤10 s window where flags and recording can
  disagree.
- **Secure-field crash annotation** (§4.2 + §12) — a secure-field tap mints a root but
  enqueues nothing, so it never reaches the sidecar; a crash during one names the
  **previous** root. Closing it means an O1-class file write per keystroke in a
  password field. **Refused.**
- **SwiftUI `.edgeRumScreen` ordering** — `onAppear` has no guaranteed order against a
  host's own `.onAppear` / `.task` on the same view. Under §4.3 this only bites for a
  deep link into a SwiftUI screen that fetches immediately (a cold launch is covered
  by the live launch root, a tap-driven navigation by the interaction root). The
  failure mode is an honest `injected_unattributed`. Settling it needs a device run.
- **iOS 15/16/17 verification of the private async family** (§7.1) — needs a device.
- **`trace.root_type = request`** (§4.6) — accepted by the store, never emitted by iOS.

**Still fogged (map #153, *Not yet specified*):**

- **Offline replay vs root envelopes.** `OfflineQueue` caps at **200 batch files**
  (`EdgeRumConfig.maxQueueSize`, `OfflineQueue.swift:69, 81, 89`) with **oldest-first
  FIFO** eviction (`:202-209`, ordered by filename at `:188`); drain is opportunistic
  and never scheduled (`HTTPTransportSink.swift:19, 94-96, 133-135`), so **replay delay
  is unbounded and unmeasured**. Payloads replay byte-for-byte (`drain(via:)`, `:139`),
  so a child can land hours later with its original instants intact — which is why
  envelopes are query-time views and **an envelope is never final**; a dashboard caching
  one needs a recompute window or it under-reports precisely the slow, flaky sessions
  most worth seeing. The sharpened iOS case: §12's crash annotation is a **join key**,
  so if the FIFO evicts the batch holding the root's carrying event, the annotation
  survives as an orphan `trace.id` pointing at nothing.

**Pre-existing vocabulary divergence, flagged not fixed:** iOS writes no
`rum_screen_durations` (the processor's metric branch returns early before the name
switch) and no `rum_ui_interactions` (that switch keys `ui.interaction`; iOS emits
`user.interaction`). Trace is unaffected — the span attributes are already safe on the
parent row.

**Out of scope for the whole effort** (map #153): the backend/Go implementation;
cross-SDK vocabulary convergence (`frame.*`, `memory.*` diverge four ways); the broad
SDK audit beyond the code trace v3 touches; and new telemetry datapoints not required
by trace v3 (MetricKit, energy, scroll hitch, memory warning, scene attribution —
tracked as #21–#28 / #100–#114).

---

## 17. Backend status

**Nothing is blocked.** Every trace column iOS needs already exists at
`EDGETELEMETRYPROCESSORGO@2874607` — the seven columns on `rum_telemetry_events`, the
`ix_..._rum_action_id` index, and the `rum_action_envelopes` view
(`internal/db/migrations/0002_android_wire_contract.up.sql:5-12, 77-78, 96-106`), with
`extractTraceInfo` (`internal/telemetry/extract.go:280-290`) reading all seven by name.
The name diff is **8/8 with zero defects**, and `VARCHAR(16)` holds every
`trace.root_type` value (longest: `interaction`, 11 chars).

**Cleared to freeze** — the four iOS-only values are filed and accepted:
`trace.root_type = resume`, `trace.root_expired`, `interaction.name_source` with its
three values, and `injected_expired` (Android's own name).

**One outstanding ask, non-blocking:** `traceparent.outcome` has **no column
anywhere** — `extractTraceInfo` does not read it, and
`internal/db/schema_check_test.go:10-14` deliberately bans it from
`rum_http_requests`. The value still lands in `rum_telemetry_events.attributes`, so
the interim query is `attributes->>'traceparent.outcome'`; the contract's §6.5 named
acceptance test (`SELECT traceparent_outcome …`) does not compile against the shipped
schema. iOS's stake is sharper than Android's: the outcome is the **only** production
signal by which §16's coverage ceilings become observable rather than remaining claims
in an audit.

Filed as [EDGETELEMETRYPROCESSORGO#1](https://github.com/NCG-Africa/EDGETELEMETRYPROCESSORGO/issues/1),
with the iOS column of the contract commented on
[edge_telemetry_android#132](https://github.com/NCG-Africa/edge_telemetry_android/issues/132).

---

## 18. Provenance

| Section | Ticket |
|---|---|
| §2.1 carrier, §7.1 capture point, §10 marker | [T1 #154](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/154) |
| §3.1 clock, §5 expiry | [T2 #155](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/155) |
| §13 overhead and defects | [T3 #156](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/156) · `docs/audits/trace-v3-path-audit.md` |
| §8 injection, §9 bag, §11.4 cancellation | [T4 #157](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/157) |
| §4.1 launch root | [T5 #158](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/158) |
| §4.2 interaction, §4.3 navigation, §4.5 clearing, §11.2 name source | [T6 #159](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/159) |
| §2.2 `lastRoot`, §12 crash annotation, §14.1 guard | [T7 #160](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/160) |
| §10 ladder order + `injected_expired`, §11 event table, §15.1, §17 | [T8 #161](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/161) |
| §7.1 private arms, §7.2 positive guard, §8.5 `canInit(with task:)`, §13.1, §16 ceilings | [T10 #163](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/163) · `docs/audits/trace-v3-swizzle-coverage.md` |
| §4.4 resume root, §15.2, §15.6 envelope key | [T11 #166](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/166) |
| This document | [T9 #162](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/162) |

Map: [#153](https://github.com/NCG-Africa/edge_telemetry_ios_sdk/issues/153).
Off-route issues filed by this map: #164, #165.
