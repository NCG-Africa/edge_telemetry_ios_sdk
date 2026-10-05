// Samples/EdgeRumSampleApp/EdgeRumSampleApp/AppDelegate.swift
//
// Minimal UIKit host that mirrors the README's "5-minute quickstart"
// AppDelegate variant. EdgeRum.start(_:) is called once at launch with
// placeholder identity values; the SDK arms its capture stack, attaches
// to URLSession, and starts pushing the JSON `telemetry_batch` envelope
// at the first flush tick.
//
// Background-flush forwarding (PLAN-iOS.md §5.5) is wired through
// application(_:handleEventsForBackgroundURLSession:completionHandler:)
// so any pending background uploads finish after process death.
//
// Refs: PLAN-iOS.md §12.3; CLAUDE.md "Session and ID rules".

import UIKit
import EdgeRum

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // API key is injected at build time from Secrets.xcconfig
        // (EDGE_RUM_API_KEY → Info.plist). Copy Secrets.local.xcconfig
        // and set your real key there — it is gitignored, never committed.
        // Falls back to the placeholder so a fresh clone still builds.
        let apiKey = Bundle.main.object(forInfoDictionaryKey: "EdgeRumAPIKey") as? String ?? "edge_REPLACE_ME"
        var config = EdgeRumConfig(
            apiKey: apiKey,
            endpoint: URL(string: "https://telemetry.ncgafrica.com")!
        )
        config.appName = "EdgeRum Sample (UIKit)"
        config.appPackage = Bundle.main.bundleIdentifier
        config.appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
        config.appBuild = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "1"
        config.environment = .development
        config.debug = true
        EdgeRum.start(config)

        // F19 / T19.7 — kick the 30 Hz event generator when the
        // performance UI test launches us.
        if isPerformanceUITestRun() {
            PerformanceHarness.shared.start()
        }
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        EdgeRum.handleBackgroundEvents(
            identifier: identifier,
            completion: completionHandler
        )
    }
}
