// Samples/EdgeRumCrashSampleApp/EdgeRumCrashSampleApp/EdgeRumCrashSampleApp.swift
//
// F14 manual-QA app. Four buttons trigger the crash classes the
// PLCrashReporter integration catches (SIGSEGV / SIGABRT /
// NSException) plus a long Thread.sleep that exercises the F15 hang
// detector once it lands. Use this app to walk the
// crash → relaunch → replay round-trip end to end.
//
// Manual QA loop (PLAN-iOS §13.3):
//   1. Launch the app.
//   2. Note the active `session.id` in Console.app (filter subsystem
//      `com.edge.rum`, look for `session.started`).
//   3. Tap one of the crash buttons; confirm the app terminates.
//   4. Relaunch the app.
//   5. Verify the FIRST emitted batch contains a single `app.crash`
//      event carrying:
//        - `eventName = "app.crash"`
//        - `cause = "NativeCrash"`
//        - `crash.fatal = true`
//        - `session.id` == the id captured in step 2 (NOT the new
//          session's id)
//        - `crash.report_json` that parses back to JSON
//

import SwiftUI
import EdgeRum

@main
struct EdgeRumCrashSampleApp: App {

    init() {
        var config = EdgeRumConfig(
            apiKey: "edge_sample_replace_me",
            endpoint: URL(string: "https://localhost/collector")!
        )
        config.appName = "EdgeRumCrashSample"
        config.appVersion = "1.0.0"
        config.environment = .development
        // debug = true relaxes the https-scheme precondition so the
        // placeholder endpoint above doesn't crash the app on launch.
        // Set this to false when pointing at a real https collector.
        config.debug = true
        // captureNativeCrashes defaults to `true`; pinned here so the
        // sample stays self-documenting.
        config.captureNativeCrashes = true
        EdgeRum.start(config)
    }

    var body: some Scene {
        WindowGroup {
            CrashHomeScreen()
        }
    }
}
