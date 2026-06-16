// Tests/EdgeRumTests/Persistence/SessionSidecarTests.swift
//
// Issue #44 (writer half): verify the JSON on disk matches the
// snapshot the Recorder just emitted, and that each subsequent write
// overwrites the previous one atomically.

import XCTest
@testable import EdgeRumCore

final class SessionSidecarTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("edge-rum-sidecar-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
    }

    private func makeSidecar() -> SessionSidecar {
        SessionSidecar(url: tempDir.appendingPathComponent("last-session.json"))
    }

    // MARK: Mirror behaviour

    func testWritesOnlyMirroredKeys() throws {
        let sidecar = makeSidecar()
        var bag = AttributeBag()
        bag.set("session.id", .string("session_1_aaaaaaaaaaaaaaaa_ios"))
        bag.set("session.start_time", .string("2026-06-14T10:30:00.000Z"))
        bag.set("session.sequence", .int(7))
        bag.set("user.id", .string("user_1_bbbbbbbbbbbbbbbb"))
        bag.set("device.id", .string("device_1_cccccccccccccccc_ios"))
        bag.set("sdk.version", .string("1.0.0"))
        bag.set("sdk.platform", .string("ios-native"))

        // Transient keys that must NOT be mirrored.
        bag.set("device.batteryLevel", .double(0.82))
        bag.set("network.type", .string("wifi"))
        bag.set("app.name", .string("Shop"))

        sidecar.write(snapshot: bag)

        let read = sidecar.read()
        XCTAssertNotNil(read)
        XCTAssertEqual(read?["session.id"], .string("session_1_aaaaaaaaaaaaaaaa_ios"))
        XCTAssertEqual(read?["session.start_time"], .string("2026-06-14T10:30:00.000Z"))
        XCTAssertEqual(read?["session.sequence"], .int(7))
        XCTAssertEqual(read?["user.id"], .string("user_1_bbbbbbbbbbbbbbbb"))
        XCTAssertEqual(read?["device.id"], .string("device_1_cccccccccccccccc_ios"))

        XCTAssertNil(read?["device.batteryLevel"])
        XCTAssertNil(read?["network.type"])
        XCTAssertNil(read?["app.name"])
    }

    func testWritesOptionalUserFieldsWhenPresent() {
        let sidecar = makeSidecar()
        var bag = AttributeBag()
        bag.set("session.id", .string("session_1_aaaaaaaaaaaaaaaa_ios"))
        bag.set("user.id", .string("user_1_bbbbbbbbbbbbbbbb"))
        bag.set("user.email", .string("a@b.com"))
        sidecar.write(snapshot: bag)

        let read = sidecar.read()
        XCTAssertEqual(read?["user.email"], .string("a@b.com"))
    }

    // MARK: Overwrite semantics

    func testSecondWriteReplacesPreviousFile() throws {
        let sidecar = makeSidecar()
        var first = AttributeBag()
        first.set("session.id", .string("session_1_aaaaaaaaaaaaaaaa_ios"))
        first.set("session.sequence", .int(1))
        sidecar.write(snapshot: first)

        var second = AttributeBag()
        second.set("session.id", .string("session_2_dddddddddddddddd_ios"))
        second.set("session.sequence", .int(2))
        sidecar.write(snapshot: second)

        let read = sidecar.read()
        XCTAssertEqual(read?["session.id"], .string("session_2_dddddddddddddddd_ios"))
        XCTAssertEqual(read?["session.sequence"], .int(2))
    }

    // MARK: Directory creation

    func testCreatesParentDirectoryOnFirstWrite() throws {
        let sidecar = makeSidecar()
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.path))

        var bag = AttributeBag()
        bag.set("session.id", .string("session_1_aaaaaaaaaaaaaaaa_ios"))
        sidecar.write(snapshot: bag)

        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("last-session.json").path
        ))
    }

    // MARK: No-op on empty snapshot

    func testEmptySnapshotIsNoOp() {
        let sidecar = makeSidecar()
        sidecar.write(snapshot: AttributeBag())
        // No file written → read() returns nil.
        XCTAssertNil(sidecar.read())
    }

    // MARK: defaultURL availability

    func testDefaultURLResolvesUnderCachesDirectory() {
        guard let url = SessionSidecar.defaultURL() else {
            XCTFail("SessionSidecar.defaultURL() returned nil")
            return
        }
        XCTAssertTrue(
            url.path.contains("edge-rum"),
            "Expected the sidecar path to contain 'edge-rum'; got \(url.path)"
        )
        XCTAssertEqual(url.lastPathComponent, "last-session.json")
    }
}
