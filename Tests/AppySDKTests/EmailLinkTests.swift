import XCTest
@testable import AppySDK

final class EmailLinkTests: XCTestCase {
    private var harness: Harness!
    private let emailURL = URL(string: "https://links.example.com/uni/ls/click?upn=abc123")!
    private let clickPath = "/uni/ls/click"

    override func setUp() {
        super.setUp()
        harness = Harness()
    }

    override func tearDown() {
        harness.tearDown()
        super.tearDown()
    }

    private func redirect(_ host: String, to location: String) {
        harness.transport.respond { request in
            request.url?.host == host ? .status(302, "", headers: ["Location": location]) : MockTransport.defaultReply(request)
        }
    }

    private func configureWithEmailDomains(_ domains: [String] = ["links.example.com"]) {
        harness.configure { $0.emailLinkDomains = domains }
    }

    func testEmailLinkIsResolvedToTheAppyLinkWithoutFollowingIt() throws {
        harness.recordDeliveries()
        configureWithEmailDomains()
        harness.advance(0.5)
        redirect("links.example.com", to: Harness.springURL.absoluteString)

        XCTAssertTrue(harness.appy.handle(url: emailURL))
        harness.settleOnMain()

        let request = try XCTUnwrap(harness.transport.requests(to: clickPath).first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url, emailURL)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(harness.opens.last?["url"] as? String, Harness.springURL.absoluteString)
        XCTAssertEqual(harness.links.last?.slug, "spring")
        XCTAssertEqual(harness.links.last?.url, Harness.springURL)
    }

    func testEmailLinkToAWebsiteIsDeliveredWithoutAnOpen() {
        harness.recordDeliveries()
        configureWithEmailDomains()
        harness.advance(0.5)
        let opensBefore = harness.opens.count
        redirect("links.example.com", to: "https://shop.example.com/shoes?color=red")

        XCTAssertTrue(harness.appy.handle(url: emailURL))
        harness.settleOnMain()

        XCTAssertEqual(harness.opens.count, opensBefore)
        XCTAssertEqual(harness.links.last, AppyDeepLink(url: URL(string: "https://shop.example.com/shoes?color=red")!, slug: "", parameters: ["color": "red"]))
    }

    func testRelativeAndChainedRedirectsAreFollowedAcrossEmailDomains() {
        harness.recordDeliveries()
        configureWithEmailDomains(["links.example.com", "click.example.net"])
        harness.advance(0.5)
        harness.transport.respond { request in
            switch (request.url?.host, request.url?.path) {
            case ("links.example.com", "/uni/ls/click"):
                return .status(301, "", headers: ["Location": "/uni/hop"])
            case ("links.example.com", "/uni/hop"):
                return .status(307, "", headers: ["Location": "https://click.example.net/c/1"])
            case ("click.example.net", _):
                return .status(302, "", headers: ["Location": Harness.springURL.absoluteString])
            default:
                return MockTransport.defaultReply(request)
            }
        }

        harness.appy.handle(url: emailURL)
        harness.settleOnMain()

        XCTAssertEqual(harness.transport.requests(to: "/uni/hop").count, 1)
        XCTAssertEqual(harness.transport.requests(to: "/c/1").count, 1)
        XCTAssertEqual(harness.links.last?.slug, "spring")
    }

    func testUnresolvableEmailLinkIsDeliveredAsIs() {
        harness.recordDeliveries()
        configureWithEmailDomains()
        harness.advance(0.5)
        harness.transport.respond { request in
            request.url?.host == "links.example.com" ? .offline : MockTransport.defaultReply(request)
        }

        XCTAssertTrue(harness.appy.handle(url: emailURL))
        harness.settleOnMain()

        XCTAssertEqual(harness.links.last, AppyDeepLink(url: emailURL, slug: ""))
        XCTAssertTrue(harness.logs.contains("Could not resolve the email link", at: .warning))
    }

    func testRedirectLoopsStopAfterFiveRequests() {
        harness.recordDeliveries()
        configureWithEmailDomains()
        harness.advance(0.5)
        redirect("links.example.com", to: emailURL.absoluteString)

        harness.appy.handle(url: emailURL)
        harness.settleOnMain()

        XCTAssertEqual(harness.transport.requests(to: clickPath).count, Appy.maximumEmailRedirects)
        XCTAssertEqual(harness.links.last, AppyDeepLink(url: emailURL, slug: ""))
    }

    func testEmailLinkThatLaunchedTheAppBecomesTheLaunchOpen() {
        harness.recordDeliveries()
        harness.transport.respond { request in
            request.url?.host == "links.example.com" ? nil : MockTransport.defaultReply(request)
        }

        XCTAssertTrue(harness.appy.handle(url: emailURL))
        configureWithEmailDomains()
        harness.advance(2)
        XCTAssertTrue(harness.opens.isEmpty)

        harness.transport.complete(clickPath, at: 0, with: .status(302, "", headers: ["Location": Harness.springURL.absoluteString]))
        harness.settleOnMain()

        XCTAssertEqual(harness.opens.count, 1)
        XCTAssertEqual(harness.opens.first?["url"] as? String, Harness.springURL.absoluteString)
        XCTAssertEqual(harness.opens.first?["firstLaunch"] as? Bool, true)
        XCTAssertEqual(harness.links.last?.slug, "spring")
    }

    func testLaunchOpenStillHappensWhenTheEmailLinkLeadsElsewhere() {
        harness.recordDeliveries()
        redirect("links.example.com", to: "https://shop.example.com/")

        harness.appy.handle(url: emailURL)
        configureWithEmailDomains()
        harness.advance(0.5)
        harness.settleOnMain()

        XCTAssertEqual(harness.opens.count, 1)
        XCTAssertNil(harness.opens.first?["url"])
        XCTAssertTrue(harness.links.contains(AppyDeepLink(url: URL(string: "https://shop.example.com/")!, slug: "")))
    }

    func testLinkDomainsWinOverEmailDomainsAndOtherHostsAreIgnored() {
        harness.configure { $0.emailLinkDomains = ["acme.appy.to", "links.example.com"] }
        harness.advance(0.5)

        XCTAssertTrue(harness.appy.handle(url: Harness.springURL))
        XCTAssertFalse(harness.appy.handle(url: URL(string: "https://elsewhere.example.org/uni/ls/click?upn=1")!))
        harness.drain()

        XCTAssertTrue(harness.transport.requests(to: clickPath).isEmpty)
        XCTAssertEqual(harness.opens.last?["url"] as? String, Harness.springURL.absoluteString)
    }
}
