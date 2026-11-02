import XCTest
@testable import AppySDK

final class DeliveryTests: XCTestCase {
    private var harness: Harness!

    override func setUp() {
        super.setUp()
        harness = Harness()
    }

    override func tearDown() {
        harness.tearDown()
        super.tearDown()
    }

    private func clickDate(_ fraction: TimeInterval = 0) -> Date {
        Date(timeIntervalSince1970: 1_790_330_645 + fraction)
    }

    func testOpenResponseIsParsedIntoTheLinkAndTheAttribution() {
        harness.recordDeliveries()
        harness.recordAttributions()
        harness.answerOpens(with: Fixture.deferred)
        harness.launch()
        harness.settleOnMain()

        XCTAssertEqual(harness.deliveries, [.found(Fixture.deferredLink)])
        XCTAssertEqual(harness.attributions, [Fixture.attributed])
        XCTAssertEqual(harness.appy.latestDeepLink, Fixture.deferredLink)
        XCTAssertEqual(harness.appy.attribution, Fixture.attributed)
        XCTAssertFalse(harness.deliveredOffMain)
    }

    func testMissingOrNullFieldsFallBackToDefaults() {
        let link = Links.deepLink(
            from: ["url": NSNull(), "deeplinkUrl": NSNull(), "slug": "spring", "parameters": ["n": 1, "s": "x"] as [String: Any], "clickedAt": NSNull()],
            openedURL: Harness.springURL
        )
        XCTAssertEqual(link, AppyDeepLink(url: Harness.springURL, slug: "spring", parameters: ["s": "x"]))
        XCTAssertEqual(Links.deepLink(from: [:], openedURL: nil), AppyDeepLink(slug: ""))

        let organic: [String: Any] = ["status": "organic", "link": NSNull(), "source": NSNull(), "medium": NSNull(), "campaign": NSNull(), "clickedAt": NSNull()]
        XCTAssertEqual(Links.attribution(from: organic), AppyAttribution(isOrganic: true))
        XCTAssertEqual(Links.attribution(from: [:]), AppyAttribution(isOrganic: true))
        XCTAssertEqual(
            Links.attribution(from: ["status": "attributed", "link": ["slug": "spring", "title": NSNull()] as [String: Any]]),
            AppyAttribution(isOrganic: false, linkSlug: "spring")
        )
    }

    func testClickedAtAcceptsCommonISO8601Forms() {
        let cases: [(String, TimeInterval)] = [
            ("2026-09-25T10:04:05Z", 0),
            ("2026-09-25T10:04:05.250Z", 0.25),
            ("2026-09-25T10:04:05.123456789Z", 0.123),
            ("2026-09-25T13:04:05+03:00", 0),
            ("2026-09-25T10:04:05.5-00:00", 0.5)
        ]
        for (text, fraction) in cases {
            XCTAssertEqual(Links.date(from: text)?.timeIntervalSince1970 ?? 0, clickDate(fraction).timeIntervalSince1970, accuracy: 0.001, text)
        }
        XCTAssertNil(Links.date(from: "yesterday"))
        XCTAssertEqual(Links.timestamp(clickDate(0.123)), "2026-09-25T10:04:05.123Z")
    }

    func testDirectOpenDeliversTheServerLinkAsFound() {
        harness.relaunchAfterFirstLaunch()
        harness.recordDeliveries()
        harness.launch()
        harness.answerOpens(with: Fixture.direct)
        XCTAssertTrue(harness.appy.handle(url: Harness.springURL))
        harness.settleOnMain()

        XCTAssertEqual(harness.deliveries, [.found(Fixture.directLink)])
        XCTAssertTrue(harness.openedURLs.isEmpty)
        XCTAssertFalse(harness.deliveredOffMain)
    }

    func testTheLatestLinkWaitsForAHandlerAndIsDeliveredOnce() {
        harness.relaunchAfterFirstLaunch()
        harness.launch()
        harness.appy.handle(url: URL(string: "https://acme.appy.to/spring")!)
        harness.appy.handle(url: URL(string: "https://acme.appy.to/summer")!)
        harness.settleOnMain()
        XCTAssertEqual(harness.appy.latestDeepLink?.slug, "summer")

        harness.recordDeliveries()
        harness.settleOnMain()
        harness.recordDeliveries()
        harness.settleOnMain()

        XCTAssertEqual(harness.links.map(\.slug), ["summer"])
        XCTAssertEqual(harness.deliveries.count, 1)
    }

    func testOfflineOpenDeliversTheLocallyParsedLink() {
        harness.relaunchAfterFirstLaunch()
        harness.recordDeliveries()
        harness.transport.respond(to: "/v1/sdk/open") { .offline }
        harness.configure()
        let url = URL(string: "https://acme.appy.to/spring?item=42&item=43&APPY_slug=x&appy_click_id=abc&q=red+shoes&note=50%25%20off")!
        harness.appy.handle(url: url)
        harness.settleOnMain()
        XCTAssertTrue(harness.deliveries.isEmpty)

        harness.advance(10)
        harness.settleOnMain()

        XCTAssertEqual(harness.opens.count, 3)
        XCTAssertEqual(harness.deliveries, [.found(AppyDeepLink(
            url: url,
            slug: "spring",
            parameters: ["item": "42", "q": "red shoes", "note": "50% off"]
        ))])
        XCTAssertTrue(harness.logs.contains("locally parsed link", at: .info))
    }

    func testNullLinkForAHandledURLDeliversTheLocalLink() {
        harness.relaunchAfterFirstLaunch()
        harness.recordDeliveries()
        harness.launch()
        let url = URL(string: "acme://items/42?appy_click_id=abc&item=42")!
        harness.appy.handle(url: url)
        harness.settleOnMain()

        XCTAssertEqual(harness.deliveries, [.found(AppyDeepLink(url: url, slug: "", parameters: ["item": "42"]))])
    }

    func testRejectedOpenForAHandledURLDeliversTheLocalLink() {
        harness.relaunchAfterFirstLaunch()
        harness.recordDeliveries()
        harness.transport.respond(to: "/v1/sdk/open") { .status(401, #"{"error":{"code":"unauthorized","message":"Unknown key"}}"#) }
        harness.configure()
        harness.appy.handle(url: Harness.springURL)
        harness.settleOnMain()

        XCTAssertEqual(harness.opens.count, 1)
        XCTAssertEqual(harness.links.map(\.slug), ["spring"])
        XCTAssertTrue(harness.logs.contains("HTTP 401 unauthorized: Unknown key", at: .error))
    }

    func testLaunchWithoutALinkAfterTheFirstLaunchDeliversNothing() {
        harness.relaunchAfterFirstLaunch()
        harness.recordDeliveries()
        harness.launch()
        harness.transport.respond(to: "/v1/sdk/open") { .offline }
        harness.relaunch()
        harness.recordDeliveries()
        harness.launch()
        harness.advance(30)
        harness.settleOnMain()

        XCTAssertEqual(harness.opens.map { $0["firstLaunch"] as? Bool }, [false, false, false, false])
        XCTAssertTrue(harness.deliveries.isEmpty)
        XCTAssertNil(harness.appy.latestDeepLink)
    }
}
