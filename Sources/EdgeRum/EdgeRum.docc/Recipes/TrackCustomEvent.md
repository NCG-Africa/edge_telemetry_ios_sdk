# Track a custom event

Emit an arbitrarily-named event from anywhere in the host app.

## Overview

Use ``EdgeRum/track(_:attributes:)`` to record an event that doesn't
fit one of the auto-captured shapes — funnel steps, A/B-test bucket
assignments, business-domain events. The name travels on the wire as
the `event.name` attribute under the `custom_event` channel.

```swift
import EdgeRum

EdgeRum.track("checkout_started", attributes: [
    "cart.size": 3,
    "cart.total": 49.95,
    "user.is_member": true,
    "ab.bucket": "treatment"
])
```

## Attribute shape

Attribute values must be one of ``AttributeValue``'s primitive cases:
`.string`, `.int`, `.double`, `.bool`. The four `ExpressibleBy…Literal`
conformances let you write attributes as plain literals, as in the
snippet above; the type system rejects nested objects and arrays at
compile time so the wire contract holds without runtime validation.

Flatten any structured data at the call site using dot-notation keys —
prefer `"cart.size"` over a `"cart"` map of further keys.

## Naming conventions

Pick stable, snake-case names. The backend dispatcher routes the
event through the `custom_event` channel regardless of the name, but
dashboards group by the literal string you supply — drift across
releases turns one funnel step into two separate metrics.
