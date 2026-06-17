// Samples/EdgeRumSwiftUISampleApp/EdgeRumSwiftUISampleApp/DetailScreen.swift
//
// Pushing this screen makes HomeScreen disappear, which fires
// HomeScreen's `screen.duration` performance entry. Tapping the
// Button records a custom event via EdgeRum.track(...) — Button
// consumes its own touch so .edgeRumTrackTap would not fire here.
//

import SwiftUI
import EdgeRum

struct DetailScreen: View {
    var body: some View {
        VStack(spacing: 24) {
            Text("Detail")
                .font(.title)
            Text("Pop back to record this screen's dwell on Home.")
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            // Button consumes its touch — instrument the action
            // directly rather than relying on .edgeRumTrackTap.
            Button(action: {
                EdgeRum.track("buy_button",
                              attributes: ["product.id": "SKU-456"])
            }) {
                Text("Record purchase intent")
                    .padding(.horizontal)
                    .padding(.vertical, 8)
            }
        }
        .padding()
        .edgeRumScreen("Detail", attributes: ["funnel.step": 2])
    }
}
