// Tests/EdgeRumTests/Transport/BackgroundUploaderTests.swift
//
// T5.4 scaffolding — verifies the completion-attach plumbing without
// touching a real background URLSession (full "suspend mid-upload and
// relaunch" is covered by the sample app's manual smoke pass).
//
//   - Matching identifier stores the completion; urlSessionDidFinish
//     events fires it on the main queue and clears it.
//   - Non-matching identifier still acks so the system doesn't spin.
//

import XCTest
@testable import EdgeRumCore

final class BackgroundUploaderTests: XCTestCase {

    func testMatchingIdentifierStoresAndFiresCompletion() {
        let uploader = BackgroundUploader(sessionIdentifier: "test.identifier")
        let exp = expectation(description: "completion fires")
        uploader.attachCompletion({ exp.fulfill() }, for: "test.identifier")

        uploader.urlSessionDidFinishEvents(forBackgroundURLSession: URLSession.shared)
        wait(for: [exp], timeout: 2)
    }

    func testNonMatchingIdentifierStillFiresCompletion() {
        let uploader = BackgroundUploader(sessionIdentifier: "test.identifier")
        let exp = expectation(description: "completion fires")
        uploader.attachCompletion({ exp.fulfill() }, for: "different.identifier")
        // Non-matching identifier should still trigger immediately so
        // the host app's expiration handler resolves.
        wait(for: [exp], timeout: 2)
    }

    func testCompletionFiresOnlyOnce() {
        let uploader = BackgroundUploader(sessionIdentifier: "x")
        var hits = 0
        uploader.attachCompletion({ hits += 1 }, for: "x")
        uploader.urlSessionDidFinishEvents(forBackgroundURLSession: URLSession.shared)
        uploader.urlSessionDidFinishEvents(forBackgroundURLSession: URLSession.shared)
        let exp = expectation(description: "stable")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(hits, 1)
    }

    func testDefaultSessionIdentifierMatchesSpec() {
        XCTAssertEqual(BackgroundUploader.defaultSessionIdentifier, "com.edge.rum.upload")
    }
}
