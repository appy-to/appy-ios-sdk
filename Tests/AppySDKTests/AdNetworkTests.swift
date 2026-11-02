import XCTest
@testable import AppySDK

final class AdNetworkTests: XCTestCase {
    private var harness: Harness!

    override func setUp() {
        super.setUp()
        harness = Harness()
    }

    override func tearDown() {
        harness.tearDown()
        super.tearDown()
    }

    func testTheFirstLaunchSendsTheAppleAdsTokenOnlyOnce() {
        harness.appleAdsToken = "apple-token"
        harness.answerOpens(with: Fixture.organic)
        harness.launch()
        harness.advance(30)
        harness.settleOnMain()

        harness.relaunch()
        harness.launch()
        harness.advance(30)
        harness.settleOnMain()

        XCTAssertEqual(harness.opens.map { $0["appleAdsToken"] as? String }, ["apple-token", nil])
        XCTAssertEqual(harness.appleAdsTokenRequests, 1)
    }

    func testNoTokenWhenAdServicesIsUnavailable() {
        harness.answerOpens(with: Fixture.organic)
        harness.launch()
        harness.advance(30)
        XCTAssertEqual(harness.opens.count, 1)
        XCTAssertNil(harness.opens.first?["appleAdsToken"])
    }

    func testTrackingOffSkipsTheToken() {
        harness.appleAdsToken = "apple-token"
        harness.appy.isTrackingEnabled = false
        harness.configure()
        harness.advance(30)
        XCTAssertTrue(harness.opens.isEmpty)
        XCTAssertEqual(harness.appleAdsTokenRequests, 0)
    }

    func testAdNetworkAttributionIsParsed() {
        let attribution: [String: Any] = [
            "status": "attributed", "link": NSNull(), "source": "google", "medium": "cpc", "campaign": NSNull(), "clickedAt": NSNull(),
            "network": ["name": "google_ads", "clickId": "Cj0KCQjw", "touch": "click"]
        ]
        let parsed = Links.attribution(from: attribution)
        XCTAssertFalse(parsed.isOrganic)
        XCTAssertNil(parsed.linkSlug)
        XCTAssertEqual(parsed.network, AppyAdNetwork(name: "google_ads", clickId: "Cj0KCQjw", touch: "click"))
        XCTAssertNil(Links.network(from: ["campaignId": "1"]))
    }
}

#if os(iOS)
final class AppleAdsTokenRuntimeTests: XCTestCase {
    func testTheRuntimeLookupReturnsATokenOrNilWithoutCrashing() {
        let token = Platform.appleAdsToken()
        XCTAssertTrue(token == nil || !(token ?? "").isEmpty)
    }
}
#endif
