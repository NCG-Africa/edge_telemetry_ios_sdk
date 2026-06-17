// Tests/EdgeRumCrashTests/CrashSidecarReaderTests.swift
//
// Pure unit coverage for the sidecar parser. Drives the `parse(_:)`
// entry point directly so tests don't have to seed a file on disk —
// the file-reading half is exercised end-to-end by
// `PLCrashIntegrationReplayTests`.
//
// Refs: PLAN-iOS.md §6.7, §8.4, §F14/T14.3.
//

import XCTest
@testable import EdgeRumCrash
import EdgeRumCore

final class CrashSidecarReaderTests: XCTestCase {

    // MARK: - Happy path

    func testReadsValidIdentitiesAndExtras() throws {
        let raw: [String: AttributeValue] = [
            "session.id": .string("session_1717234870002_ff009988aabbccdd_ios"),
            "session.start_time": .string("2026-06-14T10:25:00.002Z"),
            "session.sequence": .int(42),
            "device.id": .string("device_1717234876123_a1b2c3d4e5f60718_ios"),
            "user.id": .string("user_1717100000000_deadbeefcafef00d"),
            "user.name": .string("Marvin"),
            "sdk.platform": .string("ios-native"),
            "sdk.version": .string("1.0.0")
        ]
        let snapshot = try XCTUnwrap(CrashSidecarReader.parse(raw))

        XCTAssertEqual(snapshot.sessionId, "session_1717234870002_ff009988aabbccdd_ios")
        XCTAssertEqual(snapshot.sessionStartTime, "2026-06-14T10:25:00.002Z")
        XCTAssertEqual(snapshot.sessionSequence, 42)
        XCTAssertEqual(snapshot.deviceId, "device_1717234876123_a1b2c3d4e5f60718_ios")
        XCTAssertEqual(snapshot.userId, "user_1717100000000_deadbeefcafef00d")
        XCTAssertEqual(snapshot.extras["user.name"], .string("Marvin"))
        XCTAssertEqual(snapshot.extras["sdk.platform"], .string("ios-native"))
        XCTAssertEqual(snapshot.extras["sdk.version"], .string("1.0.0"))
        XCTAssertNil(snapshot.extras["session.id"],
                     "consumed identity keys must not appear in extras")
        XCTAssertNil(snapshot.extras["device.id"])
        XCTAssertNil(snapshot.extras["user.id"])
    }

    // MARK: - Rejection paths

    func testMissingSessionIdReturnsNil() {
        let raw: [String: AttributeValue] = [
            "device.id": .string("device_1717234876123_a1b2c3d4e5f60718_ios")
        ]
        XCTAssertNil(CrashSidecarReader.parse(raw))
    }

    func testMissingDeviceIdReturnsNil() {
        let raw: [String: AttributeValue] = [
            "session.id": .string("session_1717234870002_ff009988aabbccdd_ios")
        ]
        XCTAssertNil(CrashSidecarReader.parse(raw))
    }

    func testMalformedSessionIdReturnsNil() {
        let raw: [String: AttributeValue] = [
            // Missing required `_ios` suffix — fails IdentityFormat regex.
            "session.id": .string("session_1717234870002_ff009988aabbccdd"),
            "device.id": .string("device_1717234876123_a1b2c3d4e5f60718_ios")
        ]
        XCTAssertNil(CrashSidecarReader.parse(raw))
    }

    func testMalformedDeviceIdReturnsNil() {
        let raw: [String: AttributeValue] = [
            "session.id": .string("session_1717234870002_ff009988aabbccdd_ios"),
            "device.id": .string("device_1717234876123_NOT_HEX_a1b2c3d4_ios")
        ]
        XCTAssertNil(CrashSidecarReader.parse(raw))
    }

    func testMalformedUserIdIsDroppedButSidecarStillReturns() throws {
        let raw: [String: AttributeValue] = [
            "session.id": .string("session_1717234870002_ff009988aabbccdd_ios"),
            "device.id": .string("device_1717234876123_a1b2c3d4e5f60718_ios"),
            "user.id": .string("bogus_user_id")
        ]
        let snapshot = try XCTUnwrap(CrashSidecarReader.parse(raw))
        XCTAssertEqual(snapshot.deviceId, "device_1717234876123_a1b2c3d4e5f60718_ios")
        XCTAssertNil(snapshot.userId, "malformed user id is silently dropped")
    }

    // MARK: - File I/O end-to-end

    func testReadsRoundTrippedSidecarFile() throws {
        let tmp = makeTempSidecarURL()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Use the production SessionSidecar writer to produce the file
        // so the test pins the writer↔reader contract.
        let writer = SessionSidecar(url: tmp)
        var bag = AttributeBag()
        bag.set("session.id", .string("session_1717234870002_ff009988aabbccdd_ios"))
        bag.set("session.start_time", .string("2026-06-14T10:25:00.002Z"))
        bag.set("session.sequence", .int(7))
        bag.set("device.id", .string("device_1717234876123_a1b2c3d4e5f60718_ios"))
        bag.set("user.id", .string("user_1717100000000_deadbeefcafef00d"))
        bag.set("sdk.version", .string("1.2.3"))
        bag.set("sdk.platform", .string("ios-native"))
        writer.write(snapshot: bag)

        let reader = SessionSidecar(url: tmp)
        let snapshot = try XCTUnwrap(CrashSidecarReader.read(reader))
        XCTAssertEqual(snapshot.sessionId, "session_1717234870002_ff009988aabbccdd_ios")
        XCTAssertEqual(snapshot.sessionSequence, 7)
        XCTAssertEqual(snapshot.extras["sdk.version"], .string("1.2.3"))
    }

    func testMissingFileReturnsNil() {
        let tmp = makeTempSidecarURL()
        // Don't write anything to `tmp`.
        let reader = SessionSidecar(url: tmp)
        XCTAssertNil(CrashSidecarReader.read(reader))
    }

    // MARK: - Helpers

    private func makeTempSidecarURL() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("edgerum-crashtest-\(UUID().uuidString)",
                                   isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("last-session.json", isDirectory: false)
    }
}
