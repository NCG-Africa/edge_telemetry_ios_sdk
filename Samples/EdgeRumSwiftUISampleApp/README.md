# EdgeRum SwiftUI sample

A minimal SwiftUI app that exercises the public `.edgeRumScreen` and
`.edgeRumTrackTap` view modifiers from the [`EdgeRum`](../../) SDK.

## What it does

- Boots the SDK from `EdgeRumSwiftUISampleApp.init()` with a
  placeholder API key (`"edge_sample_replace_me"`) and a placeholder
  collector endpoint (`https://localhost/collector`). HTTP errors in
  the Xcode console are expected — replace both values to point at a
  real collector.
- `HomeScreen` carries `.edgeRumScreen("Home")` and a `ProductCard`
  with `.edgeRumTrackTap("product_card")`.
- `DetailScreen` carries `.edgeRumScreen("Detail")` and a SwiftUI
  `Button` whose action calls `EdgeRum.track("buy_button", ...)`
  directly — `Button` consumes its touch before any simultaneous tap
  recognizer runs, so `.edgeRumTrackTap` would not fire here.

## Run it

1. Open `EdgeRumSwiftUISampleApp.xcodeproj` in Xcode 16+.
2. Wait for SwiftPM to resolve the SDK from `../..` (the repository
   root).
3. Pick an iOS Simulator destination and Run.

The SDK's `debug == true` logging routes through `os_log` — open
Console.app and filter by subsystem `com.edge.rum` to watch the
emitted events.

## CI

The repository's CI builds this sample on every PR via a `xcodebuild
-destination 'generic/platform=iOS Simulator'` step. See the
`sample-build` job in `.github/workflows/ci.yml`.

## Notes on UIHostingController

If a SwiftUI screen is ALSO presented through a `UIHostingController`
inside a UIKit container, the F6 UIKit swizzle would emit a second
`navigation` event for the hosted controller. To avoid a double-emit
on the same screen, choose one of the two integration paths per
screen — the sample picks the `.edgeRumScreen` modifier path.
