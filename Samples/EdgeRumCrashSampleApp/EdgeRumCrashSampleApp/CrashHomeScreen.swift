// Samples/EdgeRumCrashSampleApp/EdgeRumCrashSampleApp/CrashHomeScreen.swift
//
// Four-button QA harness for the F14 crash backend.
//
// Each button intentionally takes the host process down. None of the
// callsites use private API; the crashes are pure Swift / Cocoa.
//
// F19 / T19.5 additions: when launched with `EDGE_RUM_UITEST=1`, the
// view exposes three accessibility-identified Text labels that the
// XCUI crash-replay test reads:
//
//   - `current.session.id`  → live `EdgeRum.sessionId`
//   - `crashed.session.id`  → the session id captured at crash time
//   - `replay.session.id`   → the session id of the most recent
//                             replayed `app.crash` event (mirrored by
//                             `UITestListener` into UserDefaults)
//
// The labels are also rendered as plain text in the QA build so a
// human walking through the manual flow can sanity-check them.
//

import SwiftUI
import EdgeRum

struct CrashHomeScreen: View {

    @State private var lastSessionId: String = EdgeRum.sessionId
    @State private var replaySessionId: String = ""
    @State private var replayCause: String = ""
    @State private var replayFatal: String = ""
    @State private var crashedSessionId: String = ""
    @State private var pollTimer: Timer?

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
                    .accessibilityIdentifier("current.session.id")
                    .accessibilityLabel(lastSessionId)

                if isCrashUITestRun() {
                    uiTestDebugPanel
                }

                Group {
                    Button("Crash with SIGSEGV", action: crashWithSegv)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("button.crash.segv")
                    Button("Crash with SIGABRT (fatalError)", action: crashWithAbort)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("button.crash.abort")
                    Button("Crash with NSException", action: crashWithException)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("button.crash.nsexception")
                    Button("Trigger 6 s main-thread hang (F15)", action: triggerHang)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("button.hang")
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
            if isCrashUITestRun() {
                refreshUITestState()
                pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
                    DispatchQueue.main.async { refreshUITestState() }
                }
            }
        }
        .onDisappear {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    // MARK: - UI test debug panel

    private var uiTestDebugPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("UI-test mirror")
                .font(.caption.weight(.semibold))
            HStack {
                Text("crashed:")
                Text(crashedSessionId.isEmpty ? "(none)" : crashedSessionId)
                    .accessibilityIdentifier("crashed.session.id")
                    .accessibilityLabel(crashedSessionId)
            }
            .font(.caption2.monospaced())
            HStack {
                Text("replay:")
                Text(replaySessionId.isEmpty ? "(none)" : replaySessionId)
                    .accessibilityIdentifier("replay.session.id")
                    .accessibilityLabel(replaySessionId)
            }
            .font(.caption2.monospaced())
            HStack {
                Text("cause:")
                Text(replayCause.isEmpty ? "(none)" : replayCause)
                    .accessibilityIdentifier("replay.cause")
                    .accessibilityLabel(replayCause)
            }
            .font(.caption2.monospaced())
            HStack {
                Text("fatal:")
                Text(replayFatal.isEmpty ? "(none)" : replayFatal)
                    .accessibilityIdentifier("replay.fatal")
                    .accessibilityLabel(replayFatal)
            }
            .font(.caption2.monospaced())
        }
        .padding(8)
        .background(Color.yellow.opacity(0.15))
        .cornerRadius(6)
    }

    private func refreshUITestState() {
        let d = CrashUITestStorage.defaults()
        crashedSessionId = d.string(forKey: CrashUITestStorage.crashedSessionIdKey) ?? ""
        replaySessionId  = d.string(forKey: CrashUITestStorage.replaySessionIdKey) ?? ""
        replayCause      = d.string(forKey: CrashUITestStorage.replayCauseKey) ?? ""
        if d.object(forKey: CrashUITestStorage.replayFatalKey) == nil {
            replayFatal = ""
        } else {
            replayFatal = d.bool(forKey: CrashUITestStorage.replayFatalKey) ? "true" : "false"
        }
    }

    // MARK: - Crash buttons

    private func captureSessionBeforeCrash() {
        guard isCrashUITestRun() else { return }
        let d = CrashUITestStorage.defaults()
        d.set(EdgeRum.sessionId, forKey: CrashUITestStorage.crashedSessionIdKey)
        d.synchronize()
    }

    private func crashWithSegv() {
        captureSessionBeforeCrash()
        // Null-pointer write → SIGSEGV / EXC_BAD_ACCESS.
        let p: UnsafeMutablePointer<Int>? = nil
        p!.pointee = 0
    }

    private func crashWithAbort() {
        captureSessionBeforeCrash()
        fatalError("F14 sample — intentional crash via fatalError")
    }

    private func crashWithException() {
        captureSessionBeforeCrash()
        NSException(
            name: .invalidArgumentException,
            reason: "F14 sample — intentional NSException",
            userInfo: nil
        ).raise()
    }

    private func triggerHang() {
        captureSessionBeforeCrash()
        // Sleeps the main thread past EdgeRumConfig.hangTimeout (default
        // 5.0s). F15's HangDetector will fire one `app.crash` event
        // with `cause = "Hang"`, `crash.thread.main_stack` populated
        // via the Mach-based snapshot, and `hang.duration_ms` ≥ 6000.
        // The app stays alive afterwards — hangs are non-fatal
        // (`crash.fatal = false`).
        Thread.sleep(forTimeInterval: 6)
    }
}
