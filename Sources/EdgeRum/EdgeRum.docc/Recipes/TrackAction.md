# Track an action

Record something the user is trying to do, and how it ended.

## Overview

Call ``EdgeRum/startAction(_:)`` when the user begins — a checkout, a
sign-in — and `complete()` or `fail(reason:)` on the returned
``RumAction`` when it ends. The SDK records an `action.started` event
now and one `action.ended` event with `action.outcome` later. While the
action is open, every event recorded carries its `action.id`, so the
requests and screens that made up a slow checkout can be found.

```swift
import EdgeRum

let checkout = EdgeRum.startAction("checkout")
submitOrder { result in
    switch result {
    case .success: checkout.complete()
    case .failure(let error): checkout.fail(reason: error.localizedDescription)
    }
}
```

## Abandoned actions

The SDK never guesses that a user gave up. An action is recorded as
`abandoned` only when it can no longer complete: its session ended, the
app process died (sent on the next launch), or it was still open ten
minutes after it started. Leaving the app — to fetch a one-time code,
say — is not abandonment: the action stays open and `action.ended`
reports how often and how long the app was in the background.

## Naming

Use a small fixed set of names. Past 50 distinct names in a session, new
names are recorded as `"_other"`, so `"checkout-\(orderId)"` loses its
name. Keep personal data out of `fail(reason:)`; it is sent as free
text.

## Idempotency

`complete()` and `fail(reason:)` record once — second and subsequent
calls, and any call after the action was abandoned, are no-ops.
