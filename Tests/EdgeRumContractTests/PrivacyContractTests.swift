// Tests/EdgeRumContractTests/PrivacyContractTests.swift
//
// F27 / #214 — turns the catalogue's "Never collected" registry (§7)
// into something CI defends, and pins the `identity` PII class to
// exactly four keys.
//
// Refs: docs/catalogue/ios-data-catalogue.md §3, §7; W7 (#195) §10.

import XCTest
import EdgeRumCore

final class PrivacyContractTests: XCTestCase {

    private static let identityKeys: Set<String> = [
        "user.name", "user.email", "user.phone", "user.external_id"
    ]

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // EdgeRumContractTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo root

    // MARK: Never collected — six absence greps

    func testSourcesNeverReferenceDeviceOrRequestIdentifiers() throws {
        let banned = [
            "ASIdentifierManager", "advertisingIdentifier", "identifierForVendor",
            "allHTTPHeaderFields", "IOPlatformSerialNumber", "ATTrackingManager"
        ]
        let sources = Self.repoRoot.appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "no Swift sources found under \(sources.path)")

        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for token in banned where text.contains(token) {
                XCTFail("\(file.lastPathComponent) references \(token)")
            }
        }
    }

    // MARK: identity is exactly four keys

    func testCatalogueIdentityClassIsExactlyFourKeys() throws {
        let catalogue = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("docs/catalogue/ios-data-catalogue.md"),
            encoding: .utf8
        )
        // Attribute-registry rows: | `key` | type | on events | scope | presence | cardinality | pii | …
        let keys = catalogue.split(separator: "\n").compactMap { line -> String? in
            let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count > 7, cells[1].hasPrefix("`"), cells[7] == "identity" else { return nil }
            return cells[1].trimmingCharacters(in: CharacterSet(charactersIn: "`"))
        }
        XCTAssertEqual(Set(keys), Self.identityKeys)
    }

    func testIdentifyAddsExactlyTheFourIdentityKeysToTheWire() throws {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_717_234_876.000))
        let sink = RecordingTransportSink()
        let recorder = Recorder(clock: clock, transport: sink, sdkVersion: "1.0.0")
        recorder.configure(RecorderConfig(
            apiKey: "edge_test_abc",
            endpoint: URL(string: "https://collect.example.com")!,
            batchSize: 1_000
        ))
        recorder.setEnabled(true)

        recorder.recordEvent(name: "navigation", attributes: [:])
        recorder.flush(reason: .manual)
        recorder.setUser(RecorderUser(id: "ext-1", name: "Ann", email: "a@x.io", phone: "+254"))
        recorder.flush(reason: .manual)

        let before = Set(try XCTUnwrap(sink.envelopes.first?.events.first).attributes.keys)
        let profile = try XCTUnwrap(sink.envelopes.last?.events.first { $0.name == "user.profile.update" })
        XCTAssertEqual(Set(profile.attributes.keys).subtracting(before), Self.identityKeys)
    }
}
