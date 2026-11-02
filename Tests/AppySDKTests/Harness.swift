import XCTest
@testable import AppySDK

final class Harness {
    static let key = "appy_pk_test_4f2a9c7e1b3d"
    static let springURL = URL(string: "https://acme.appy.to/spring?item=42")!

    let transport = MockTransport()
    let clock = ManualClock()
    let logs = LogRecorder()
    let suite = "to.appy.sdk.tests.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("appy-\(UUID().uuidString)")
    let defaults: UserDefaults
    private(set) var appy: Appy!
    private(set) var deliveries: [AppyDeepLinkResult] = []
    private(set) var attributions: [AppyAttribution] = []
    private(set) var openedURLs: [URL] = []
    private(set) var mainThreadCalls: [String] = []
    private(set) var deliveredOffMain = false
    var acceptsURLs = true
    var appleAdsToken: String?
    private(set) var appleAdsTokenRequests = 0

    init() {
        defaults = UserDefaults(suiteName: suite)!
        relaunch()
    }

    var eventsFile: URL {
        directory.appendingPathComponent("AppySDK/events.json")
    }

    func relaunch() {
        if appy != nil {
            drain()
        }
        let clock = self.clock
        let logs = self.logs
        appy = Appy(
            transport: transport,
            defaults: defaults,
            eventsFile: eventsFile,
            now: { clock.now },
            after: { clock.schedule($0, $1) },
            log: { logs.record($0, $1) },
            openURL: { [unowned self] url in
                deliveredOffMain = deliveredOffMain || !Thread.isMainThread
                mainThreadCalls.append("open")
                if acceptsURLs {
                    openedURLs.append(url)
                }
                return acceptsURLs
            },
            appleAdsToken: { [unowned self] in
                appleAdsTokenRequests += 1
                return appleAdsToken
            }
        )
    }

    func configure(domains: [String] = ["acme.appy.to"], key: String = Harness.key, _ customize: (inout AppyConfiguration) -> Void = { _ in }) {
        var configuration = AppyConfiguration(publishableKey: key, linkDomains: domains)
        configuration.logLevel = .debug
        customize(&configuration)
        appy.configure(configuration)
        drain()
    }

    func launch() {
        configure()
        advance(0.5)
    }

    func relaunchAfterFirstLaunch() {
        defaults.set(true, forKey: "firstOpenCompleted")
        relaunch()
    }

    func holdLaunchOpens() {
        transport.respond { request in
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
            let isLaunchOpen = request.url?.path == "/v1/sdk/open" && body?["url"] == nil
            return isLaunchOpen ? nil : MockTransport.defaultReply(request)
        }
    }

    func drain() {
        for _ in 0..<50 {
            appy.queue.sync {}
        }
    }

    func advance(_ seconds: TimeInterval) {
        drain()
        let queue = appy.queue
        clock.advance(by: seconds) { work in
            queue.sync(execute: work)
            drain()
        }
    }

    func recordDeliveries() {
        appy.onDeepLink = { [unowned self] result in
            deliveredOffMain = deliveredOffMain || !Thread.isMainThread
            mainThreadCalls.append("onDeepLink")
            deliveries.append(result)
        }
    }

    func recordAttributions() {
        appy.onAttribution = { [unowned self] attribution in
            deliveredOffMain = deliveredOffMain || !Thread.isMainThread
            mainThreadCalls.append("onAttribution")
            attributions.append(attribution)
        }
    }

    var links: [AppyDeepLink] {
        deliveries.compactMap(\.link)
    }

    func answerOpens(with body: String) {
        transport.respond(to: "/v1/sdk/open") { .status(200, body) }
    }

    func settleOnMain() {
        drain()
        let delivered = XCTestExpectation(description: "main queue drained")
        DispatchQueue.main.async { delivered.fulfill() }
        XCTAssertEqual(XCTWaiter().wait(for: [delivered], timeout: 5), .completed)
    }

    var opens: [[String: Any]] {
        transport.bodies(to: "/v1/sdk/open")
    }

    var batches: [[[String: Any]]] {
        transport.bodies(to: "/v1/sdk/events").map { $0["events"] as? [[String: Any]] ?? [] }
    }

    var storedEvents: [[String: Any]] {
        drain()
        guard let data = try? Data(contentsOf: eventsFile) else { return [] }
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["events"] as? [[String: Any]] ?? []
    }

    func track(_ count: Int, prefix: String = "event") {
        for index in 0..<count {
            appy.track("\(prefix)_\(index)")
        }
        drain()
    }

    func tearDown() {
        drain()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}
