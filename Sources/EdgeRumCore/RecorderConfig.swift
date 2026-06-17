// Sources/EdgeRumCore/RecorderConfig.swift
//
// Thin Sendable mirror of `EdgeRumConfig` that the internal Recorder
// understands. EdgeRumCore cannot import the public umbrella module
// (the dependency edge points the other way), so the public surface
// projects the subset of `EdgeRumConfig` the Recorder actually needs
// into this struct via `Recorder.shared.configure(_:)` before
// `start(_:)`.
//
// Refs: PLAN-iOS.md §F2/T2.2 (config), §F3/T3.1 (Recorder configure).
//

import Foundation

public struct RecorderConfig: Sendable, Hashable {

    public var apiKey: String
    public var endpoint: URL
    public var debug: Bool
    public var sampleRate: Double
    public var batchSize: Int
    public var flushInterval: TimeInterval
    public var location: String?
    public var appName: String?
    public var appVersion: String?
    public var appPackage: String?
    public var appBuild: String?
    public var environmentName: String?

    public init(
        apiKey: String,
        endpoint: URL,
        debug: Bool = false,
        sampleRate: Double = 1.0,
        batchSize: Int = 30,
        flushInterval: TimeInterval = 5.0,
        location: String? = nil,
        appName: String? = nil,
        appVersion: String? = nil,
        appPackage: String? = nil,
        appBuild: String? = nil,
        environmentName: String? = nil
    ) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.debug = debug
        self.sampleRate = sampleRate
        self.batchSize = batchSize
        self.flushInterval = flushInterval
        self.location = location
        self.appName = appName
        self.appVersion = appVersion
        self.appPackage = appPackage
        self.appBuild = appBuild
        self.environmentName = environmentName
    }
}
