import Foundation

public final class Appy: @unchecked Sendable {
    public static let shared = Appy(
        transport: Platform.makeSession(),
        defaults: UserDefaults(suiteName: "to.appy.sdk") ?? .standard,
        eventsFile: Platform.eventsFile
    )
    public static let sdkVersion = "1.0.0"

    enum LaunchPhase {
        case idle, waiting, resolving, sending, finished, skipped
    }

    enum DeferredWait {
        case notStarted, waiting, done
    }

    let queue = DispatchQueue(label: "to.appy.sdk", qos: .userInitiated)
    let transport: AppyTransport
    let defaults: UserDefaults
    let eventsFile: URL?
    let now: () -> Date
    let after: (TimeInterval, @escaping () -> Void) -> Void
    let logSink: (AppyLogLevel, String) -> Void
    let openURL: (URL) -> Bool
    let appleAdsToken: () -> String?
    let installId: String
    var configuration: AppyConfiguration?
    var linkDomains: [String] = []
    var emailDomains: [String] = []
    var firstOpenCompleted: Bool
    var trackingOn: Bool
    var userIdValue: String?
    var capturedDevice: [String: Any] = [:]
    var handler: ((AppyDeepLinkResult) -> Void)?
    var undeliveredResult: AppyDeepLinkResult?
    var latestLink: AppyDeepLink?
    var deferredWait = DeferredWait.notStarted
    var attributionHandler: ((AppyAttribution) -> Void)?
    var undeliveredAttribution: AppyAttribution?
    var storedAttribution: AppyAttribution?
    var earlyURLs: [URL] = []
    var launch = LaunchPhase.idle
    var hasSentOpen = false
    var events: [[String: Any]] = []
    var flushWanted = false
    var isSending = false
    var isBackingOff = false
    var debounceGeneration = 0
    var failedFlushes = 0
    var suspensionWaiters: [() -> Void] = []
    var isSaveScheduled = false

    init(
        transport: AppyTransport,
        defaults: UserDefaults,
        eventsFile: URL?,
        now: @escaping () -> Date = Date.init,
        after: ((TimeInterval, @escaping () -> Void) -> Void)? = nil,
        log: @escaping (AppyLogLevel, String) -> Void = Platform.log,
        openURL: @escaping (URL) -> Bool = Platform.openURL,
        appleAdsToken: @escaping () -> String? = Platform.appleAdsToken
    ) {
        let queue = self.queue
        self.transport = transport
        self.defaults = defaults
        self.eventsFile = eventsFile
        self.now = now
        self.after = after ?? { delay, work in queue.asyncAfter(deadline: .now() + delay, execute: work) }
        logSink = log
        self.openURL = openURL
        self.appleAdsToken = appleAdsToken
        let storedId = defaults.string(forKey: "installId") ?? ""
        installId = UUID(uuidString: storedId) == nil ? UUID().uuidString.lowercased() : storedId
        defaults.set(installId, forKey: "installId")
        firstOpenCompleted = defaults.bool(forKey: "firstOpenCompleted")
        trackingOn = defaults.object(forKey: "trackingEnabled") as? Bool ?? true
        userIdValue = defaults.string(forKey: "userId")
        let savedAttribution = defaults.data(forKey: "attribution").flatMap { try? JSONSerialization.jsonObject(with: $0) }
        storedAttribution = (savedAttribution as? [String: Any]).map(Links.attribution(from:))
        queue.async { self.loadEvents() }
    }

    public static func configure(_ configuration: AppyConfiguration) {
        shared.configure(configuration)
    }

    public var onDeepLink: ((AppyDeepLinkResult) -> Void)? {
        get { queue.sync { handler } }
        set { queue.async { self.setHandler(newValue) } }
    }

    public var onAttribution: ((AppyAttribution) -> Void)? {
        get { queue.sync { attributionHandler } }
        set { queue.async { self.setAttributionHandler(newValue) } }
    }

    public var attribution: AppyAttribution? {
        queue.sync { storedAttribution }
    }

    public var latestDeepLink: AppyDeepLink? {
        queue.sync { latestLink }
    }

    @discardableResult
    public func handle(url: URL) -> Bool {
        queue.sync { receive(url) }
    }

    @discardableResult
    public func handle(userActivity: NSUserActivity) -> Bool {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb, let url = userActivity.webpageURL else {
            return false
        }
        return handle(url: url)
    }

    public func setUserId(_ userId: String?) {
        queue.async { self.storeUserId(userId) }
    }

    public var isTrackingEnabled: Bool {
        get { queue.sync { trackingOn } }
        set { queue.async { self.setTracking(newValue) } }
    }

    public func link(slug: String, parameters: [String: String] = [:]) -> URL? {
        queue.sync { () -> URL? in
            guard let domain = linkDomains.first else {
                log(.error, "link(slug:parameters:) needs Appy.configure with at least one link domain.")
                return nil
            }
            let url = Links.shareLink(domain: domain, slug: slug, parameters: parameters)
            if url == nil {
                log(.error, "\"\(slug)\" is not a valid slug: use 1-64 characters from a-z, 0-9 and hyphen.")
            }
            return url
        }
    }

    public func flush() {
        queue.async { self.requestFlush() }
    }

    func configure(_ configuration: AppyConfiguration) {
        let captureDevice = { [weak self] in
            let values = Platform.mainThreadDeviceValues()
            self?.queue.async { self?.capturedDevice = values }
        }
        if Thread.isMainThread {
            captureDevice()
        } else {
            DispatchQueue.main.async(execute: captureDevice)
        }
        queue.async { self.start(configuration) }
    }

    func start(_ requested: AppyConfiguration) {
        guard configuration == nil else {
            return log(.error, "Appy.configure was called more than once; the first configuration stays active.")
        }
        var config = requested
        config.publishableKey = requested.publishableKey.trimmingCharacters(in: .whitespacesAndNewlines)
        config.launchLinkWaitInterval = requested.launchLinkWaitInterval.isFinite ? max(0, requested.launchLinkWaitInterval) : 0.5
        config.requestTimeout = requested.requestTimeout > 0 ? requested.requestTimeout : 10
        let timeout = requested.deferredDeepLinkTimeout
        config.deferredDeepLinkTimeout = timeout.isFinite && timeout > 0 ? timeout : 5
        configuration = config
        for domain in requested.linkDomains.compactMap(Links.normalizedDomain) where !linkDomains.contains(domain) {
            linkDomains.append(domain)
        }
        for domain in requested.emailLinkDomains.compactMap(Links.normalizedDomain) where !linkDomains.contains(domain) && !emailDomains.contains(domain) {
            emailDomains.append(domain)
        }
        let keyPreview = config.publishableKey.prefix(12)
        if !config.publishableKey.hasPrefix("appy_pk_") {
            log(.error, "The publishable key \(keyPreview)… does not start with appy_pk_.")
        }
        if linkDomains.isEmpty {
            log(.warning, "No link domains are configured; only URLs with appy_click_id are recognized.")
        }
        log(.info, "Configured Appy \(Appy.sdkVersion) with key \(keyPreview)…, domains \(linkDomains), email domains \(emailDomains), install \(installId).")
        Platform.observeBackground { [weak self] done in
            guard let self else { return done() }
            self.queue.async { self.flushBeforeSuspension(done) }
        }
        let early = earlyURLs
        earlyURLs.removeAll()
        let links = early.filter { !isEmailLink($0) && isAppyLink($0) }
        if !trackingOn {
            skipLaunchOpen()
            links.forEach { sendOpen($0, isLaunch: false) }
        } else if let first = links.first {
            beginLaunchOpen(first)
            links.dropFirst().forEach { sendOpen($0, isLaunch: false) }
        } else {
            awaitDeferredLink()
            launch = .waiting
            after(config.launchLinkWaitInterval) { [weak self] in
                if self?.launch == .waiting {
                    self?.beginLaunchOpen(nil)
                }
            }
        }
        early.filter(isEmailLink).forEach(receiveEmailLink)
    }

    func receive(_ url: URL) -> Bool {
        guard configuration != nil else {
            guard Links.mayBeAppyLink(url) else { return false }
            earlyURLs = Array((earlyURLs + [url]).suffix(10))
            return true
        }
        if isEmailLink(url) {
            receiveEmailLink(url)
            return true
        }
        guard isAppyLink(url) else { return false }
        if launch == .waiting {
            beginLaunchOpen(url)
        } else {
            sendOpen(url, isLaunch: false)
        }
        return true
    }

    func isAppyLink(_ url: URL) -> Bool {
        let isLink = Links.isAppyLink(url, domains: linkDomains)
        if !isLink {
            log(.debug, "Ignoring \(url.absoluteString): not an Appy link.")
        }
        return isLink
    }

    func beginLaunchOpen(_ url: URL?) {
        launch = .sending
        if url != nil {
            deferredWait = .done
        }
        sendOpen(url, isLaunch: true)
    }

    func skipLaunchOpen() {
        launch = .skipped
        log(.info, "Tracking is disabled, so the launch open and deferred matching are skipped.")
        pump()
    }

    func setTracking(_ enabled: Bool) {
        trackingOn = enabled
        defaults.set(enabled, forKey: "trackingEnabled")
        if !enabled {
            clearEvents()
            if launch == .waiting {
                skipLaunchOpen()
            }
        } else if launch == .skipped, !hasSentOpen {
            awaitDeferredLink()
            beginLaunchOpen(nil)
        }
    }

    func storeUserId(_ userId: String?) {
        var value = userId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if value?.isEmpty == true {
            value = nil
        }
        if let rejected = value, rejected.unicodeScalars.count > 128 {
            log(.error, "User IDs must be at most 128 characters; the user ID was cleared.")
            value = nil
        }
        userIdValue = value
        defaults.set(value, forKey: "userId")
    }

    func log(_ level: AppyLogLevel, _ message: @autoclosure () -> String) {
        guard level != .none, level <= (configuration?.logLevel ?? .error) else { return }
        logSink(level, "[Appy] \(message())")
    }
}
