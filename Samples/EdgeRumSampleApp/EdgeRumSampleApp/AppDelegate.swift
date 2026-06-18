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
        var config = EdgeRumConfig(
            apiKey: "edge_sample_replace_me",
            endpoint: URL(string: "https://localhost/collector")!
        )
        config.appName = "EdgeRum Sample (UIKit)"
        config.appPackage = Bundle.main.bundleIdentifier
        config.appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
        config.appBuild = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "1"
        config.environment = .development
        config.debug = true
        EdgeRum.start(config)
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
