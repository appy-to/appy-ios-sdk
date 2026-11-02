import Foundation

public struct AppyConfiguration: Sendable {
    public var publishableKey: String
    public var linkDomains: [String]
    public var emailLinkDomains: [String] = []
    public var apiBaseURL = URL(string: "https://api.appy.to")!
    public var logLevel = AppyLogLevel.error
    public var launchLinkWaitInterval: TimeInterval = 0.5
    public var requestTimeout: TimeInterval = 10
    public var openDeferredDeepLinks = false
    public var deferredDeepLinkTimeout: TimeInterval = 5

    public init(publishableKey: String, linkDomains: [String] = []) {
        self.publishableKey = publishableKey
        self.linkDomains = linkDomains
    }
}

public enum AppyDeepLinkResult: Equatable, Sendable {
    case found(AppyDeepLink)
    case notFound
    case failed(AppyError)

    var link: AppyDeepLink? {
        if case .found(let link) = self {
            return link
        }
        return nil
    }
}

public enum AppyError: Error, Equatable, Sendable {
    case timeout
    case network
    case invalidResponse
}

public struct AppyDeepLink: Equatable, Sendable {
    public let url: URL?
    public let deeplinkURL: URL?
    public let slug: String
    public let parameters: [String: String]
    public let isDeferred: Bool
    public let clickedAt: Date?

    public init(
        url: URL? = nil,
        deeplinkURL: URL? = nil,
        slug: String,
        parameters: [String: String] = [:],
        isDeferred: Bool = false,
        clickedAt: Date? = nil
    ) {
        self.url = url
        self.deeplinkURL = deeplinkURL
        self.slug = slug
        self.parameters = parameters
        self.isDeferred = isDeferred
        self.clickedAt = clickedAt
    }
}

public struct AppyAttribution: Equatable, Sendable {
    public let isOrganic: Bool
    public let linkSlug: String?
    public let linkTitle: String?
    public let source: String?
    public let medium: String?
    public let campaign: String?
    public let clickedAt: Date?
    public let network: AppyAdNetwork?

    public init(
        isOrganic: Bool,
        linkSlug: String? = nil,
        linkTitle: String? = nil,
        source: String? = nil,
        medium: String? = nil,
        campaign: String? = nil,
        clickedAt: Date? = nil,
        network: AppyAdNetwork? = nil
    ) {
        self.isOrganic = isOrganic
        self.linkSlug = linkSlug
        self.linkTitle = linkTitle
        self.source = source
        self.medium = medium
        self.campaign = campaign
        self.clickedAt = clickedAt
        self.network = network
    }
}

public struct AppyAdNetwork: Equatable, Sendable {
    public let name: String
    public let campaignId: String?
    public let campaignName: String?
    public let adGroupId: String?
    public let adGroupName: String?
    public let adId: String?
    public let clickId: String?
    public let touch: String?

    public init(
        name: String,
        campaignId: String? = nil,
        campaignName: String? = nil,
        adGroupId: String? = nil,
        adGroupName: String? = nil,
        adId: String? = nil,
        clickId: String? = nil,
        touch: String? = nil
    ) {
        self.name = name
        self.campaignId = campaignId
        self.campaignName = campaignName
        self.adGroupId = adGroupId
        self.adGroupName = adGroupName
        self.adId = adId
        self.clickId = clickId
        self.touch = touch
    }
}

public enum AppyLogLevel: Int, Comparable, Sendable {
    case none
    case error
    case warning
    case info
    case debug

    public static func < (lhs: AppyLogLevel, rhs: AppyLogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
