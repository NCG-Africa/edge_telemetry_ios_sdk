# Time an operation

Measure the wall-clock duration of a chunk of host-app code.

## Overview

Call ``EdgeRum/time(_:)`` at the start of the work and `end()` on the
returned ``RumTimer`` when it finishes. The SDK records one
performance data point named after the original argument, with
`duration_ms` merged in automatically.

```swift
import EdgeRum

let timer = EdgeRum.time("checkout.submit")
performCheckout { result in
    timer.end(attributes: [
        "payment.method": "card",
        "checkout.outcome": result.isSuccess ? "ok" : "fail"
    ])
}
```

## Idempotency

`RumTimer.end()` records exactly once — second and subsequent calls
are no-ops. `RumTimer.cancel()` discards the timer without recording;
calling `cancel()` after `end()`, or `end()` after `cancel()`, is also
a no-op. The timer is safe to thread across closures, completion
handlers, and `async let` boundaries.

## Async / await

In `async` code the same pattern works without modification — the
timer captures the start moment on construction and the end moment on
the `end()` call, regardless of how the host suspends in between:

```swift
let timer = EdgeRum.time("api.fetch_products")
do {
    let products = try await api.fetchProducts()
    timer.end(attributes: ["product.count": products.count])
} catch {
    timer.end(attributes: ["error.kind": "fetch_failed"])
    EdgeRum.captureError(error)
}
```
