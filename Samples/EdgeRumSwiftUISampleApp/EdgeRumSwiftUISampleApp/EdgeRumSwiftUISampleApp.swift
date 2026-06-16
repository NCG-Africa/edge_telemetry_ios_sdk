// Samples/EdgeRumSwiftUISampleApp/EdgeRumSwiftUISampleApp/EdgeRumSwiftUISampleApp.swift
//
// F7 sample app entry point. Boots the SDK against a placeholder
// collector endpoint (you'll see HTTP errors in Xcode's console —
// that is expected; replace the apiKey/endpoint to point at a real
// collector). Two screens exercise the public modifiers:
//
//   - HomeScreen      → .edgeRumScreen("Home") + .edgeRumTrackTap on a card.
//   - DetailScreen    → .edgeRumScreen("Detail") + a Button that calls
//                       EdgeRum.track("buy_button", ...) directly.
//
// Navigate Home → Detail and back to see `screen.duration` fire on
// each disappear in the console log (config.debug == true).
//

import SwiftUI
import EdgeRum

@main
struct EdgeRumSwiftUISampleApp: App {

    init() {
        var config = EdgeRumConfig(
            apiKey: "edge_sample_replace_me",
            endpoint: URL(string: "https://localhost/collector")!
        )
        config.appName = "EdgeRumSwiftUISample"
        config.appVersion = "1.0.0"
        config.environment = .development
        // debug = true relaxes the https-scheme precondition so the
        // placeholder endpoint above doesn't crash the app on launch.
        // Set this to false when pointing at a real https collector.
        config.debug = true
        EdgeRum.start(config)
    }

    var body: some Scene {
        WindowGroup {
            NavigationView {
                HomeScreen()
            }
            // SwiftUI on iOS 14 picks the column style by default on
            // iPad; force a stack to keep the sample identical across
            // device classes.
            .navigationViewStyle(.stack)
        }
    }
}
