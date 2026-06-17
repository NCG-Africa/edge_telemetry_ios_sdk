# EdgeRum crash sample

Manual-QA app for F14 native crash capture. Four buttons take the
host process down via the crash classes the F14 PLCrashReporter
integration catches (Mach signals + uncaught `NSException`) plus a
long `Thread.sleep` for the F15 hang detector preview.

## What it covers

| Button | Triggers | F14 path |
|---|---|---|
| `Crash with SIGSEGV` | Null-pointer write → `EXC_BAD_ACCESS` | Mach exception → PLCR signal record |
| `Crash with SIGABRT (fatalError)` | `fatalError(_:)` | Mach exception → PLCR signal record |
| `Crash with NSException` | `NSException.raise()` | PLCR uncaught-exception handler |
| `Trigger 10s hang (F15 preview)` | `Thread.sleep(forTimeInterval: 10)` | F15 — not yet wired |

## Manual QA loop (PLAN-iOS §13.3)

1. Open the project in Xcode, pick an iOS Simulator or device,
   build, and Run.
2. Note the active `session.id` on screen (also visible in
   Console.app — filter subsystem `com.edge.rum`, look for
   `session.started`).
3. Tap one of the crash buttons; confirm the app terminates.
4. Relaunch the app.
5. Verify the **first** emitted batch contains a single `app.crash`
   event carrying:
   - `eventName = "app.crash"`
   - `cause = "NativeCrash"`
   - `crash.fatal = true`
   - `session.id` == the id captured in step 2 (NOT the new
     session's id)
   - `crash.report_format_version = "edgerum.crash.v1"`
   - `crash.report_json` that parses back to JSON (contains
     `threads`, `binary_images`, `format_version`)

> **Simulator caveat.** PLCrashReporter is configured with Mach
> exception handling (`PLAN-iOS.md` §6.7). Xcode's debugger intercepts
> Mach exceptions on the Simulator before PLCR sees them, so the
> SIGSEGV / SIGABRT paths are most reliable on a real device. The
> NSException path works on both. To reproduce SIGSEGV in the
> Simulator, run the app *without* the debugger attached:
> `xcrun simctl launch <booted> com.example.edge.rum.crashsample`.

## Xcode project

The project file is intentionally **not** checked in to keep the diff
focused. To wire the sources into Xcode:

1. Open `Samples/EdgeRumSwiftUISampleApp/EdgeRumSwiftUISampleApp.xcodeproj`
   in Xcode 16+ (it already has the SwiftPM-resolved `EdgeRum`
   dependency wired up against `../..`).
2. `File → New → Project… → iOS → App` and name it
   `EdgeRumCrashSampleApp`, organisation identifier
   `com.example.edge.rum`, language Swift, interface SwiftUI, life
   cycle SwiftUI App.
3. Save it next to the SwiftUI sample (`Samples/EdgeRumCrashSampleApp/`).
4. Delete the generated `ContentView.swift` and
   `EdgeRumCrashSampleApp.swift`, then **add the source files in this
   directory** (`EdgeRumCrashSampleApp.swift`,
   `CrashHomeScreen.swift`, `Info.plist`) to the target.
5. `File → Add Package Dependencies… → Add Local…` and point at the
   repository root (`../..`). Pick the `EdgeRum` product.
6. Build and Run.

If you'd rather we check in the `.xcodeproj` for review, file a
follow-up; the pattern is documented in ADR-007 (F7 SwiftUI sample
app uses a checked-in `.xcodeproj`).
