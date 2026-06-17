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
        XCTAssertEqual(attrs["cause"], .string("AppError"))
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

    // MARK: - error.type

    func testErrorTypeIsSwiftTypeName() {
        enum CheckoutFailure: Error { case cardDeclined }
        let attrs = AppErrorBuilder.build(
            error: CheckoutFailure.cardDeclined,
            context: [:],
            stack: [],
            debug: false
        )
        XCTAssertEqual(attrs["error.type"], .string("CheckoutFailure"))
    }

    func testErrorTypeForNSErrorIsClassName() {
        let err = NSError(domain: "x", code: 0)
        let attrs = AppErrorBuilder.build(
            error: err,
            context: [:],
            stack: [],
            debug: false
        )
        XCTAssertEqual(attrs["error.type"], .string("NSError"))
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
        XCTAssertEqual(attrs["cause"], .string("AppError"))
        XCTAssertEqual(attrs["crash.context.error.domain"], .string("Forged"))
        XCTAssertEqual(attrs["crash.context.cause"], .string("Forged"))
    }

    // MARK: - error.stack

    func testStackJoinsFramesWithNewlines() {
        let frames = [
            "0   EdgeRum                  0x0001  frame_a",
            "1   EdgeRum                  0x0002  frame_b",
            "2   EdgeRum                  0x0003  frame_c"
        ]
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

    func testStackTruncationDropsTrailingFramesWhole() {
        // 100 frames of ~80 bytes each = ~8_100 bytes > 4_096 cap.
        let frames = (0..<100).map { String(repeating: "F", count: 80) + "_\($0)" }
        let joined = AppErrorBuilder.truncateStack(frames, maxBytes: 4_096)
        XCTAssertLessThanOrEqual(joined.utf8.count, 4_096)
        // Truncation must drop trailing frames whole, not slice
        // mid-symbol — assert the prefix is intact.
        XCTAssertTrue(joined.hasPrefix(frames[0]))
    }

    func testStackTruncationIsUTF8Safe() {
        // A multi-byte UTF-8 sequence near the byte boundary must not
        // get sliced. Frames mix ASCII + 4-byte emoji.
        let emoji = "🛡️🚀"   // 8 bytes of UTF-8
        let frames = (0..<200).map { "\($0) \(emoji) frame_padding_for_size" }
        let joined = AppErrorBuilder.truncateStack(frames, maxBytes: 4_096)
        XCTAssertNotNil(joined.data(using: .utf8),
                        "truncated string must remain valid UTF-8")
        XCTAssertLessThanOrEqual(joined.utf8.count, 4_096)
    }

    // MARK: - Cause / runtime invariants

    func testCauseAndRuntimeAlwaysSet() {
        let attrs = AppErrorBuilder.build(
            error: NSError(domain: "x", code: 0),
            context: [:],
            stack: [],
            debug: false
        )
        XCTAssertEqual(attrs["cause"], .string("AppError"))
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
