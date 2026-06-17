import XCTest
@testable import EdgeRum
@testable import EdgeRumCore
#if canImport(UIKit)
import UIKit
#endif

/// Unit tests for `AccessibilityContext` — F16/T16.2's UIAccessibility
/// snapshot.
///
/// Refs: PLAN-iOS.md §16.4 / F16 / T16.2; docs/data-flow.md §3.2.
final class AccessibilityContextTests: XCTestCase {

    // MARK: write(into:)

    func testWriteEmitsAllFiveKeysWhenPresent() {
        let ctx = AccessibilityContext(
            dynamicType: "L",
            reduceMotion: false,
            boldText: true,
            voiceOver: false,
            increaseContrast: true
        )
        var bag = AttributeBag()
        ctx.write(into: &bag)
        XCTAssertEqual(bag["device.dynamic_type"], .string("L"))
        XCTAssertEqual(bag["device.reduce_motion"], .bool(false))
        XCTAssertEqual(bag["device.bold_text"], .bool(true))
        XCTAssertEqual(bag["device.voiceover"], .bool(false))
        XCTAssertEqual(bag["device.increase_contrast"], .bool(true))
        XCTAssertEqual(bag.count, 5)
    }

    func testWriteOmitsAllKeysWhenNil() {
        let ctx = AccessibilityContext()
        var bag = AttributeBag()
        ctx.write(into: &bag)
        XCTAssertTrue(bag.isEmpty)
    }

    func testWriteEmitsOnlyDynamicTypeWhenOthersNil() {
        let ctx = AccessibilityContext(dynamicType: "XXXL")
        var bag = AttributeBag()
        ctx.write(into: &bag)
        XCTAssertEqual(bag["device.dynamic_type"], .string("XXXL"))
        XCTAssertNil(bag["device.reduce_motion"])
        XCTAssertEqual(bag.count, 1)
    }

    // MARK: dynamicTypeString mapping

    #if canImport(UIKit)
    func testDynamicTypeMappingStandardCategories() {
        XCTAssertEqual(AccessibilityContext.dynamicTypeString(.extraSmall), "XS")
        XCTAssertEqual(AccessibilityContext.dynamicTypeString(.small), "S")
        XCTAssertEqual(AccessibilityContext.dynamicTypeString(.medium), "M")
        XCTAssertEqual(AccessibilityContext.dynamicTypeString(.large), "L")
        XCTAssertEqual(AccessibilityContext.dynamicTypeString(.extraLarge), "XL")
        XCTAssertEqual(AccessibilityContext.dynamicTypeString(.extraExtraLarge), "XXL")
        XCTAssertEqual(AccessibilityContext.dynamicTypeString(.extraExtraExtraLarge), "XXXL")
    }

    func testDynamicTypeMappingAccessibilityCategories() {
        XCTAssertEqual(AccessibilityContext.dynamicTypeString(.accessibilityMedium), "AX1")
        XCTAssertEqual(AccessibilityContext.dynamicTypeString(.accessibilityLarge), "AX2")
        XCTAssertEqual(AccessibilityContext.dynamicTypeString(.accessibilityExtraLarge), "AX3")
        XCTAssertEqual(AccessibilityContext.dynamicTypeString(.accessibilityExtraExtraLarge), "AX4")
        XCTAssertEqual(AccessibilityContext.dynamicTypeString(.accessibilityExtraExtraExtraLarge), "AX5")
    }

    func testDynamicTypeMappingUnknownCategoryFallsBackToL() {
        let unknown = UIContentSizeCategory(rawValue: "UIContentSizeCategorySomethingTotallyMade")
        XCTAssertEqual(AccessibilityContext.dynamicTypeString(unknown), "L")
    }
    #endif

    // MARK: snapshot()

    #if canImport(UIKit)
    func testSnapshotProducesAllFiveFieldsOnUIKitHost() {
        let ctx = AccessibilityContext.snapshot()
        XCTAssertNotNil(ctx.dynamicType, "dynamicType must be populated on UIKit hosts")
        XCTAssertNotNil(ctx.reduceMotion)
        XCTAssertNotNil(ctx.boldText)
        XCTAssertNotNil(ctx.voiceOver)
        XCTAssertNotNil(ctx.increaseContrast)
    }
    #endif

    func testSnapshotDoesNotCrashOffMainThread() {
        let exp = expectation(description: "off-main snapshot")
        DispatchQueue.global(qos: .utility).async {
            _ = AccessibilityContext.snapshot()
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
    }
}
