# Capture a handled error

Report a thrown `Error` from a `do / catch` block.

## Overview

Use ``EdgeRum/captureError(_:context:)`` to attach an
`app.crash` event with `cause = "AppError"` for any `Error` your code
catches. The SDK flattens the error's type, domain (for `NSError`),
code, and `localizedDescription` automatically; the call-site stack is
snapshotted synchronously before the queue handoff so the frames in
the report match the throw site.

```swift
import EdgeRum

do {
    try submitOrder()
} catch {
    EdgeRum.captureError(error, context: [
        "payment.method": "card",
        "checkout.step": "submit"
    ])
}
```

## Context attributes

The `context` map is intended for the call-site state that the error
itself cannot carry — what the user was doing, what cart they had,
which experiment bucket they were in. Each key is prefixed
`crash.context.` on the wire so it cannot collide with the standard
`error.*` payload.

Values must conform to ``AttributeValue``, matching the rule for every
other public API entry point — primitives only, no nesting.

## When not to use it

For *unhandled* throws or runtime traps, the F14 PLCrashReporter
integration captures the crash automatically and replays it on the
next launch. `captureError` is the explicit path for errors your code
*has* caught and wants tagged with semantic context. Do not call it
from a `fatalError` site — the SDK will not have time to flush before
the process terminates.
