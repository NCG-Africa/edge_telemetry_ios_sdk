import XCTest
import EdgeRumCore

/// Contract tests for `PayloadBuilder` (issue #40). Output must pass
/// `WireAssertions.assertValidEnvelope`.
final class PayloadBuilderContractTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_717_234_876.512)

    private func sampleContext() -> AttributeBag {
        AttributeBag([
            "app.name": "Shop",
            "app.package_name": "com.example.shop",
            "device.platform": "ios",
            "device.manufacturer": "Apple",
            "device.os": "ios",
            "device.id": "device_1717234876123_a1b2c3d4e5f60718_ios",
            "device.isVirtual": false,
            "network.type": "wifi",
            "network.effectiveType": "4g",
            "session.id": "session_1717234870002_ff009988aabbccdd_ios",
            "session.start_time": "2026-06-14T10:25:00.002Z",
            "session.sequence": 1,
            "user.id": "user_1717100000000_deadbeefcafef00d",
            "sdk.version": "1.0.0",
            "sdk.platform": "ios-native"
        ])
    }

    func testBuiltEnvelopePassesWireAssertions() throws {
        let builder = PayloadBuilder()
        let envelope = builder.build(
            events: [
                .event(name: "navigation", timestamp: t0, attributes: ["navigation.kind": "uikit"]),
                .event(name: "http.request", timestamp: t0, attributes: ["http.method": "GET", "http.status_code": 200]),
                .metric(name: "frame_render_time", value: 18.4, timestamp: t0, attributes: ["frame.target_hz": 60])
            ],
            context: sampleContext(),
            flushTime: t0
        )
        let result = try WireAssertions.assertValidEnvelope(envelope)
        let events = try XCTUnwrap(result.json["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 3)
        // Identity attrs are merged into every event by the builder.
        for event in events {
            let attrs = try XCTUnwrap(event["attributes"] as? [String: Any])
            try WireAssertions.assertIdentityAttributes(attrs)
        }
    }

    func testBuilderTimestampIsFlushTimeNotEnqueueTime() {
        let builder = PayloadBuilder()
        let enqueue = t0
        let flush = t0.addingTimeInterval(5.0)
        let envelope = builder.build(
            events: [.event(name: "navigation", timestamp: enqueue, attributes: AttributeBag())],
            context: AttributeBag(),
            flushTime: flush
        )
        XCTAssertEqual(envelope.timestamp, flush,
                       "Envelope timestamp must reflect flush time (issue #40)")
        XCTAssertEqual(envelope.events.first?.timestamp, enqueue,
                       "Per-event timestamp must reflect the moment recordEvent() was called")
    }

    func testEventAttributesWinOnConflictWithContext() {
        let builder = PayloadBuilder()
        let env = builder.build(
            events: [.event(name: "navigation", timestamp: t0, attributes: ["screen.name": "Override"])],
            context: AttributeBag(["screen.name": "FromContext"]),
            flushTime: t0
        )
        XCTAssertEqual(env.events.first?.attributes["screen.name"], .string("Override"))
    }

    /// #250 R1: identity keys leave every event — context- and
    /// event-supplied — and the context's identity fills the envelope.
    func testIdentityIsLiftedToTheEnvelopeAndStrippedFromEvents() {
        let env = PayloadBuilder().build(
            events: [.event(name: "custom_event", timestamp: t0, attributes: [
                "app.name": "Evil", "app.version": "0", "app.environment": "prod",
                "sdk.version": "0", "sdk.platform": "ios-native", "device.id": "x",
                "app.state": "active"
            ])],
            context: AttributeBag([
                "app.name": "Shop", "app.package_name": "com.example.shop", "app.version": "2.1.0",
                "app.build_number": "412", "sdk.version": "1.0.0",
                "device.id": "device_1717234876123_a1b2c3d4e5f60718_ios", "session.id": "s"
            ]),
            flushTime: t0
        )
        XCTAssertEqual(env.events.first?.attributes.values, ["app.state": "active", "session.id": "s"])
        XCTAssertEqual(env.app, AppContext(name: "Shop", packageName: "com.example.shop", version: "2.1.0", buildNumber: "412"))
        XCTAssertEqual(env.sdkVersion, "1.0.0")
        XCTAssertEqual(env.deviceId, "device_1717234876123_a1b2c3d4e5f60718_ios")
    }

    func testBatchSizeMatchesEventsCount() throws {
        let builder = PayloadBuilder()
        let events: [Event] = (0..<7).map { _ in
            .event(name: "navigation", timestamp: t0, attributes: AttributeBag())
        }
        let env = builder.build(events: events, context: sampleContext(), flushTime: t0)
        let (_, json) = try WireAssertions.assertValidEnvelope(env)
        XCTAssertEqual(json["batch_size"] as? Int, 7)
    }
}
