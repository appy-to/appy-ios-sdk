import XCTest
@testable import AppySDK

final class FirstLaunchTests: XCTestCase {
    private var harness: Harness!

    override func setUp() {
        super.setUp()
        harness = Harness()
    }

    override func tearDown() {
        harness.tearDown()
        super.tearDown()
    }

    func testConfigurationDefaults() {
        let configuration = AppyConfiguration(publishableKey: Harness.key)
        XCTAssertFalse(configuration.openDeferredDeepLinks)
        XCTAssertEqual(configuration.deferredDeepLinkTimeout, 5)
        XCTAssertNil(harness.appy.attribution)
        XCTAssertNil(harness.appy.latestDeepLink)
    }

    func testTheDeferredLinkIsDeliveredExactlyOnce() {
        harness.recordDeliveries()
        harness.answerOpens(with: Fixture.deferred)
        harness.launch()
        harness.advance(30)
        harness.settleOnMain()
        XCTAssertEqual(harness.deliveries, [.found(Fixture.deferredLink)])
        XCTAssertTrue(harness.openedURLs.isEmpty)
        XCTAssertFalse(harness.deliveredOffMain)

        harness.relaunch()
        harness.recordDeliveries()
        harness.launch()
        harness.advance(30)
        harness.settleOnMain()
        XCTAssertEqual(harness.opens.map { $0["firstLaunch"] as? Bool }, [true, false])
        XCTAssertEqual(harness.deliveries.count, 1)
    }

    func testAnOrganicFirstLaunchDeliversNotFound() {
        for body in [Fixture.organic, "{}", #"{"firstLaunch":true,"link":{"slug":"spring","isDeferred":true}}"#] {
            let local = Harness()
            local.recordDeliveries()
            local.answerOpens(with: body)
            local.launch()
            local.advance(30)
            local.settleOnMain()
            XCTAssertEqual(local.deliveries, [.notFound], body)
            XCTAssertNil(local.appy.latestDeepLink, body)
            local.tearDown()
        }
    }

    func testFailuresBeforeTheTimeoutAreDeliveredAndRetriedNextLaunch() {
        let cases: [(Reply, AppyError)] = [
            (.offline, .network),
            (.status(503), .network),
            (.status(429), .network),
            (.status(401, #"{"error":{"code":"unauthorized","message":"Unknown key"}}"#), .invalidResponse),
            (.status(422), .invalidResponse),
            (.status(200, "<html>Sign in to the Wi-Fi</html>"), .invalidResponse)
        ]
        for (reply, error) in cases {
            let local = Harness()
            local.recordDeliveries()
            local.transport.respond(to: "/v1/sdk/open") { reply }
            local.launch()
            local.advance(4)
            local.settleOnMain()
            XCTAssertEqual(local.deliveries, [.failed(error)], "\(error)")
            local.advance(30)
            local.settleOnMain()
            XCTAssertEqual(local.deliveries.count, 1, "\(error)")
            XCTAssertFalse(local.defaults.bool(forKey: "firstOpenCompleted"), "\(error)")

            local.relaunch()
            local.recordDeliveries()
            local.answerOpens(with: Fixture.deferred)
            local.launch()
            local.settleOnMain()
            XCTAssertEqual(local.opens.last?["firstLaunch"] as? Bool, true, "\(error)")
            XCTAssertEqual(local.deliveries, [.failed(error), .found(Fixture.deferredLink)], "\(error)")
            local.tearDown()
        }
    }

    func testTimeoutIsDeliveredOnceAndALateAnswerOnlyUpdatesAttribution() {
        harness.recordDeliveries()
        harness.recordAttributions()
        harness.transport.respond(to: "/v1/sdk/open") { nil }
        harness.configure { $0.openDeferredDeepLinks = true }
        harness.advance(4.75)
        harness.settleOnMain()
        XCTAssertTrue(harness.deliveries.isEmpty)

        harness.advance(0.25)
        harness.settleOnMain()
        XCTAssertEqual(harness.deliveries, [.failed(.timeout)])
        XCTAssertTrue(harness.logs.contains("within 5.0 s", at: .warning))

        harness.transport.complete("/v1/sdk/open", at: 0, with: .status(200, Fixture.deferred))
        harness.settleOnMain()
        XCTAssertEqual(harness.deliveries, [.failed(.timeout)])
        XCTAssertEqual(harness.attributions, [Fixture.attributed])
        XCTAssertEqual(harness.appy.attribution, Fixture.attributed)
        XCTAssertEqual(harness.appy.latestDeepLink, Fixture.deferredLink)
        XCTAssertTrue(harness.openedURLs.isEmpty)
        XCTAssertTrue(harness.logs.contains("arrived after the timeout", at: .info))
    }

    func testTheTimeoutCanBeConfigured() {
        let cases: [(TimeInterval, TimeInterval)] = [(2, 2), (8, 8), (0, 5), (-1, 5), (.nan, 5), (.infinity, 5)]
        for (configured, effective) in cases {
            let local = Harness()
            local.recordDeliveries()
            local.transport.respond(to: "/v1/sdk/open") { nil }
            local.configure { $0.deferredDeepLinkTimeout = configured }
            local.advance(effective - 0.25)
            local.settleOnMain()
            XCTAssertTrue(local.deliveries.isEmpty, "\(configured)")
            local.advance(0.25)
            local.settleOnMain()
            XCTAssertEqual(local.deliveries, [.failed(.timeout)], "\(configured)")
            local.tearDown()
        }
    }

    func testALateCallbackReceivesThePendingResultOnce() {
        harness.answerOpens(with: Fixture.organic)
        harness.launch()
        harness.settleOnMain()

        harness.recordDeliveries()
        harness.settleOnMain()
        harness.recordDeliveries()
        harness.settleOnMain()
        XCTAssertEqual(harness.deliveries, [.notFound])
    }

    func testAPendingLinkIsNotReplacedByALaterTimeout() {
        harness.holdLaunchOpens()
        harness.launch()
        harness.appy.handle(url: Harness.springURL)
        harness.advance(30)
        harness.settleOnMain()

        harness.recordDeliveries()
        harness.settleOnMain()
        XCTAssertEqual(harness.deliveries, [.found(AppyDeepLink(url: Harness.springURL, slug: "spring", parameters: ["item": "42"]))])
    }

    func testALaunchLinkIsTheOnlyFirstLaunchAnswer() {
        harness.recordDeliveries()
        harness.transport.respond(to: "/v1/sdk/open") { nil }
        harness.configure()
        harness.appy.handle(url: Harness.springURL)
        harness.advance(30)
        harness.settleOnMain()
        XCTAssertTrue(harness.deliveries.isEmpty)

        harness.transport.complete("/v1/sdk/open", at: 0, with: .status(200, Fixture.direct))
        harness.settleOnMain()
        XCTAssertEqual(harness.opens.map { $0["firstLaunch"] as? Bool }, [true])
        XCTAssertEqual(harness.deliveries, [.found(Fixture.directLink)])
    }

    func testWithTrackingOffTheLookupAndItsTimeoutStartWhenTrackingIsTurnedOn() {
        harness.recordDeliveries()
        harness.transport.respond(to: "/v1/sdk/open") { nil }
        harness.appy.isTrackingEnabled = false
        harness.configure()
        harness.advance(30)
        harness.settleOnMain()
        XCTAssertTrue(harness.opens.isEmpty)
        XCTAssertTrue(harness.deliveries.isEmpty)

        harness.appy.isTrackingEnabled = true
        harness.advance(4.75)
        harness.settleOnMain()
        XCTAssertEqual(harness.opens.map { $0["firstLaunch"] as? Bool }, [true])
        XCTAssertTrue(harness.deliveries.isEmpty)

        harness.transport.complete("/v1/sdk/open", at: 0, with: .status(200, Fixture.deferred))
        harness.advance(30)
        harness.settleOnMain()
        XCTAssertEqual(harness.deliveries, [.found(Fixture.deferredLink)])
    }

    func testOpenDeferredDeepLinksOpensTheDestinationAfterTheCallback() {
        harness.recordDeliveries()
        harness.answerOpens(with: Fixture.deferred)
        harness.configure { $0.openDeferredDeepLinks = true }
        harness.advance(0.5)
        harness.settleOnMain()
        XCTAssertEqual(harness.deliveries, [.found(Fixture.deferredLink)])
        XCTAssertEqual(harness.openedURLs, [URL(string: "acme://items?item=42")!])
        XCTAssertEqual(harness.mainThreadCalls, ["onDeepLink", "open"])
        XCTAssertFalse(harness.deliveredOffMain)

        harness.appy.handle(url: Harness.springURL)
        harness.settleOnMain()
        XCTAssertEqual(harness.deliveries.count, 2)
        XCTAssertEqual(harness.openedURLs.count, 1)
    }

    func testOpenDeferredDeepLinksWorksWithoutACallbackAndOnlyForTheAppsOwnSchemes() {
        harness.acceptsURLs = false
        harness.answerOpens(with: Fixture.deferred)
        harness.configure { $0.openDeferredDeepLinks = true }
        harness.advance(0.5)
        harness.settleOnMain()
        harness.drain()
        XCTAssertEqual(harness.mainThreadCalls, ["open"])
        XCTAssertTrue(harness.logs.contains("acme://items?item=42 was not opened", at: .warning))

        harness.recordDeliveries()
        harness.settleOnMain()
        XCTAssertEqual(harness.deliveries, [.found(Fixture.deferredLink)])
        XCTAssertEqual(harness.mainThreadCalls, ["open", "onDeepLink"])
    }

    func testDeferredLinksAreOpenedOnlyWhenEnabledAndWithADestination() {
        let withoutDestination = Fixture.deferred.replacingOccurrences(of: #""deeplinkUrl":"acme://items?item=42","#, with: "")
        for (body, enabled) in [(Fixture.deferred, false), (withoutDestination, true)] {
            let local = Harness()
            local.recordDeliveries()
            local.answerOpens(with: body)
            local.configure { $0.openDeferredDeepLinks = enabled }
            local.advance(0.5)
            local.settleOnMain()
            XCTAssertEqual(local.links.map(\.isDeferred), [true])
            XCTAssertEqual(local.mainThreadCalls, ["onDeepLink"])
            local.tearDown()
        }
    }

    func testAttributionIsDeliveredOnceAndPersistedAcrossLaunches() {
        harness.answerOpens(with: Fixture.deferred)
        harness.launch()
        harness.settleOnMain()
        XCTAssertEqual(harness.appy.attribution, Fixture.attributed)

        harness.recordAttributions()
        harness.settleOnMain()
        harness.recordAttributions()
        harness.settleOnMain()
        XCTAssertEqual(harness.attributions, [Fixture.attributed])
        XCTAssertFalse(harness.deliveredOffMain)

        harness.relaunch()
        XCTAssertEqual(harness.appy.attribution, Fixture.attributed)
        harness.recordAttributions()
        harness.launch()
        harness.settleOnMain()
        XCTAssertEqual(harness.opens.last?["firstLaunch"] as? Bool, false)
        XCTAssertEqual(harness.appy.attribution, Fixture.attributed)
        XCTAssertEqual(harness.attributions.count, 1)
    }

    func testOrganicAttributionIsDeliveredAndPersisted() {
        harness.recordAttributions()
        harness.answerOpens(with: Fixture.organic)
        harness.launch()
        harness.settleOnMain()
        XCTAssertEqual(harness.attributions, [AppyAttribution(isOrganic: true)])
        XCTAssertTrue(harness.logs.contains("The install is organic.", at: .info))

        harness.relaunch()
        XCTAssertEqual(harness.appy.attribution, AppyAttribution(isOrganic: true))
    }

    func testNoAttributionWithoutAnAnsweredFirstLaunch() {
        harness.recordAttributions()
        harness.transport.respond(to: "/v1/sdk/open") { .offline }
        harness.launch()
        harness.advance(30)
        harness.settleOnMain()
        XCTAssertNil(harness.appy.attribution)
        XCTAssertTrue(harness.attributions.isEmpty)
        XCTAssertNil(harness.defaults.object(forKey: "attribution"))
    }
}
