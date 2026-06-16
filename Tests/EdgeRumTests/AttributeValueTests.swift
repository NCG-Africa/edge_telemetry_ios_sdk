import XCTest
@testable import EdgeRum

/// Covers the public attribute value enum: literal conformances,
/// `Hashable` semantics, and the basic guarantees `Sendable` adds.
///
/// Refs: PLAN-iOS.md §3.2, §F2/T2.3.
final class AttributeValueTests: XCTestCase {

    // MARK: - Literal conformances

    func testStringLiteralBecomesStringCase() {
        let value: AttributeValue = "hello"
        XCTAssertEqual(value, .string("hello"))
    }

    func testIntegerLiteralBecomesIntCase() {
        let value: AttributeValue = 42
        XCTAssertEqual(value, .int(42))
    }

    func testFloatLiteralBecomesDoubleCase() {
        let value: AttributeValue = 3.14
        XCTAssertEqual(value, .double(3.14))
    }

    func testBooleanLiteralBecomesBoolCase() {
        let valueTrue: AttributeValue = true
        let valueFalse: AttributeValue = false
        XCTAssertEqual(valueTrue, .bool(true))
        XCTAssertEqual(valueFalse, .bool(false))
    }

    func testDictionaryLiteralComposesEveryCase() {
        let attributes: [String: AttributeValue] = [
            "cart.size": 3,
            "cart.total": 49.95,
            "user.is_member": true,
            "ab.bucket": "treatment"
        ]
        XCTAssertEqual(attributes["cart.size"], .int(3))
        XCTAssertEqual(attributes["cart.total"], .double(49.95))
        XCTAssertEqual(attributes["user.is_member"], .bool(true))
        XCTAssertEqual(attributes["ab.bucket"], .string("treatment"))
    }

    // MARK: - Hashable

    func testEqualCasesHashEqually() {
        let a: AttributeValue = .int(7)
        let b: AttributeValue = .int(7)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    func testDifferentCasesAreNotEqual() {
        XCTAssertNotEqual(AttributeValue.string("1"), AttributeValue.int(1))
        XCTAssertNotEqual(AttributeValue.int(1), AttributeValue.double(1.0))
        XCTAssertNotEqual(AttributeValue.bool(true), AttributeValue.string("true"))
    }

    func testCanRoundTripThroughASet() {
        let set: Set<AttributeValue> = [.string("a"), .string("a"), .int(1), .bool(true)]
        XCTAssertEqual(set.count, 3, "Duplicate .string('a') must collapse")
    }

    // MARK: - Sendable (compile-only check)

    func testSendableConformance() {
        // If the enum stopped being Sendable, this generic constraint
        // would fail to compile — the test failing at build time is
        // the assertion.
        requireSendable(AttributeValue.string("x"))
    }

    private func requireSendable<T: Sendable>(_ value: T) {
        _ = value
    }
}
