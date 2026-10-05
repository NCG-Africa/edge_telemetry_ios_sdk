// Tests/EdgeRumCaptureTests/SwizzleTests.swift
//
// F32 / #219 acceptance: a forced swizzle failure surfaces in
// `sdk.capabilities_failed` on the envelope.

import XCTest
import EdgeRumCore
@testable import EdgeRumCapture

final class SwizzleTests: XCTestCase {

    func testForcedSwizzleFailureSurfacesInCapabilitiesFailed() throws {
        let health = SdkHealth()
        let ok = Swizzle.exchange(
            NSObject.self,
            NSSelectorFromString("edgerum_doesNotExist"),
            #selector(NSObject.description),
            capability: .httpSwizzle,
            health: health
        )
        XCTAssertFalse(ok)

        let sink = RecordingTransportSink()
        let recorder = Recorder(transport: sink, health: health)
        recorder.setEnabled(true)
        recorder.recordEvent(name: "navigation", attributes: [:])
        recorder.flush(reason: .manual)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(XCTUnwrap(sink.envelopes.last))) as? [String: Any])
        XCTAssertEqual(json["sdk.capabilities_failed"] as? String, "http_swizzle")
    }
}
