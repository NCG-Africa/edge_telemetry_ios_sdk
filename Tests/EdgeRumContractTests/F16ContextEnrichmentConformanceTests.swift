import XCTest
import EdgeRumCore

/// F16 — wire conformance for the context-bag enrichment.
///
/// Drives a `Recorder` seeded with non-default F16 contexts (Power,
/// Accessibility, Storage, plus NetworkContext extras and the
/// DeviceContext locale/timezone fields), emits one `navigation`
/// event, and asserts:
///
///   - The envelope still passes every `WireAssertions.assertValidEnvelope`
///     check (primitives only, no forbidden tokens, ISO 8601 stamps).
///   - Every one of the 16 new wire keys is present with the expected
///     type and value.
///   - The existing identity attributes (session.id, device.id,
///     sdk.platform) survive the new write order.
///
/// Refs: PLAN-iOS.md §16.4 / F16; docs/data-flow.md §3.
final class F16ContextEnrichmentConformanceTests: XCTestCase {

    private func makeRecorderWithF16Contexts() -> (Recorder, RecordingTransportSink) {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_717_234_876.512))
        let sink = RecordingTransportSink()

        let provider = ContextProvider(
            app: AppContext(
                name: "Shop",
                packageName: "com.example.shop",
                version: "2.1.0",
                buildNumber: "412",
                environment: "production"
            ),
            device: DeviceContext(
                platformVersion: "17.4.1",
                model: "iPhone15,3",
                isVirtual: false,
                screenWidth: 1290,
                screenHeight: 2796,
                pixelRatio: 3.0,
                locale: "en_KE",
                timezone: "Africa/Nairobi",
                timezoneOffsetMin: 180
            ),
            deviceIdentity: DeviceIdentitySnapshot(id: "device_1_aaaaaaaaaaaaaaaa_ios"),
            network: NetworkContext(
                type: .cellular,
                effectiveType: "4g",
                isExpensive: true,
                isConstrained: true,
                interface: "pdp_ip0"
            ),
            session: SessionContextSnapshot(
                id: "session_1_bbbbbbbbbbbbbbbb_ios",
                startTime: Date(timeIntervalSince1970: 1),
                sequence: 7
            ),
            user: UserContextSnapshot(id: "user_1_cccccccccccccccc"),
            sdk: SdkContext(version: "1.0.0"),
            power: PowerContext(thermalState: "serious", lowPowerMode: true),
            accessibility: AccessibilityContext(
                dynamicType: "AX2",
                reduceMotion: true,
                boldText: false,
                voiceOver: true,
                increaseContrast: false
            ),
            storage: StorageContext(
                diskFreeMb: 9_876,
                diskTotalMb: 131_072,
                backgroundRefresh: "available"
            )
        )

        let recorder = Recorder(
            clock: clock,
            sampler: Sampler(sampleRate: 1.0, entropy: { 0.0 }),
            transport: sink,
            contextProvider: provider,
            sdkVersion: "1.0.0"
        )
        recorder.configure(RecorderConfig(
            apiKey: "edge_test_abc",
            endpoint: URL(string: "https://collect.example.com")!
        ))
        return (recorder, sink)
    }

    func testEnvelopeCarriesAllSixteenF16Attributes() throws {
        let (recorder, sink) = makeRecorderWithF16Contexts()
        // configure() called above re-snapshots the live AppContext +
        // DeviceContext from Info.plist / UIDevice, which clobbers our
        // fixture's locale fields. Re-apply the F16 contexts after
        // configure so the asserted values survive.
        let provider = recorder.currentContextProvider
        provider.refreshDevice(DeviceContext(
            platformVersion: "17.4.1",
            model: "iPhone15,3",
            isVirtual: false,
            screenWidth: 1290,
            screenHeight: 2796,
            pixelRatio: 3.0,
            locale: "en_KE",
            timezone: "Africa/Nairobi",
            timezoneOffsetMin: 180
        ))

        recorder.recordEvent(name: "navigation", attributes: [
            "navigation.kind": "uikit",
            "navigation.name": "Cart"
        ])
        recorder.flush(reason: .manual)

        let envelope = try XCTUnwrap(sink.envelopes.first)
        let (_, json) = try WireAssertions.assertValidEnvelope(envelope)

        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        let attrs = try XCTUnwrap(events.first?["attributes"] as? [String: Any])
        try WireAssertions.assertIdentityAttributes(attrs)

        // T16.1 PowerContext
        XCTAssertEqual(attrs["device.thermal_state"] as? String, "serious")
        XCTAssertEqual(attrs["device.low_power_mode"] as? Bool, true)

        // T16.2 AccessibilityContext
        XCTAssertEqual(attrs["device.dynamic_type"] as? String, "AX2")
        XCTAssertEqual(attrs["device.reduce_motion"] as? Bool, true)
        XCTAssertEqual(attrs["device.bold_text"] as? Bool, false)
        XCTAssertEqual(attrs["device.voiceover"] as? Bool, true)
        XCTAssertEqual(attrs["device.increase_contrast"] as? Bool, false)

        // T16.3 NetworkContext extras
        XCTAssertEqual(attrs["network.expensive"] as? Bool, true)
        XCTAssertEqual(attrs["network.constrained"] as? Bool, true)
        XCTAssertEqual(attrs["network.interface"] as? String, "pdp_ip0")

        // T16.4 StorageContext
        XCTAssertEqual(attrs["device.disk_free_mb"] as? Int, 9_876)
        XCTAssertEqual(attrs["device.disk_total_mb"] as? Int, 131_072)
        XCTAssertEqual(attrs["app.background_refresh"] as? String, "available")

        // T16.5 DeviceContext locale / timezone
        XCTAssertEqual(attrs["device.locale"] as? String, "en_KE")
        XCTAssertEqual(attrs["device.timezone"] as? String, "Africa/Nairobi")
        XCTAssertEqual(attrs["device.timezone_offset_min"] as? Int, 180)
    }

    /// All F16 attributes must be primitives — the generic
    /// `assertValidEnvelope` already enforces this, but we add a
    /// targeted sanity check on the specific key set so any future
    /// regression toward nested/array values surfaces here with a
    /// clear name.
    func testF16AttributesAreAllPrimitives() throws {
        let (recorder, sink) = makeRecorderWithF16Contexts()
        recorder.recordEvent(name: "navigation", attributes: [:])
        recorder.flush(reason: .manual)
        let envelope = try XCTUnwrap(sink.envelopes.first)
        let (_, json) = try WireAssertions.assertValidEnvelope(envelope)
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        let attrs = try XCTUnwrap(events.first?["attributes"] as? [String: Any])

        let f16Keys: [String] = [
            "device.thermal_state",
            "device.low_power_mode",
            "device.dynamic_type",
            "device.reduce_motion",
            "device.bold_text",
            "device.voiceover",
            "device.increase_contrast",
            "network.expensive",
            "network.constrained",
            "network.interface",
            "device.disk_free_mb",
            "device.disk_total_mb",
            "app.background_refresh",
            "device.locale",
            "device.timezone",
            "device.timezone_offset_min"
        ]
        for key in f16Keys {
            let value = try XCTUnwrap(attrs[key], "F16 key \(key) must be present on every event")
            XCTAssertFalse(value is [Any], "\(key) must not be an array")
            XCTAssertFalse(value is [String: Any], "\(key) must not be a nested object")
        }
    }
}
