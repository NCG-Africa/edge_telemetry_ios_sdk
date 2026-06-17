// Samples/EdgeRumCrashSampleApp/EdgeRumCrashSampleApp/CrashHomeScreen.swift
//
// Four-button QA harness for the F14 crash backend.
//
// Each button intentionally takes the host process down. None of the
// callsites use private API; the crashes are pure Swift / Cocoa.
//

import SwiftUI
import EdgeRum

struct CrashHomeScreen: View {

    @State private var lastSessionId: String = EdgeRum.sessionId

    var body: some View {
        NavigationView {
            VStack(spacing: 18) {
                Text("F14 — Native crash sample")
                    .font(.title2.weight(.semibold))

                Text("Session: \(lastSessionId)")
                    .font(.footnote.monospaced())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(6)

                Group {
                    Button("Crash with SIGSEGV", action: crashWithSegv)
                        .buttonStyle(.borderedProminent)
                    Button("Crash with SIGABRT (fatalError)", action: crashWithAbort)
                        .buttonStyle(.borderedProminent)
                    Button("Crash with NSException", action: crashWithException)
                        .buttonStyle(.borderedProminent)
                    Button("Trigger 10s hang (F15 preview)", action: triggerHang)
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity)

                Spacer()

                Text("After the crash, relaunch the app and watch Console.app for an `app.crash` event carrying THIS session id.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .padding()
            .navigationTitle("EdgeRum crash QA")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            // Re-read in case the host app rotated the session before
            // the view appeared (unlikely, but keeps the label honest).
            lastSessionId = EdgeRum.sessionId
        }
    }

    // MARK: - Crash buttons

    private func crashWithSegv() {
        // Null-pointer write → SIGSEGV / EXC_BAD_ACCESS.
        let p: UnsafeMutablePointer<Int>? = nil
        p!.pointee = 0
    }

    private func crashWithAbort() {
        fatalError("F14 sample — intentional crash via fatalError")
    }

    private func crashWithException() {
        NSException(
            name: .invalidArgumentException,
            reason: "F14 sample — intentional NSException",
            userInfo: nil
        ).raise()
    }

    private func triggerHang() {
        // Sleeps the main thread past EdgeRumConfig.hangTimeout (default
        // 5.0s). F15's hang detector will fire once it lands.
        Thread.sleep(forTimeInterval: 10)
    }
}
