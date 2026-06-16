// Samples/EdgeRumSwiftUISampleApp/EdgeRumSwiftUISampleApp/NetworkScreen.swift
//
// F8 sample — exercises the automatic HTTP capture.
//
// Three buttons fire `URLSession.shared.dataTask` requests at
// `httpbin.org`. With `config.debug = true` the SDK logs the
// emitted `http.request` events and `resource_timing` metrics to
// the system log — open Xcode's console or `log stream
// --predicate 'subsystem == "com.edge.rum"'` to watch them flow.
//
// Note: the SDK's own POST to the configured collector endpoint is
// filtered out by the three defense-in-depth checks (internal header,
// task description marker, endpoint host match). You will not see an
// `http.request` event for it.
//

import SwiftUI
import EdgeRum

struct NetworkScreen: View {

    @State private var lastResult: String = ""

    var body: some View {
        VStack(spacing: 20) {
            Text("Tap a button to fire a real request.\nWatch http.request + resource_timing land in the console.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("Fetch JSON") {
                fire(URL(string: "https://httpbin.org/json")!,
                     label: "Fetch JSON")
            }
            .buttonStyle(.borderedProminent)

            Button("Fetch large payload") {
                fire(URL(string: "https://httpbin.org/bytes/100000")!,
                     label: "Fetch large payload")
            }
            .buttonStyle(.bordered)

            Button("Trigger 404") {
                fire(URL(string: "https://httpbin.org/status/404")!,
                     label: "Trigger 404")
            }
            .buttonStyle(.bordered)

            Text(lastResult)
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
                .padding(.top, 12)

            Spacer()
        }
        .padding()
        .edgeRumScreen("Network")
    }

    private func fire(_ url: URL, label: String) {
        // Direct call into URLSession.shared — F8's URLProtocol
        // registration intercepts these and emits one http.request
        // event plus one resource_timing metric per call.
        URLSession.shared.dataTask(with: url) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    lastResult = "\(label) → error: \(error.localizedDescription)"
                    return
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let bytes = data?.count ?? 0
                lastResult = "\(label) → \(status), \(bytes) bytes"
            }
        }.resume()
    }
}
