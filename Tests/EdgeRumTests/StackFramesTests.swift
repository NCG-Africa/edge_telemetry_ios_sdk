// Tests/EdgeRumTests/StackFramesTests.swift
//
// F29 / W20 — the shared `image +0x<offset> <hint>` formatter behind
// `error.stack`, `long_task.stack`, `hang.stack`, its whole-frame byte
// cap, and the `<prefix>.binary_images` JSON string.
//

import XCTest
import EdgeRumCore

final class StackFramesTests: XCTestCase {

    // MARK: - symbolicate

    func testLiveAddressesFormatAsImageOffsetHint() throws {
        let frames = StackFrames.symbolicate(Thread.callStackReturnAddresses.map(\.uintValue))
        let first = try XCTUnwrap(frames.first)
        let image = try XCTUnwrap(first.image, "a live return address resolves to an image")
        // `<image> +0x<lowercase hex>` then an optional ` <hint>`.
        let pattern = "^" + NSRegularExpression.escapedPattern(for: image.name) + " \\+0x[0-9a-f]+( .+)?$"
        XCTAssertNotNil(first.text.range(of: pattern, options: .regularExpression),
                        "unexpected frame format: \(first.text)")
        XCTAssertFalse(image.name.contains("/"), "image is the last path component")
        XCTAssertNotNil(image.uuid.range(of: "^[0-9a-f]{32}$", options: .regularExpression),
                        "LC_UUID in PLCrashReporter format, got \(image.uuid)")
    }

    func testOffsetIsImageRelative() throws {
        // RTLD_DEFAULT == (void *)-2
        let symbol = try XCTUnwrap(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "dladdr"))
        let address = UInt(bitPattern: symbol)
        var info = Dl_info()
        XCTAssertNotEqual(dladdr(UnsafeRawPointer(bitPattern: address), &info), 0)
        let base = UInt(bitPattern: try XCTUnwrap(info.dli_fbase))
        let frame = try XCTUnwrap(StackFrames.symbolicate([address]).first)
        XCTAssertTrue(frame.text.contains(" +0x" + String(address - base, radix: 16)),
                      "offset must be address − image base: \(frame.text)")
        XCTAssertTrue(frame.text.hasSuffix(" dladdr"), "dladdr symbol is the hint: \(frame.text)")
    }

    func testUnresolvableAddressFallsBackToAbsoluteHexWithoutImage() {
        let frames = StackFrames.symbolicate([0x10])
        XCTAssertEqual(frames, [StackFrame(text: "0x10")])
        XCTAssertNil(StackFrames.binaryImagesJSON(frames))
    }

    // MARK: - capped

    func testCapKeepsWholeFramesAndCountsRemovedBytes() {
        let frames = ["alpha", "beta", "gamma"].map { StackFrame(text: $0) }
        // budget fits "alpha\nbeta" (+ join bytes) but not gamma
        let result = StackFrames.capped(frames, maxBytes: 12)
        XCTAssertEqual(result.stack, "alpha\nbeta")
        XCTAssertEqual(result.bytesRemoved, "alpha\nbeta\ngamma".utf8.count - "alpha\nbeta".utf8.count)
    }

    func testCapUnderBudgetRemovesNothing() {
        let frames = ["a", "b"].map { StackFrame(text: $0) }
        let result = StackFrames.capped(frames, maxBytes: 4096)
        XCTAssertEqual(result.stack, "a\nb")
        XCTAssertEqual(result.bytesRemoved, 0)
    }

    func testCapNeverExceedsBudgetAndStaysUTF8Safe() {
        let frames = (0..<200).map { StackFrame(text: "\($0) 🛡️🚀 frame_padding_for_size") }
        let result = StackFrames.capped(frames, maxBytes: 4096)
        XCTAssertLessThanOrEqual(result.stack.utf8.count, 4096)
        XCTAssertTrue(result.stack.hasPrefix(frames[0].text))
        XCTAssertNotNil(result.stack.data(using: .utf8))
    }

    func testCapEmptyInput() {
        let result = StackFrames.capped([], maxBytes: 4096)
        XCTAssertEqual(result.stack, "")
        XCTAssertEqual(result.bytesRemoved, 0)
        XCTAssertNil(result.binaryImages)
    }

    func testCapListsOnlyImagesOfKeptFrames() {
        let kept = StackImage(name: "App", uuid: "aa")
        let cut = StackImage(name: "Cut", uuid: "bb")
        let frames = [StackFrame(text: "App +0x1", image: kept),
                      StackFrame(text: String(repeating: "x", count: 100), image: cut)]
        XCTAssertEqual(StackFrames.capped(frames, maxBytes: 20).binaryImages,
                       #"[{"name":"App","uuid":"aa"}]"#)
    }

    // MARK: - binaryImagesJSON

    func testBinaryImagesDeduplicatedInFirstSeenOrder() {
        let a = StackImage(name: "App", uuid: "aa")
        let b = StackImage(name: "UIKitCore", uuid: "bb")
        let frames = [StackFrame(text: "1", image: b), StackFrame(text: "2", image: a),
                      StackFrame(text: "3"), StackFrame(text: "4", image: b)]
        XCTAssertEqual(StackFrames.binaryImagesJSON(frames),
                       #"[{"name":"UIKitCore","uuid":"bb"},{"name":"App","uuid":"aa"}]"#)
    }
}
