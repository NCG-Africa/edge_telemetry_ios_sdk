// Sources/EdgeRumCore/Context/AppContext.swift
//
// Snapshot of the host application's identity attributes. Populated
// from `Bundle.main` Info.plist keys at `Recorder.start()` time and
// the `EdgeRumConfig` overrides (appName/appVersion/etc).
//
// Wire keys (CLAUDE.md "EdgeTelemetryProcessor contract"):
//   app.name             — CFBundleDisplayName, fall back to CFBundleName
//   app.package_name     — CFBundleIdentifier
//   app.version          — CFBundleShortVersionString
//   app.build_number     — CFBundleVersion   (omitted when nil)
//   app.environment      — from config.environment
//
// Refs: PLAN-iOS.md §7.5, §F3/T3.3.
//

import Foundation

public struct AppContext: Sendable, Hashable {

    public var name: String?
    public var packageName: String?
    public var version: String?
    public var buildNumber: String?
    public var environment: String?

    public init(
        name: String? = nil,
        packageName: String? = nil,
        version: String? = nil,
        buildNumber: String? = nil,
        environment: String? = nil
    ) {
        self.name = name
        self.packageName = packageName
        self.version = version
        self.buildNumber = buildNumber
        self.environment = environment
    }

    /// Read the host app's Info.plist via `Bundle.main`. The
    /// `EdgeRumConfig`-supplied overrides take precedence over the
    /// Info.plist reads — host apps that ship a private build with
    /// no version key can still set `appVersion` explicitly.
    public static func snapshot(
        bundle: Bundle = .main,
        appNameOverride: String? = nil,
        appVersionOverride: String? = nil,
        appPackageOverride: String? = nil,
        appBuildOverride: String? = nil,
        environment: String? = nil
    ) -> AppContext {
        let plist = bundle.infoDictionary ?? [:]

        let name = appNameOverride
            ?? plist["CFBundleDisplayName"] as? String
            ?? plist["CFBundleName"] as? String

        let packageName = appPackageOverride
            ?? bundle.bundleIdentifier
            ?? plist["CFBundleIdentifier"] as? String

        let version = appVersionOverride
            ?? plist["CFBundleShortVersionString"] as? String

        let buildNumber = appBuildOverride
            ?? plist["CFBundleVersion"] as? String

        return AppContext(
            name: name,
            packageName: packageName,
            version: version,
            buildNumber: buildNumber,
            environment: environment
        )
    }

    public func write(into bag: inout AttributeBag) {
        bag.setIfPresent("app.name", name.map { .string($0) })
        bag.setIfPresent("app.package_name", packageName.map { .string($0) })
        bag.setIfPresent("app.version", version.map { .string($0) })
        bag.setIfPresent("app.build_number", buildNumber.map { .string($0) })
        bag.setIfPresent("app.environment", environment.map { .string($0) })
    }
}
