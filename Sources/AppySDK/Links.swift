import Foundation

enum Links {
    static let clickIdParameter = "appy_click_id"
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func normalizedDomain(_ rawDomain: String) -> String? {
        var domain = rawDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if domain.hasPrefix("applinks:") {
            domain.removeFirst("applinks:".count)
        }
        if let scheme = domain.range(of: "://") {
            domain.removeSubrange(..<scheme.upperBound)
        }
        domain = String(domain.prefix { !"/?#".contains($0) })
        if let userInfo = domain.lastIndex(of: "@") {
            domain.removeSubrange(...userInfo)
        }
        domain = String(domain.prefix { $0 != ":" })
        while domain.hasSuffix(".") {
            domain.removeLast()
        }
        return domain.isEmpty ? nil : domain
    }

    static func host(of url: URL) -> String? {
        guard var host = url.host?.lowercased() else { return nil }
        while host.hasSuffix(".") {
            host.removeLast()
        }
        return host.isEmpty ? nil : host
    }

    static func queryItems(of url: URL) -> [(name: String, value: String)] {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""
        return query.split(separator: "&").map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map { part -> String in
                let spaced = part.replacingOccurrences(of: "+", with: " ")
                return spaced.removingPercentEncoding ?? spaced
            }
            return (parts[0], parts.count > 1 ? parts[1] : "")
        }
    }

    static func isAppyLink(_ url: URL, domains: [String]) -> Bool {
        host(of: url).map(domains.contains) == true || queryItems(of: url).contains { $0.name == clickIdParameter }
    }

    static func mayBeAppyLink(_ url: URL) -> Bool {
        let isWeb = ["http", "https"].contains(url.scheme?.lowercased() ?? "") && host(of: url) != nil
        return isWeb || queryItems(of: url).contains { $0.name == clickIdParameter }
    }

    static func publicParameters(of url: URL) -> [String: String] {
        var parameters: [String: String] = [:]
        for item in queryItems(of: url) where !item.name.isEmpty && !item.name.lowercased().hasPrefix("appy_") {
            if parameters[item.name] == nil {
                parameters[item.name] = item.value
            }
        }
        return parameters
    }

    static func localLink(for url: URL, domains: [String]) -> AppyDeepLink {
        let isOnLinkDomain = host(of: url).map(domains.contains) == true
        return AppyDeepLink(
            url: url,
            slug: isOnLinkDomain ? url.pathComponents.first { $0 != "/" } ?? "" : "",
            parameters: publicParameters(of: url)
        )
    }

    static func deepLink(from json: [String: Any], openedURL: URL?) -> AppyDeepLink {
        AppyDeepLink(
            url: (json["url"] as? String).flatMap(URL.init(string:)) ?? openedURL,
            deeplinkURL: (json["deeplinkUrl"] as? String).flatMap(URL.init(string:)),
            slug: json["slug"] as? String ?? "",
            parameters: (json["parameters"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:],
            isDeferred: json["isDeferred"] as? Bool ?? false,
            clickedAt: (json["clickedAt"] as? String).flatMap(date(from:))
        )
    }

    static func attribution(from json: [String: Any]) -> AppyAttribution {
        let link = json["link"] as? [String: Any]
        return AppyAttribution(
            isOrganic: json["status"] as? String != "attributed",
            linkSlug: link?["slug"] as? String,
            linkTitle: link?["title"] as? String,
            source: json["source"] as? String,
            medium: json["medium"] as? String,
            campaign: json["campaign"] as? String,
            clickedAt: (json["clickedAt"] as? String).flatMap(date(from:)),
            network: (json["network"] as? [String: Any]).flatMap(network(from:))
        )
    }

    static func network(from json: [String: Any]) -> AppyAdNetwork? {
        guard let name = json["name"] as? String, !name.isEmpty else { return nil }
        return AppyAdNetwork(
            name: name,
            campaignId: json["campaignId"] as? String,
            campaignName: json["campaignName"] as? String,
            adGroupId: json["adGroupId"] as? String,
            adGroupName: json["adGroupName"] as? String,
            adId: json["adId"] as? String,
            clickId: json["clickId"] as? String,
            touch: json["touch"] as? String
        )
    }

    static func date(from text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let dot = text.firstIndex(of: "."), let end = text[text.index(after: dot)...].firstIndex(where: { !$0.isNumber }) else {
            return nil
        }
        let milliseconds = (text[dot..<end] + "000").prefix(4)
        return formatter.date(from: String(text[..<dot]) + milliseconds + text[end...])
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func shareLink(domain: String, slug: String, parameters: [String: String]) -> URL? {
        let slug = slug.lowercased()
        let isSlug = slug.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
        guard isSlug, (1...64).contains(slug.unicodeScalars.count) else { return nil }
        let encode = { (text: String) in text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text }
        let query = parameters.filter { !$0.key.isEmpty }
            .sorted { $0.key < $1.key }
            .map { encode($0.key) + "=" + encode($0.value) }
            .joined(separator: "&")
        return URL(string: "https://\(domain)/\(slug)" + (query.isEmpty ? "" : "?" + query))
    }
}
