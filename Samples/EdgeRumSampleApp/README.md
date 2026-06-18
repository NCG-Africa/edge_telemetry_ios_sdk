# EdgeRum UIKit sample

A minimal UIKit app demonstrating the F1 → F18 capture surface of the
[`EdgeRum`](../../) SDK from the AppDelegate / SceneDelegate side.

## What it does

- Boots the SDK from `AppDelegate.application(_:didFinishLaunchingWithOptions:)`
  with a placeholder API key (`edge_sample_replace_me`) and a
  placeholder collector endpoint (`https://localhost/collector`).
  Replace both values to point at a real collector.
- **Home → Catalog** — fires two `URLSession.shared.dataTask` requests
  to `httpbin.org` on `viewDidLoad`. Each one is captured as an
  `http.request` event plus a companion `resource_timing` metric.
- **Home → Debug** — six buttons that exercise the public API:
  `track`, `identify`, `time`, `captureError`, `disable`, `enable`.
  Each tap also fires the F9 interaction capture.

`config.debug = true` is set so every emitted event is logged through
`os_log` under the `com.edge.rum` subsystem. Open Console.app and
filter by subsystem to watch the traffic.

## Generate the Xcode project

Unlike the other two samples, this app's `.xcodeproj` is generated
from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen).
The repo ignores `*.xcodeproj/` under `Samples/EdgeRumSampleApp/`;
`project.yml` is the source of truth.

```sh
# Install XcodeGen (one-time).
brew install xcodegen

# Generate the .xcodeproj from project.yml.
./Tools/gen-sample-xcodeproj.sh
```

Then open `Samples/EdgeRumSampleApp/EdgeRumSampleApp.xcodeproj` in
Xcode 16+, wait for SwiftPM to resolve the local `EdgeRum` package
from `../..`, pick an iOS Simulator destination, and Run.

## CI

CI runs `Tools/gen-sample-xcodeproj.sh` followed by `xcodebuild`
against a generic iOS Simulator destination. See the `sample-build`
job in [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml).
