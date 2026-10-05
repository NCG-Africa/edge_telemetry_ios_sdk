# Capture a handled error

Report a thrown `Error` from a `do / catch` block.

## Overview

Use ``EdgeRum/captureError(_:context:)`` to record an
`app.error` event for any `Error` your code catches. The SDK flattens
the error's type (`error.class`), domain (for `NSError`), code, and
`localizedDescription` automatically; the call-site stack is
snapshotted synchronously before the queue handoff so the frames in
`error.stack` match the throw site. Frames read
`image +0x<offset> <hint>`, with the referenced images listed in
`error.binary_images`.

`app.error` follows ``EdgeRumConfig/sampleRate`` and ships with the
next normal flush; it does not force an immediate upload.

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
`error.*` payload. Because of that prefix, these keys are exempt from
the reserved-prefix rule that drops SDK-namespaced keys from other
attribute maps.

Values must conform to ``AttributeValue``, matching the rule for every
other public API entry point — primitives only, no nesting.

## When not to use it

For *unhandled* throws or runtime traps, the F14 PLCrashReporter
integration captures the crash automatically and replays it on the
next launch. `captureError` is the explicit path for errors your code
*has* caught and wants tagged with semantic context. Do not call it
from a `fatalError` site — the SDK will not have time to flush before
the process terminates.
