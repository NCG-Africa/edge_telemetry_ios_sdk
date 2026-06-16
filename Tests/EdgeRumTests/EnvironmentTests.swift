import XCTest
@testable import EdgeRum

/// Pins the wire representation of `Environment`. The backend already
/// indexes the three strings emitted by the web and Android SDKs;
/// drift would silently mis-classify iOS traffic.
///
/// Refs: PLAN-iOS.md §3.2, §F2/T2.4.
final class EnvironmentTests: XCTestCase {

    func testRawValuesMatchTheBackendContract() {
        XCTAssertEqual(Environment.production.rawValue, "production")
        XCTAssertEqual(Environment.staging.rawValue, "staging")
        XCTAssertEqual(Environment.development.rawValue, "development")
    }

    func testRoundTripFromRawValue() {
        XCTAssertEqual(Environment(rawValue: "production"), .production)
        XCTAssertEqual(Environment(rawValue: "staging"), .staging)
        XCTAssertEqual(Environment(rawValue: "development"), .development)
        XCTAssertNil(Environment(rawValue: "prod"))
        XCTAssertNil(Environment(rawValue: ""))
    }

    func testAllCasesExposesAllThree() {
        XCTAssertEqual(
            Set(Environment.allCases),
            [.production, .staging, .development]
        )
    }

    func testHashableEquality() {
        XCTAssertEqual(Environment.staging, Environment.staging)
        XCTAssertEqual(Environment.staging.hashValue, Environment.staging.hashValue)
        XCTAssertNotEqual(Environment.staging, Environment.production)
    }
}
