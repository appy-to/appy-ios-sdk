import XCTest
@testable import AppySDK

final class NetworkAndLinkTests: XCTestCase {
    private var harness: Harness!
    private let launchTimers: [TimeInterval] = [5, 0.5]

    override func setUp() {
        super.setUp()
        harness = Harness()
    }

    override func tearDown() {
        harness.tearDown()
        super.tearDown()
    }

    func testRetryableFailuresUseThreeAttemptsWithBackoff() {
        harness.transport.respond(to: "/v1/sdk/open") { .offline }
        harness.launch()
        harness.advance(60)

        let retryDelays = Array(harness.clock.delays.drop(while: launchTimers.contains))
        XCTAssertEqual(harness.opens.count, 3)
        XCTAssertEqual(retryDelays.count, 2)
        XCTAssertEqual(retryDelays[0], 1.05, accuracy: 0.051)
        XCTAssertEqual(retryDelays[1], 2.1, accuracy: 0.101)
    }

    func testRetryAfterIsHonoredInlineUpToTenSeconds() {
        harness.transport.respond(to: "/v1/sdk/open") { .status(429, headers: ["Retry-After": "7"]) }
        harness.launch()
        harness.advance(6.75)
        XCTAssertEqual(harness.opens.count, 1)
        harness.advance(0.25)
        XCTAssertEqual(harness.opens.count, 2)
        XCTAssertEqual(harness.clock.delays.drop(while: launchTimers.contains).first, 7)

        let local = Harness()
        local.transport.respond(to: "/v1/sdk/open") { .status(503, headers: ["Retry-After": "30"]) }
        local.launch()
        local.advance(120)
        XCTAssertEqual(local.opens.count, 1)
        local.tearDown()
    }

    func testClientErrorsAreNeverRetried() {
        for status in [400, 401, 403, 404, 422] {
            let local = Harness()
            local.transport.respond(to: "/v1/sdk/open") { .status(status) }
            local.launch()
            local.advance(60)
            XCTAssertEqual(local.opens.count, 1, "HTTP \(status)")
            local.tearDown()
        }
    }

    func testBaseURLAndTimeoutComeFromTheConfiguration() {
        harness.configure {
            $0.apiBaseURL = URL(string: "https://staging.appy.to/api/")!
            $0.requestTimeout = 3
        }
        harness.advance(0.5)

        let request = harness.transport.requests(to: "/api/v1/sdk/open").first
        XCTAssertEqual(request?.url?.absoluteString, "https://staging.appy.to/api/v1/sdk/open")
        XCTAssertEqual(request?.timeoutInterval, 3)
    }

    func testUserIdIsTrimmedPersistedAndLimitedToOneHundredTwentyEightCharacters() {
        harness.launch()
        harness.appy.setUserId("  u_123 ")
        harness.drain()
        XCTAssertEqual(harness.defaults.string(forKey: "userId"), "u_123")

        let longest = String(repeating: "u", count: 128)
        harness.appy.setUserId(longest)
        harness.appy.handle(url: Harness.springURL)
        harness.drain()
        XCTAssertEqual(harness.opens.last?["userId"] as? String, longest)

        harness.appy.setUserId(longest + "u")
        harness.appy.handle(url: Harness.springURL)
        harness.drain()
        XCTAssertNil(harness.opens.last?["userId"])
        XCTAssertNil(harness.defaults.string(forKey: "userId"))
        XCTAssertTrue(harness.logs.contains("at most 128 characters", at: .error))

        harness.appy.setUserId("u_9")
        harness.relaunch()
        harness.launch()
        XCTAssertEqual(harness.opens.last?["userId"] as? String, "u_9")
    }

    func testShareLinks() {
        XCTAssertNil(harness.appy.link(slug: "spring"))
        harness.configure(domains: ["go.acme.com", "acme.appy.to"])

        XCTAssertEqual(harness.appy.link(slug: "spring")?.absoluteString, "https://go.acme.com/spring")
        XCTAssertEqual(harness.appy.link(slug: "Spring-Sale-2026")?.absoluteString, "https://go.acme.com/spring-sale-2026")
        let parameters = ["utm_source": "news letter", "item": "42", "q": "a&b=c+d/é", "": "ignored"]
        XCTAssertEqual(
            harness.appy.link(slug: "spring", parameters: parameters)?.absoluteString,
            "https://go.acme.com/spring?item=42&q=a%26b%3Dc%2Bd%2F%C3%A9&utm_source=news%20letter"
        )
        for invalid in ["", "spring sale", "spring/sale", "spring_sale", "şeker", String(repeating: "a", count: 65)] {
            XCTAssertNil(harness.appy.link(slug: invalid), invalid)
        }
        XCTAssertTrue(harness.logs.contains("is not a valid slug", at: .error))

        let roundTrip = ["q": "a&b=c+d", "name": "Çağla Öz", "empty": ""]
        XCTAssertEqual(Links.publicParameters(of: harness.appy.link(slug: "spring", parameters: roundTrip)!), roundTrip)
    }

    func testDomainNormalization() {
        let domains = [" Acme.Appy.To ", "https://user@go.acme.com:443/path", "applinks:links.acme.com?mode=developer", "", "acme.appy.to."]
        XCTAssertEqual(domains.compactMap(Links.normalizedDomain), ["acme.appy.to", "go.acme.com", "links.acme.com", "acme.appy.to"])
    }
}
