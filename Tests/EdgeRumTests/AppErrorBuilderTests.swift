import XCTest
@testable import EdgeRum
import EdgeRumCore

/// Unit coverage for the pure F13 attribute builder.
///
/// Refs: PLAN-iOS.md §6.6, §F13/T13.1, §F13/T13.2.
final class AppErrorBuilderTests: XCTestCase {

    // MARK: - error.kind discriminator

    func testSwiftErrorReportsKindSwift() {
        struct DemoError: Error {}
        let attrs = AppErrorBuilder.build(
            error: DemoError(),
            context: [:],
            stack: [],
            debug: false
        )
        XCTAssertEqual(attrs["error.kind"], .string("swift"))
        XCTAssertNil(attrs["cause"])
        XCTAssertEqual(attrs["runtime"], .string("swift"))
        XCTAssertNil(attrs.first(where: { $0.key.hasPrefix("error.userInfo.") }),
                     "Swift errors must not surface error.userInfo.* on the wire")
    }

    func testNSErrorReportsKindNSError() {
        let err = NSError(domain: "MyDomain", code: 7)
        let attrs = AppErrorBuilder.build(
            error: err,
            context: [:],
            stack: [],
            debug: false
        )
        XCTAssertEqual(attrs["error.kind"], .string("nserror"))
        XCTAssertEqual(attrs["error.domain"], .string("MyDomain"))
        XCTAssertEqual(attrs["error.code"], .int(7))
    }

    // MARK: - error_type (F33)

    func testErrorTypeIsHostSuppliedVerbatim() {
        struct DemoError: Error {}
        let attrs = AppErrorBuilder.build(
            error: DemoError(), type: "decoding_error", context: [:], stack: [], debug: false)
        XCTAssertEqual(attrs["error_type"], .string("decoding_error"))
    }

    func testErrorTypeOmittedWhenNilOrEmpty() {
        struct DemoError: Error {}
        XCTAssertNil(AppErrorBuilder.build(error: DemoError(), context: [:], stack: [], debug: false)["error_type"])
        XCTAssertNil(AppErrorBuilder.build(
            error: DemoError(), type: "", context: [:], stack: [], debug: false)["error_type"])
    }

    func testErrorTypeCappedAt128UTF8Bytes() {
        struct DemoError: Error {}
        let attrs = AppErrorBuilder.build(
            error: DemoError(), type: String(repeating: "é", count: 100), context: [:], stack: [], debug: false)
        guard case let .string(value)? = attrs["error_type"] else { return XCTFail("error_type missing") }
        XCTAssertEqual(value.utf8.count, 128)
        XCTAssertEqual(value, String(repeating: "é", count: 64))
    }

    // MARK: - error.class

    func testErrorTypeIsSwiftTypeName() {
        enum CheckoutFailure: Error { case cardDeclined }
        let attrs = AppErrorBuilder.build(
            error: CheckoutFailure.cardDeclined,
            context: [:],
            stack: [],
            debug: false
        )
        XCTAssertEqual(attrs["error.class"], .string("CheckoutFailure"))
    }

    func testErrorTypeForNSErrorIsClassName() {
        let err = NSError(domain: "x", code: 0)
        let attrs = AppErrorBuilder.build(
            error: err,
            context: [:],
            stack: [],
            debug: false
        )
        XCTAssertEqual(attrs["error.class"], .string("NSError"))
    }

    // MARK: - userInfo flattening (T13.2)

    func testPrimitiveUserInfoIsFlattenedWithPrefix() {
        let err = NSError(domain: "Domain", code: 1, userInfo: [
            "stringKey": "hello",
            "intKey": 42,
            "doubleKey": 1.5,
            "boolKey": true
        ])
        let attrs = AppErrorBuilder.build(
            error: err,
            context: [:],
            stack: [],
            debug: false
        )
        XCTAssertEqual(attrs["error.userInfo.stringKey"], .string("hello"))
        XCTAssertEqual(attrs["error.userInfo.intKey"], .int(42))
        XCTAssertEqual(attrs["error.userInfo.doubleKey"], .double(1.5))
        XCTAssertEqual(attrs["error.userInfo.boolKey"], .bool(true))
    }

    func testNonPrimitiveUserInfoValuesAreDroppedSilently() {
        let nested = NSError(domain: "Underlying", code: 99)
        let err = NSError(domain: "Outer", code: 1, userInfo: [
            "kept": "v",
            "dropped_nested_error": nested,
            "dropped_array": [1, 2, 3] as [Int],
            "dropped_dict": ["a": 1] as [String: Int]
        ])
        let attrs = AppErrorBuilder.build(
            error: err,
            context: [:],
            stack: [],
            debug: false
        )
        XCTAssertEqual(attrs["error.userInfo.kept"], .string("v"))
        XCTAssertNil(attrs["error.userInfo.dropped_nested_error"])
        XCTAssertNil(attrs["error.userInfo.dropped_array"])
        XCTAssertNil(attrs["error.userInfo.dropped_dict"])
    }

    func testSwiftErrorDoesNotEmitUserInfoEntries() {
        struct DemoError: LocalizedError {
            var errorDescription: String? { "boom" }
        }
        let attrs = AppErrorBuilder.build(
            error: DemoError(),
            context: [:],
            stack: [],
            debug: false
        )
        let userInfoKeys = attrs.keys.filter { $0.hasPrefix("error.userInfo.") }
        XCTAssertTrue(userInfoKeys.isEmpty,
                      "Swift LocalizedError must not leak bridged userInfo to the wire")
    }

    // MARK: - context prefixing (T13.1)

    func testCallerContextIsPrefixedCrashContext() {
        let attrs = AppErrorBuilder.build(
            error: NSError(domain: "x", code: 0),
            context: [
                "screen": .string("Cart"),
                "user.flow": .string("checkout"),
                "retry.count": .int(2)
            ],
            stack: [],
            debug: false
        )
        XCTAssertEqual(attrs["crash.context.screen"], .string("Cart"))
        XCTAssertEqual(attrs["crash.context.user.flow"], .string("checkout"))
        XCTAssertEqual(attrs["crash.context.retry.count"], .int(2))
        XCTAssertNil(attrs["screen"], "Context keys must never arrive un-prefixed")
        XCTAssertNil(attrs["user.flow"])
        XCTAssertNil(attrs["retry.count"])
    }

    func testContextDoesNotOverwriteErrorAttributes() {
        // Even if the caller passes a key that collides with one of
        // the standard error.* attributes, the prefix protects the
        // wire payload from collisions.
        let err = NSError(domain: "Real", code: 1)
        let attrs = AppErrorBuilder.build(
            error: err,
            context: [
                "error.domain": .string("Forged"),
                "cause": .string("Forged")
            ],
            stack: [],
            debug: false
        )
        XCTAssertEqual(attrs["error.domain"], .string("Real"),
                       "Standard error.domain must reflect the actual error")
        XCTAssertNil(attrs["cause"])
        XCTAssertEqual(attrs["crash.context.error.domain"], .string("Forged"))
        XCTAssertEqual(attrs["crash.context.cause"], .string("Forged"))
    }

    // MARK: - error.stack

    func testStackJoinsFramesWithNewlines() {
        let frames = ["EdgeRum +0x1 frame_a", "EdgeRum +0x2 frame_b", "EdgeRum +0x3 frame_c"]
            .map { StackFrame(text: $0) }
        let attrs = AppErrorBuilder.build(
            error: NSError(domain: "x", code: 0),
            context: [:],
            stack: frames,
            debug: false
        )
        if case let .string(joined) = attrs["error.stack"] {
            XCTAssertEqual(joined.components(separatedBy: "\n").count, 3)
            XCTAssertTrue(joined.contains("frame_a"))
            XCTAssertTrue(joined.contains("frame_c"))
        } else {
            XCTFail("error.stack must be a .string AttributeValue")
        }
    }

    func testEmptyStackOmitsErrorStackAttribute() {
        let attrs = AppErrorBuilder.build(
            error: NSError(domain: "x", code: 0),
            context: [:],
            stack: [],
            debug: false
        )
        XCTAssertNil(attrs["error.stack"])
    }

    func testStackOverCapSetsTruncatedBytesAndKeptImagesOnly() {
        // 100 frames of ~84 bytes each ≈ 8_500 bytes > 4_096 cap; only
        // the first ~48 fit, so `Late` (frames 60+) must not be listed.
        let kept = StackImage(name: "App", uuid: "aa")
        let late = StackImage(name: "Late", uuid: "bb")
        let frames = (0..<100).map {
            StackFrame(text: String(repeating: "F", count: 80) + "_\($0)",
                       image: $0 < 60 ? kept : late)
        }
        let attrs = AppErrorBuilder.build(
            error: NSError(domain: "x", code: 0), context: [:], stack: frames, debug: false
        )
        guard case let .string(stack)? = attrs["error.stack"],
              case let .int(removed)? = attrs["error.stack.truncated"] else {
            return XCTFail("error.stack + error.stack.truncated expected")
        }
        XCTAssertLessThanOrEqual(stack.utf8.count, AppErrorBuilder.maxStackBytes)
        XCTAssertTrue(stack.hasPrefix(frames[0].text), "trailing frames dropped whole")
        XCTAssertGreaterThan(removed, 0)
        XCTAssertEqual(removed, StackFrames.join(frames).utf8.count - stack.utf8.count)
        XCTAssertEqual(attrs["error.binary_images"],
                       .string(#"[{"name":"App","uuid":"aa"}]"#))
    }

    func testStackUnderCapOmitsTruncatedAndImagelessOmitsBinaryImages() {
        let attrs = AppErrorBuilder.build(
            error: NSError(domain: "x", code: 0), context: [:],
            stack: [StackFrame(text: "0x1234")], debug: false
        )
        XCTAssertEqual(attrs["error.stack"], .string("0x1234"))
        XCTAssertNil(attrs["error.stack.truncated"])
        XCTAssertNil(attrs["error.binary_images"])
    }

    // MARK: - Cause / runtime invariants

    func testCauseAndRuntimeAlwaysSet() {
        let attrs = AppErrorBuilder.build(
            error: NSError(domain: "x", code: 0),
            context: [:],
            stack: [],
            debug: false
        )
        XCTAssertNil(attrs["cause"])
        XCTAssertEqual(attrs["runtime"], .string("swift"))
    }

    // MARK: - error.message fallback

    func testSwiftErrorMessageFallsBackToDescribingWhenLocalizedIsGeneric() {
        struct DemoError: Error {
            let detail: String
        }
        let attrs = AppErrorBuilder.build(
            error: DemoError(detail: "specific reason"),
            context: [:],
            stack: [],
            debug: false
        )
        if case let .string(message) = attrs["error.message"] {
            XCTAssertTrue(
                message.contains("DemoError") || message.contains("specific reason"),
                "Fallback message should describe the Swift error, got \(message)"
            )
        } else {
            XCTFail("error.message must always be set")
        }
    }

    func testNSErrorMessageUsesLocalizedDescription() {
        let err = NSError(domain: "x", code: 0, userInfo: [
            NSLocalizedDescriptionKey: "Server unreachable"
        ])
        let attrs = AppErrorBuilder.build(
            error: err,
            context: [:],
            stack: [],
            debug: false
        )
        XCTAssertEqual(attrs["error.message"], .string("Server unreachable"))
    }
}
