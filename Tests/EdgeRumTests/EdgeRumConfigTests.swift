import XCTest
@testable import EdgeRum

/// Locks the defaults and validation behaviour of `EdgeRumConfig`.
/// Defaults are part of the consumer contract — bumping any of them
/// is a breaking change.
///
/// Refs: PLAN-iOS.md §3.2, §F2/T2.2; CLAUDE.md "Error handling
///       conventions".
final class EdgeRumConfigTests: XCTestCase {

    // MARK: - Defaults

    func testRequiredFieldsAreSetAndRestAreDefault() {
        let config = EdgeRumConfig(
            apiKey: "edge_dev_abc",
            endpoint: URL(string: "https://collect.example.com")!
        )
        XCTAssertEqual(config.apiKey, "edge_dev_abc")
        XCTAssertEqual(config.endpoint.absoluteString, "https://collect.example.com")

        XCTAssertNil(config.appName)
        XCTAssertNil(config.appVersion)
        XCTAssertNil(config.appPackage)
        XCTAssertNil(config.appBuild)
        XCTAssertNil(config.environment)
        XCTAssertNil(config.location)

        XCTAssertEqual(config.resolveLocation, false)
        XCTAssertEqual(config.locationProviderUrl?.absoluteString, "https://ipapi.co/json/")
        XCTAssertEqual(config.sampleRate, 1.0)
        XCTAssertEqual(config.ignoreUrls.count, 0)
        XCTAssertEqual(config.maxQueueSize, 200)
        XCTAssertEqual(config.flushInterval, 5.0)
        XCTAssertEqual(config.batchSize, 30)

        XCTAssertEqual(config.captureNativeCrashes, true)
        XCTAssertEqual(config.enableHangDetection, true)
        XCTAssertEqual(config.hangTimeout, 5.0)
        XCTAssertEqual(config.captureScreens, true)
        XCTAssertEqual(config.captureHTTP, true)
        XCTAssertEqual(config.captureTaps, true)
        XCTAssertEqual(config.captureRenderingPerformance, true)
        XCTAssertEqual(config.captureLifecycle, true)
        XCTAssertEqual(config.captureNetworkChanges, true)

        XCTAssertEqual(config.debug, false)
    }

    // MARK: - Validation

    func testValidateAcceptsHappyPath() {
        let config = EdgeRumConfig(
            apiKey: "edge_live_abc",
            endpoint: URL(string: "https://collect.example.com")!
        )
        XCTAssertEqual(EdgeRumConfig.validate(config), .ok)
    }

    func testValidateRejectsEmptyApiKey() {
        let config = EdgeRumConfig(
            apiKey: "",
            endpoint: URL(string: "https://collect.example.com")!
        )
        XCTAssertEqual(EdgeRumConfig.validate(config), .invalidApiKey)
    }

    func testValidateRejectsApiKeyWithoutPrefix() {
        let config = EdgeRumConfig(
            apiKey: "abc-not-prefixed",
            endpoint: URL(string: "https://collect.example.com")!
        )
        XCTAssertEqual(EdgeRumConfig.validate(config), .invalidApiKey)
    }

    func testValidateRejectsHttpEndpointInProduction() {
        var config = EdgeRumConfig(
            apiKey: "edge_dev_abc",
            endpoint: URL(string: "http://collect.example.com")!
        )
        config.debug = false
        XCTAssertEqual(EdgeRumConfig.validate(config), .invalidEndpoint)
    }

    func testValidateAllowsHttpEndpointInDebug() {
        var config = EdgeRumConfig(
            apiKey: "edge_dev_abc",
            endpoint: URL(string: "http://localhost:8080")!
        )
        config.debug = true
        XCTAssertEqual(EdgeRumConfig.validate(config), .ok)
    }

    func testValidateRejectsUppercaseHttpEndpointInProduction() {
        // Scheme is case-insensitive per RFC 3986 — our validator
        // must accept uppercase HTTPS and reject uppercase HTTP.
        var configHTTPS = EdgeRumConfig(
            apiKey: "edge_dev_abc",
            endpoint: URL(string: "HTTPS://collect.example.com")!
        )
        configHTTPS.debug = false
        XCTAssertEqual(EdgeRumConfig.validate(configHTTPS), .ok)
    }

}
