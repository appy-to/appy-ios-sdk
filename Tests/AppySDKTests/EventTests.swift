import XCTest
@testable import AppySDK

final class EventTests: XCTestCase {
    private var harness: Harness!

    override func setUp() {
        super.setUp()
        harness = Harness()
    }

    override func tearDown() {
        harness.tearDown()
        super.tearDown()
    }

    private var eventNames: [String] {
        harness.storedEvents.compactMap { $0["name"] as? String }
    }

    func testEventValidation() throws {
        harness.transport.respond(to: "/v1/sdk/events") { nil }
        harness.launch()
        let properties: [String: Any] = [
            "sku": "A1", "qty": 2, "price": 9.99, "gift": false, "flag": NSNumber(value: true),
            "note": String(repeating: "é", count: 600), String(repeating: "k", count: 65): "x", "": "empty",
            "when": Date(), "tags": ["a"], "nothing": NSNull(), "nan": Double.nan
        ]
        harness.appy.track("  purchase \n", properties: properties, revenue: Decimal(string: "19.98"), currency: " usd ")
        harness.appy.track("")
        harness.appy.track(String(repeating: "a", count: 65))
        harness.appy.track(String(repeating: "a", count: 64))
        harness.appy.track("bad_currency", revenue: 5, currency: "US")
        harness.appy.track("huge", revenue: Decimal(string: "1000000000000"), currency: "USD")
        harness.appy.track("orphan_currency", currency: "EUR")
        var many: [String: Any] = [:]
        (0..<60).forEach { many[String(format: "key%02d", $0)] = $0 }
        harness.appy.track("many", properties: many)

        let stored = harness.storedEvents
        XCTAssertEqual(stored.compactMap { $0["name"] as? String }, ["purchase", String(repeating: "a", count: 64), "bad_currency", "huge", "orphan_currency", "many"])
        let purchase = try XCTUnwrap(stored.first)
        let kept = try XCTUnwrap(purchase["properties"] as? [String: Any])
        XCTAssertEqual(Set(kept.keys), ["sku", "qty", "price", "gift", "flag", "note"])
        XCTAssertEqual((kept["note"] as? String)?.unicodeScalars.count, 512)
        XCTAssertEqual(purchase["revenue"] as? String, "19.98")
        XCTAssertEqual(purchase["currency"] as? String, "USD")
        XCTAssertNil(stored[2]["revenue"])
        XCTAssertNil(stored[2]["currency"])
        XCTAssertNil(stored[3]["revenue"])
        XCTAssertNil(stored[4]["currency"])
        XCTAssertEqual((stored[5]["properties"] as? [String: Any])?.count, 50)
        XCTAssertNotNil((stored[5]["properties"] as? [String: Any])?["key49"])
        XCTAssertTrue(harness.logs.contains("Event names must be 1-64 characters", at: .error))
        XCTAssertTrue(harness.logs.contains("three-letter currency code", at: .warning))
        XCTAssertTrue(harness.logs.contains("property \"tags\" was dropped", at: .debug))
    }

    func testEventsWireFormat() throws {
        harness.appy.setUserId("u_123")
        harness.launch()
        harness.appy.track("purchase", properties: ["sku": "A1", "qty": 2, "gift": false], revenue: Decimal(string: "19.98"), currency: "USD")
        harness.appy.setUserId(nil)
        harness.appy.track("share")
        harness.advance(2)

        let request = try XCTUnwrap(harness.transport.requests(to: "/v1/sdk/events").first)
        let text = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(text.contains(#""revenue":19.98"#), text)
        XCTAssertFalse(text.contains("null"))
        XCTAssertEqual(harness.transport.bodies(to: "/v1/sdk/events").first?["installId"] as? String, harness.defaults.string(forKey: "installId"))
        let purchase = try XCTUnwrap(harness.batches.first?.first)
        XCTAssertEqual(Set(purchase.keys), ["id", "name", "timestamp", "properties", "revenue", "currency", "userId"])
        XCTAssertEqual(purchase["timestamp"] as? String, "2026-09-25T10:00:00.500Z")
        XCTAssertEqual(purchase["userId"] as? String, "u_123")
        XCTAssertNotNil(UUID(uuidString: purchase["id"] as? String ?? ""))
        let share = try XCTUnwrap(harness.batches.first?.last)
        XCTAssertEqual(Set(share.keys), ["id", "name", "timestamp", "properties"])
        XCTAssertEqual((share["properties"] as? [String: Any])?.count, 0)
    }

    func testNothingIsSentBeforeTheLaunchOpenFinishes() {
        harness.transport.respond(to: "/v1/sdk/open") { nil }
        harness.launch()
        harness.track(25)
        harness.appy.flush()
        harness.advance(10)
        XCTAssertTrue(harness.batches.isEmpty)

        harness.transport.complete("/v1/sdk/open", at: 0, with: .status(200, #"{"deepLink":null}"#))
        harness.drain()
        XCTAssertEqual(harness.batches.map(\.count), [25])
        XCTAssertTrue(harness.storedEvents.isEmpty)
    }

    func testFlushTriggers() {
        harness.launch()
        harness.track(1)
        harness.advance(1.5)
        harness.track(1, prefix: "second")
        harness.advance(1.75)
        XCTAssertTrue(harness.batches.isEmpty)
        harness.advance(0.25)
        XCTAssertEqual(harness.batches.map(\.count), [2])

        harness.track(19)
        XCTAssertEqual(harness.batches.count, 1)
        harness.track(1, prefix: "twentieth")
        XCTAssertEqual(harness.batches.map(\.count), [2, 20])

        harness.track(3)
        harness.appy.flush()
        harness.drain()
        XCTAssertEqual(harness.batches.map(\.count), [2, 20, 3])
    }

    func testBatchesHoldAtMostOneHundredEventsAndTwoHundredFiftySixKilobytes() {
        harness.transport.respond(to: "/v1/sdk/open") { nil }
        harness.launch()
        harness.track(250)
        harness.transport.complete("/v1/sdk/open", at: 0, with: .status(200, "{}"))
        harness.drain()
        XCTAssertEqual(harness.batches.map(\.count), [100, 100, 50])

        let bulky = Dictionary(uniqueKeysWithValues: (0..<10).map { ("field\($0)", String(repeating: "x", count: 500)) })
        (0..<120).forEach { _ in harness.appy.track("bulky", properties: bulky) }
        harness.appy.flush()
        harness.drain()

        let sizes = harness.transport.requests(to: "/v1/sdk/events").map { $0.httpBody?.count ?? 0 }
        XCTAssertEqual(harness.batches.reduce(0) { $0 + $1.count }, 370)
        XCTAssertTrue(harness.batches.dropFirst(3).allSatisfy { $0.count < 100 })
        XCTAssertTrue(sizes.allSatisfy { $0 <= 256 * 1024 }, "\(sizes)")
        XCTAssertTrue(sizes.dropFirst(3).contains { $0 > 200 * 1024 }, "\(sizes)")
        XCTAssertTrue(harness.storedEvents.isEmpty)
    }

    func testQueueIsPersistedAcrossLaunchesAndCappedAtOneThousand() {
        harness.transport.respond(to: "/v1/sdk/open") { nil }
        harness.launch()
        harness.track(1005)
        XCTAssertEqual(eventNames.count, 1000)
        XCTAssertEqual(eventNames.first, "event_5")
        XCTAssertTrue(harness.logs.contains("The event queue is full", at: .warning))

        harness.relaunch()
        harness.transport.respond { MockTransport.defaultReply($0) }
        harness.launch()
        XCTAssertEqual(harness.batches.reduce(0) { $0 + $1.count }, 1000)
        XCTAssertEqual(harness.batches.first?.first?["name"] as? String, "event_5")
        XCTAssertTrue(harness.storedEvents.isEmpty)
    }

    func testAcceptedBatchesAreRemovedAndRejectedEventsLogged() {
        harness.transport.respond(to: "/v1/sdk/events") {
            .status(202, #"{"accepted":1,"duplicates":0,"rejected":[{"index":1,"id":"abc12345","message":"name must be 1-64 printable characters"}]}"#)
        }
        harness.launch()
        harness.track(2)
        harness.appy.flush()
        harness.drain()

        XCTAssertTrue(harness.storedEvents.isEmpty)
        XCTAssertTrue(harness.logs.contains("Event abc12345 was rejected: name must be 1-64 printable characters", at: .warning))
    }

    func testClientErrorsDropTheBatch() {
        harness.transport.respond(to: "/v1/sdk/events") { .status(400, #"{"error":{"code":"validation_failed","message":"bad batch"}}"#) }
        harness.launch()
        harness.track(3)
        harness.appy.flush()
        harness.advance(600)

        XCTAssertEqual(harness.batches.map(\.count), [3])
        XCTAssertTrue(harness.storedEvents.isEmpty)
        XCTAssertTrue(harness.logs.contains("rejected 3 event(s) with HTTP 400", at: .error))
    }

    func testRetryableFailuresKeepEventsAndBackOff() {
        harness.transport.respond(to: "/v1/sdk/events") { .status(503) }
        harness.launch()
        harness.track(2)
        harness.appy.flush()
        harness.advance(3.5)
        XCTAssertEqual(harness.batches.count, 3)
        XCTAssertEqual(harness.storedEvents.count, 2)

        harness.transport.respond { MockTransport.defaultReply($0) }
        harness.advance(3)
        XCTAssertEqual(harness.batches.count, 3)
        harness.advance(1.5)
        XCTAssertEqual(harness.batches.count, 4)
        XCTAssertTrue(harness.storedEvents.isEmpty)
    }

    func testLongRetryAfterIsHonoredBetweenFlushes() {
        harness.transport.respond(to: "/v1/sdk/events") { .status(429, headers: ["Retry-After": "120"]) }
        harness.launch()
        harness.track(2)
        harness.appy.flush()
        harness.drain()
        XCTAssertEqual(harness.batches.count, 1)

        harness.transport.respond { MockTransport.defaultReply($0) }
        harness.track(1, prefix: "late")
        harness.advance(119)
        XCTAssertEqual(harness.batches.count, 1)
        harness.advance(1)
        XCTAssertEqual(harness.batches.map(\.count), [2, 3])
    }

    func testBackgroundFlushFinishesAfterTheUpload() {
        harness.transport.respond(to: "/v1/sdk/events") { nil }
        harness.launch()
        harness.track(2)
        var finished = false
        let appy = harness.appy!
        appy.queue.async { appy.flushBeforeSuspension { finished = true } }
        harness.drain()
        XCTAssertEqual(harness.batches.map(\.count), [2])
        XCTAssertFalse(harness.appy.queue.sync { finished })

        harness.transport.complete("/v1/sdk/events", at: 0, with: .status(202, "{}"))
        harness.drain()
        XCTAssertTrue(harness.appy.queue.sync { finished })
    }

    func testOptOutClearsTheQueueAndDropsNewEvents() {
        harness.transport.respond(to: "/v1/sdk/events") { nil }
        harness.launch()
        harness.track(2)
        XCTAssertEqual(eventNames.count, 2)

        harness.appy.isTrackingEnabled = false
        harness.appy.track("after_opt_out")
        harness.appy.flush()
        harness.advance(60)

        XCTAssertFalse(harness.appy.isTrackingEnabled)
        XCTAssertTrue(harness.storedEvents.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.eventsFile.path))
        XCTAssertTrue(harness.batches.isEmpty)
    }
}
