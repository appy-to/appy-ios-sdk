import XCTest
@testable import AppySDK

final class DeduplicationTests: XCTestCase {
    private var harness: Harness!

    override func setUp() {
        super.setUp()
        harness = Harness()
    }

    override func tearDown() {
        harness.tearDown()
        super.tearDown()
    }

    private var storedIds: [String] {
        harness.storedEvents.compactMap { $0["id"] as? String }
    }

    private var sentIds: [[String]] {
        harness.batches.map { $0.compactMap { $0["id"] as? String } }
    }

    func testDeduplicationIdIsSentAsTheEventId() throws {
        let longest = String(repeating: "~", count: 127) + "!"
        harness.launch()
        harness.appy.track("purchase", properties: ["sku": "A1"], revenue: Decimal(string: "9.99"), currency: "USD", deduplicationId: " \t2000000123456789\n")
        harness.appy.track("restore", deduplicationId: longest)
        harness.appy.track("share")
        harness.advance(2)

        let batch = try XCTUnwrap(harness.batches.first)
        XCTAssertEqual(batch.count, 3)
        XCTAssertEqual(batch[0]["id"] as? String, "2000000123456789")
        XCTAssertEqual(Set(batch[0].keys), ["id", "name", "timestamp", "properties", "revenue", "currency"])
        XCTAssertEqual(batch[1]["id"] as? String, longest)
        XCTAssertNotNil(UUID(uuidString: batch[2]["id"] as? String ?? ""))
        let text = String(decoding: harness.transport.requests(to: "/v1/sdk/events").first?.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(text.contains(#""id":"2000000123456789""#), text)
        XCTAssertFalse(harness.logs.messages.contains { $0.contains("deduplicationId") })
    }

    func testInvalidDeduplicationIdsFallBackToGeneratedIds() {
        harness.transport.respond(to: "/v1/sdk/events") { nil }
        harness.launch()
        let invalid = ["", "   \n", String(repeating: "x", count: 129), "order 42", "order 42", "caf\u{E9}", "tab\there", "del\u{7F}"]
        invalid.forEach { harness.appy.track("purchase", deduplicationId: $0) }

        let ids = storedIds
        XCTAssertEqual(ids.count, invalid.count)
        XCTAssertEqual(Set(ids).count, invalid.count)
        XCTAssertTrue(ids.allSatisfy { UUID(uuidString: $0) != nil }, "\(ids)")
        XCTAssertTrue(harness.logs.contains("deduplicationId is empty", at: .error))
        XCTAssertTrue(harness.logs.contains("deduplicationId has 129 characters", at: .error))
        XCTAssertTrue(harness.logs.contains("deduplicationId contains a space", at: .error))
        XCTAssertTrue(harness.logs.contains("deduplicationId contains U+00E9, which is not printable ASCII", at: .error))
        XCTAssertTrue(harness.logs.contains("deduplicationId contains U+0009", at: .error))
        XCTAssertTrue(harness.logs.contains("deduplicationId contains U+007F", at: .error))
        XCTAssertTrue(harness.logs.contains("A generated ID was used", at: .error))
    }

    func testDuplicateIdsInTheQueueAreDropped() throws {
        harness.transport.respond(to: "/v1/sdk/events") { nil }
        harness.launch()
        harness.appy.track("purchase", properties: ["attempt": 1], deduplicationId: "T1")
        harness.appy.track("purchase", properties: ["attempt": 2], deduplicationId: " T1 ")
        harness.appy.track("restore", deduplicationId: "T2")
        harness.appy.track("restore", deduplicationId: "t2")

        XCTAssertEqual(storedIds, ["T1", "T2", "t2"])
        let first = try XCTUnwrap(harness.storedEvents.first?["properties"] as? [String: Any])
        XCTAssertEqual(first["attempt"] as? Int, 1)
        XCTAssertTrue(harness.logs.contains("Event \"purchase\" with deduplicationId T1 is already queued; this one was dropped.", at: .info))

        harness.appy.flush()
        harness.drain()
        XCTAssertEqual(sentIds, [["T1", "T2", "t2"]])
        harness.appy.track("purchase", deduplicationId: "T1")
        XCTAssertEqual(storedIds, ["T1", "T2", "t2"])

        harness.transport.complete("/v1/sdk/events", at: 0, with: .status(202, "{}"))
        harness.drain()
        XCTAssertTrue(harness.storedEvents.isEmpty)
        harness.appy.track("purchase", deduplicationId: "T1")
        harness.appy.flush()
        harness.drain()
        XCTAssertEqual(sentIds, [["T1", "T2", "t2"], ["T1"]])
    }

    func testDeduplicationIdSurvivesARelaunch() {
        harness.transport.respond(to: "/v1/sdk/open") { nil }
        harness.launch()
        harness.appy.track("purchase", revenue: 5, currency: "USD", deduplicationId: "2000000123456789")
        XCTAssertEqual(storedIds, ["2000000123456789"])

        harness.relaunch()
        harness.transport.respond { MockTransport.defaultReply($0) }
        harness.configure()
        harness.appy.track("purchase", revenue: 5, currency: "USD", deduplicationId: "2000000123456789")
        XCTAssertEqual(storedIds, ["2000000123456789"])
        XCTAssertTrue(harness.logs.contains("deduplicationId 2000000123456789 is already queued", at: .info))

        harness.advance(0.5)
        XCTAssertEqual(sentIds, [["2000000123456789"]])
        XCTAssertEqual(harness.batches.first?.first?["revenue"] as? Int, 5)
        XCTAssertTrue(harness.storedEvents.isEmpty)
    }
}
