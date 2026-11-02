import Foundation

extension Appy {
    func awaitDeferredLink() {
        guard deferredWait == .notStarted, !firstOpenCompleted, let timeout = configuration?.deferredDeepLinkTimeout else { return }
        deferredWait = .waiting
        after(timeout) { [weak self] in
            guard self?.deferredWait == .waiting else { return }
            self?.log(.warning, "No deferred deep link answer within \(timeout) s; onDeepLink receives .failed(.timeout).")
            self?.answerDeferred(.failed(.timeout))
        }
    }

    func answerDeferred(_ result: AppyDeepLinkResult) {
        let link = result.link
        guard deferredWait == .waiting else {
            if deferredWait == .done, let link {
                latestLink = link
                log(.info, "The deferred deep link \(link.slug) arrived after the timeout; it is kept in latestDeepLink.")
            }
            return
        }
        deferredWait = .done
        let opensLink = configuration?.openDeferredDeepLinks == true && link?.isDeferred == true
        deliver(result, thenOpen: opensLink ? link?.deeplinkURL : nil)
    }

    func deliver(_ result: AppyDeepLinkResult, thenOpen destination: URL? = nil) {
        let link = result.link
        if let link {
            latestLink = link
        }
        let handler = self.handler
        if handler == nil, link != nil || undeliveredResult?.link == nil {
            undeliveredResult = result
        }
        guard handler != nil || destination != nil else { return }
        DispatchQueue.main.async {
            handler?(result)
            if let destination, !self.openURL(destination) {
                self.queue.async { self.log(.warning, "\(destination.absoluteString) was not opened: its scheme is not one of the app's URL schemes.") }
            }
        }
    }

    func setHandler(_ newHandler: ((AppyDeepLinkResult) -> Void)?) {
        handler = newHandler
        guard let newHandler, let result = undeliveredResult else { return }
        undeliveredResult = nil
        DispatchQueue.main.async { newHandler(result) }
    }

    func receiveAttribution(_ json: [String: Any]) {
        let attribution = Links.attribution(from: json)
        storedAttribution = attribution
        defaults.set(try? JSONSerialization.data(withJSONObject: json), forKey: "attribution")
        let source = attribution.network?.name ?? attribution.linkSlug ?? "a link"
        log(.info, attribution.isOrganic ? "The install is organic." : "The install is attributed to \(source).")
        guard let handler = attributionHandler else {
            undeliveredAttribution = attribution
            return
        }
        DispatchQueue.main.async { handler(attribution) }
    }

    func setAttributionHandler(_ newHandler: ((AppyAttribution) -> Void)?) {
        attributionHandler = newHandler
        guard let newHandler, let attribution = undeliveredAttribution else { return }
        undeliveredAttribution = nil
        DispatchQueue.main.async { newHandler(attribution) }
    }
}
