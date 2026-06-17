import XCTest
@testable import EdgeRum

/// `UserContext` is the host-app user profile attached via
/// `EdgeRum.identify(_:)`. The test confirms the field shape and the
/// equality semantics callers rely on.
///
/// Refs: PLAN-iOS.md §3.2, §F2/T2.4.
final class UserContextTests: XCTestCase {

    func testDefaultInitLeavesEveryFieldNil() {
        let user = UserContext()
        XCTAssertNil(user.id)
        XCTAssertNil(user.name)
        XCTAssertNil(user.email)
        XCTAssertNil(user.phone)
    }

    func testFullInitPopulatesEveryField() {
        let user = UserContext(
            id: "user-123",
            name: "Asha",
            email: "asha@example.com",
            phone: "+254700000000"
        )
        XCTAssertEqual(user.id, "user-123")
        XCTAssertEqual(user.name, "Asha")
        XCTAssertEqual(user.email, "asha@example.com")
        XCTAssertEqual(user.phone, "+254700000000")
    }

    func testEqualityIsValueBased() {
        let a = UserContext(id: "1", name: "A")
        let b = UserContext(id: "1", name: "A")
        let c = UserContext(id: "1", name: "B")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    func testCanLiveInsideASet() {
        let users: Set<UserContext> = [
            UserContext(id: "1"),
            UserContext(id: "1"),
            UserContext(id: "2")
        ]
        XCTAssertEqual(users.count, 2)
    }
}
