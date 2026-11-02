import Foundation

extension Appy {
    static let maximumEmailRedirects = 5

    func isEmailLink(_ url: URL) -> Bool {
        Links.host(of: url).map(emailDomains.contains) == true
    }

    func receiveEmailLink(_ url: URL) {
        if launch == .waiting {
            launch = .resolving
        }
        log(.debug, "Resolving the email link \(url.absoluteString).")
        followEmailLink(url, redirects: 0) { [weak self] destination in
            self?.finishEmailLink(url, destination: destination)
        }
    }

    func followEmailLink(_ url: URL, redirects: Int, completion: @escaping (URL?) -> Void) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: configuration?.requestTimeout ?? 10)
        request.httpMethod = "GET"
        transport.send(request) { [weak self] _, response, error in
            self?.queue.async {
                guard let self else { return }
                let http = response as? HTTPURLResponse
                let location = http.flatMap { (300...399).contains($0.statusCode) ? $0.value(forHTTPHeaderField: "Location") : nil }
                guard let location, let next = URL(string: location, relativeTo: url)?.absoluteURL else {
                    let reason = http.map { "HTTP \($0.statusCode) without a redirect" } ?? error?.localizedDescription ?? "no response"
                    self.log(.warning, "Could not resolve the email link \(url.absoluteString): \(reason).")
                    return completion(nil)
                }
                guard self.isEmailLink(next) else { return completion(next) }
                guard redirects + 1 < Self.maximumEmailRedirects else {
                    self.log(.warning, "The email link \(url.absoluteString) redirected more than \(Self.maximumEmailRedirects) times.")
                    return completion(nil)
                }
                self.followEmailLink(next, redirects: redirects + 1, completion: completion)
            }
        }
    }

    func finishEmailLink(_ emailURL: URL, destination: URL?) {
        let holdsLaunch = launch == .resolving
        guard let destination else {
            if holdsLaunch {
                beginLaunchOpen(nil)
            }
            return deliver(.found(AppyDeepLink(url: emailURL, slug: "")))
        }
        log(.info, "The email link \(emailURL.absoluteString) points to \(destination.absoluteString).")
        if isAppyLink(destination) {
            if holdsLaunch {
                beginLaunchOpen(destination)
            } else {
                sendOpen(destination, isLaunch: false)
            }
            return
        }
        if holdsLaunch {
            beginLaunchOpen(nil)
        }
        deliver(.found(Links.localLink(for: destination, domains: linkDomains)))
    }
}
