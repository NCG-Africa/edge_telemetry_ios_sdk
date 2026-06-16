import XCTest
@testable import EdgeRum

final class PlaceholderTests: XCTestCase {
    func testSDKVersionIsNonEmpty() {
        XCTAssertFalse(EdgeRum.sdkVersion.isEmpty)
    }
}
