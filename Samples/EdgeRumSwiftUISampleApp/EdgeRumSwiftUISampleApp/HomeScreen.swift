// Samples/EdgeRumSwiftUISampleApp/EdgeRumSwiftUISampleApp/HomeScreen.swift
//
// Exercises:
//   - .edgeRumScreen("Home") → emits a `navigation` event on appear
//     and a `screen.duration` performance entry on disappear.
//   - .edgeRumTrackTap on a non-Button view → emits one
//     `user.interaction` event per tap. Buttons consume their touch
//     before any simultaneous tap recognizer runs, so for Button
//     instrumentation we call EdgeRum.track(...) directly in the
//     action closure (see DetailScreen).
//
// Note: if a SwiftUI screen is also presented via UIHostingController
// (e.g. embedded in a UIKit container), the F6 swizzle would emit a
// `navigation` event for that hosted controller as well. To avoid a
// double-emit on the same screen, choose ONE of the two integration
// paths per screen. The sample picks the modifier path.
//

import SwiftUI
import EdgeRum

struct HomeScreen: View {
    var body: some View {
        VStack(spacing: 24) {
            Text("EdgeRum SwiftUI sample")
                .font(.title2)
                .multilineTextAlignment(.center)

            // Non-Button tap-target — .edgeRumTrackTap fires here.
            ProductCard(sku: "SKU-456")
                .edgeRumTrackTap("product_card",
                                 attributes: ["product.id": "SKU-456"])

            NavigationLink("Open detail", destination: DetailScreen())
                .padding()

            NavigationLink("Open network demo", destination: NetworkScreen())
                .padding(.top, 4)
        }
        .padding()
        .edgeRumScreen("Home", attributes: ["funnel.step": 1])
    }
}

struct ProductCard: View {
    let sku: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Product card")
                .font(.headline)
            Text("Tap me — emits user.interaction")
                .font(.footnote)
                .foregroundColor(.secondary)
            Text("SKU: \(sku)")
                .font(.footnote)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(12)
    }
}
