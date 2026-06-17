# Identify a user

Attach a host-app user identity to subsequent events.

## Overview

Call ``EdgeRum/identify(_:)`` once you have established who the user is
— typically right after login. The values you pass become additional
attributes on every following event under the `user.*` namespace; they
do **not** replace the SDK-owned anonymous `user.id` (see
<doc:Privacy>).

```swift
import EdgeRum

func didFinishLogin(user: AccountUser) {
    EdgeRum.identify(UserContext(
        id: user.accountId,
        name: user.displayName,
        email: user.email
    ))
}
```

## Clearing on logout

`UserContext` fields are all optional. Pass an empty `UserContext()` to
clear the host-app values back to nil; the SDK-owned anonymous
identifier carries on unchanged.

```swift
func didLogOut() {
    EdgeRum.identify(UserContext())
}
```

## Calling order

Calling ``EdgeRum/identify(_:)`` before ``EdgeRum/start(_:)`` is a
no-op with a warning emitted via `os_log`. Defer the call until the
host app has run its `start(_:)` hook — usually on the very first frame
after login completes.
