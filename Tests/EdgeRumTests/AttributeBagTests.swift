import XCTest
@testable import EdgeRum
import EdgeRumCore

/// Unit tests for `AttributeBag` — the flat key→primitive container
/// used everywhere inside EdgeRumCore. Coverage centres on the
/// `merging(_:)` semantics ("event attrs win") that the Recorder
/// relies on at every `recordEvent` call.
///
/// Refs: PLAN-iOS.md §7.6, §F3/T3.2.
final class AttributeBagTests: XCTestCase {

    func testEmptyBagInitialState() {
        let bag = AttributeBag()
        XCTAssertTrue(bag.isEmpty)
        XCTAssertEqual(bag.count, 0)
    }

    func testDictionaryLiteral() {
        let bag: AttributeBag = ["session.id": "abc", "session.sequence": 12]
        XCTAssertEqual(bag["session.id"], .string("abc"))
        XCTAssertEqual(bag["session.sequence"], .int(12))
        XCTAssertEqual(bag.count, 2)
    }

    func testSubscriptSetAndGet() {
        var bag = AttributeBag()
        bag["app.name"] = .string("Shop")
        XCTAssertEqual(bag["app.name"], .string("Shop"))
        XCTAssertNil(bag["app.unknown"])
    }

    func testSetIfPresentSkipsNil() {
        var bag = AttributeBag()
        bag.setIfPresent("app.version", nil)
        bag.setIfPresent("app.name", .string("Shop"))
        XCTAssertNil(bag["app.version"])
        XCTAssertEqual(bag["app.name"], .string("Shop"))
    }

    // MARK: merging — "event attrs win on conflict"

    func testMergingWithEmptyOtherIsIdentity() {
        let bag: AttributeBag = ["app.name": "Shop"]
        let merged = bag.merging(AttributeBag())
        XCTAssertEqual(merged["app.name"], .string("Shop"))
        XCTAssertEqual(merged.count, 1)
    }

    func testMergingDisjointKeysUnions() {
        let context: AttributeBag = ["app.name": "Shop", "device.platform": "ios"]
        let event: AttributeBag = ["http.method": "GET", "http.status_code": 200]
        let merged = context.merging(event)
        XCTAssertEqual(merged.count, 4)
        XCTAssertEqual(merged["app.name"], .string("Shop"))
        XCTAssertEqual(merged["http.method"], .string("GET"))
        XCTAssertEqual(merged["http.status_code"], .int(200))
    }

    func testMergingEventWinsOnConflict() {
        let context: AttributeBag = ["sample.key": "context_value"]
        let event: AttributeBag = ["sample.key": "event_value"]
        let merged = context.merging(event)
        XCTAssertEqual(merged["sample.key"], .string("event_value"),
                       "Event attrs MUST win on conflict — CLAUDE.md step 2")
    }

    func testMergingFromDictionaryLiteralPath() {
        let context: AttributeBag = ["k": "context"]
        let merged = context.merging(["k": "event", "extra": 1])
        XCTAssertEqual(merged["k"], .string("event"))
        XCTAssertEqual(merged["extra"], .int(1))
    }

    func testMergeIsMutatingEquivalent() {
        var bag: AttributeBag = ["a": 1]
        bag.merge(["a": 2, "b": 3])
        XCTAssertEqual(bag["a"], .int(2))
        XCTAssertEqual(bag["b"], .int(3))
    }
}
