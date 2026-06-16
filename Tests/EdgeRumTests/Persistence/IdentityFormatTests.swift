// Tests/EdgeRumTests/Persistence/IdentityFormatTests.swift
//
// T4.1 acceptance: regex holds across 10k generated samples per id
// kind. Plus targeted negative cases for the malformations we expect
// to see when a persisted id has been corrupted or written by an older
// build.

import XCTest
@testable import EdgeRumCore

final class IdentityFormatTests: XCTestCase {

    // MARK: 10k positive cases (issue #41 acceptance)

    func testDeviceIdGeneratorMatchesRegexAcross10kSamples() {
        for _ in 0..<10_000 {
            let id = DeviceIdentitySnapshot.newId()
            XCTAssertTrue(
                IdentityFormat.isValid(id, kind: .device),
                "\(id) did not match device regex"
            )
        }
    }

    func testSessionIdGeneratorMatchesRegexAcross10kSamples() {
        let manager = SessionManager()
        for _ in 0..<10_000 {
            let state = manager.rotate()
            XCTAssertTrue(
                IdentityFormat.isValid(state.id, kind: .session),
                "\(state.id) did not match session regex"
            )
        }
    }

    func testUserIdGeneratorMatchesRegexAcross10kSamples() {
        for _ in 0..<10_000 {
            let id = UserContextSnapshot.newAnonymousId()
            XCTAssertTrue(
                IdentityFormat.isValid(id, kind: .user),
                "\(id) did not match user regex"
            )
        }
    }

    // MARK: Negative cases

    func testRejectsEmptyString() {
        XCTAssertFalse(IdentityFormat.isValid("", kind: .device))
        XCTAssertFalse(IdentityFormat.isValid("", kind: .session))
        XCTAssertFalse(IdentityFormat.isValid("", kind: .user))
    }

    func testRejectsWrongPrefix() {
        XCTAssertFalse(IdentityFormat.isValid("session_1_aaaaaaaaaaaaaaaa_ios", kind: .device))
        XCTAssertFalse(IdentityFormat.isValid("device_1_aaaaaaaaaaaaaaaa_ios", kind: .session))
        XCTAssertFalse(IdentityFormat.isValid("device_1_aaaaaaaaaaaaaaaa_ios", kind: .user))
    }

    func testRejectsMissingIosSuffixOnDeviceAndSession() {
        XCTAssertFalse(IdentityFormat.isValid("device_1_aaaaaaaaaaaaaaaa", kind: .device))
        XCTAssertFalse(IdentityFormat.isValid("session_1_aaaaaaaaaaaaaaaa", kind: .session))
    }

    func testRejectsIosSuffixOnUser() {
        XCTAssertFalse(IdentityFormat.isValid("user_1_aaaaaaaaaaaaaaaa_ios", kind: .user))
    }

    func testRejectsNonHexCharactersInRandomSegment() {
        XCTAssertFalse(IdentityFormat.isValid("device_1_zzzzzzzzzzzzzzzz_ios", kind: .device))
        XCTAssertFalse(IdentityFormat.isValid("device_1_AAAAAAAAAAAAAAAA_ios", kind: .device))
    }

    func testRejectsWrongHexLength() {
        XCTAssertFalse(IdentityFormat.isValid("device_1_aaaa_ios", kind: .device))
        XCTAssertFalse(IdentityFormat.isValid("device_1_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_ios", kind: .device))
    }

    func testRejectsNonNumericEpoch() {
        XCTAssertFalse(IdentityFormat.isValid("device_abc_aaaaaaaaaaaaaaaa_ios", kind: .device))
        XCTAssertFalse(IdentityFormat.isValid("session_abc_aaaaaaaaaaaaaaaa_ios", kind: .session))
        XCTAssertFalse(IdentityFormat.isValid("user_abc_aaaaaaaaaaaaaaaa", kind: .user))
    }

    func testRejectsUUIDStyleHex() {
        XCTAssertFalse(IdentityFormat.isValid(
            "device_1717234876123_a1b2c3d4e5f607189abcdef012345678_ios",
            kind: .device
        ))
    }

    // MARK: validate(_:kind:) convenience returns nil on mismatch

    func testValidateReturnsValueWhenValid() {
        let id = "device_1717234876123_a1b2c3d4e5f60718_ios"
        XCTAssertEqual(IdentityFormat.validate(id, kind: .device), id)
    }

    func testValidateReturnsNilWhenInvalid() {
        XCTAssertNil(IdentityFormat.validate("garbage", kind: .device))
        XCTAssertNil(IdentityFormat.validate("garbage", kind: .session))
        XCTAssertNil(IdentityFormat.validate("garbage", kind: .user))
    }

    // MARK: Cross-kind isolation

    func testKindsAreMutuallyExclusive() {
        let device = "device_1_aaaaaaaaaaaaaaaa_ios"
        let session = "session_1_aaaaaaaaaaaaaaaa_ios"
        let user = "user_1_aaaaaaaaaaaaaaaa"

        XCTAssertTrue(IdentityFormat.isValid(device, kind: .device))
        XCTAssertFalse(IdentityFormat.isValid(device, kind: .session))
        XCTAssertFalse(IdentityFormat.isValid(device, kind: .user))

        XCTAssertTrue(IdentityFormat.isValid(session, kind: .session))
        XCTAssertFalse(IdentityFormat.isValid(session, kind: .device))
        XCTAssertFalse(IdentityFormat.isValid(session, kind: .user))

        XCTAssertTrue(IdentityFormat.isValid(user, kind: .user))
        XCTAssertFalse(IdentityFormat.isValid(user, kind: .device))
        XCTAssertFalse(IdentityFormat.isValid(user, kind: .session))
    }
}
