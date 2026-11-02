import Foundation

protocol AppyTransport {
    func send(_ request: URLRequest, completion: @escaping (Data?, URLResponse?, Error?) -> Void)
}

extension URLSession: AppyTransport {
    func send(_ request: URLRequest, completion: @escaping (Data?, URLResponse?, Error?) -> Void) {
        dataTask(with: request, completionHandler: completion).resume()
    }
}

extension Appy {
    static let maximumAttempts = 3
    static let maximumInlineRetryAfter: TimeInterval = 10

    static func isRetryable(_ status: Int) -> Bool {
        status == 0 || status == 429 || status >= 500
    }

    func sendOpen(_ url: URL?, isLaunch: Bool) {
        let firstLaunch = trackingOn && !hasSentOpen && !firstOpenCompleted
        hasSentOpen = true
        var body: [String: Any] = [
            "installId": installId,
            "firstLaunch": firstLaunch,
            "trackingEnabled": trackingOn,
            "device": Platform.deviceValues().merging(capturedDevice) { _, captured in captured },
            "app": Platform.appValues(),
            "sdkVersion": Appy.sdkVersion
        ]
        body["url"] = url?.absoluteString
        body["userId"] = trackingOn ? userIdValue : nil
        if firstLaunch {
            body["appleAdsToken"] = appleAdsToken()
        }
        log(.debug, "Opening session (firstLaunch \(firstLaunch), url \(url?.absoluteString ?? "none")).")
        post("v1/sdk/open", body) { [weak self] status, json, _ in
            self?.finishOpen(url: url, firstLaunch: firstLaunch, isLaunch: isLaunch, status: status, json: json)
        }
    }

    func finishOpen(url: URL?, firstLaunch: Bool, isLaunch: Bool, status: Int, json: [String: Any]?) {
        let answer = (200...299).contains(status) ? json : nil
        if let answer, firstLaunch {
            firstOpenCompleted = true
            defaults.set(true, forKey: "firstOpenCompleted")
            if let attribution = answer["attribution"] as? [String: Any] {
                receiveAttribution(attribution)
            }
        }
        let served = (answer?["deepLink"] as? [String: Any]).map { Links.deepLink(from: $0, openedURL: url) }
        if let url {
            if served == nil {
                log(.info, "Delivering the locally parsed link for \(url.absoluteString).")
            }
            deliver(.found(served ?? Links.localLink(for: url, domains: linkDomains)))
        } else if let served {
            answerDeferred(.found(served))
        } else {
            answerDeferred(answer != nil ? .notFound : .failed(Self.isRetryable(status) ? .network : .invalidResponse))
        }
        if isLaunch {
            launch = .finished
            pump()
        }
    }

    func post(
        _ path: String,
        _ body: [String: Any],
        attempt: Int = 1,
        completion: @escaping (_ status: Int, _ json: [String: Any]?, _ retryAfter: TimeInterval?) -> Void
    ) {
        guard let config = configuration, JSONSerialization.isValidJSONObject(body),
              let payload = try? JSONSerialization.data(withJSONObject: body) else {
            log(.error, "Could not encode the POST /\(path) body.")
            return completion(400, nil, nil)
        }
        var request = URLRequest(url: config.apiBaseURL.appendingPathComponent(path), timeoutInterval: config.requestTimeout)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("Bearer \(config.publishableKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ios/\(Appy.sdkVersion)", forHTTPHeaderField: "X-Appy-SDK")
        transport.send(request) { [weak self] data, response, error in
            self?.queue.async {
                self?.finishRequest(path, body, attempt, data, response as? HTTPURLResponse, error, completion)
            }
        }
    }

    private func finishRequest(
        _ path: String,
        _ body: [String: Any],
        _ attempt: Int,
        _ data: Data?,
        _ response: HTTPURLResponse?,
        _ error: Error?,
        _ completion: @escaping (Int, [String: Any]?, TimeInterval?) -> Void
    ) {
        let status = response?.statusCode ?? 0
        let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let retryAfter = response?.value(forHTTPHeaderField: "Retry-After")
            .flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
            .flatMap { $0 >= 0 ? $0 : nil }
        if !(200...299).contains(status) {
            let details = json?["error"] as? [String: Any]
            let reason = status == 0
                ? error?.localizedDescription ?? "no response"
                : "HTTP \(status) \(details?["code"] as? String ?? ""): \(details?["message"] as? String ?? "")"
            log(status == 0 ? .warning : .error, "POST /\(path) failed: \(reason)")
        }
        guard Self.isRetryable(status), attempt < Self.maximumAttempts, (retryAfter ?? 0) <= Self.maximumInlineRetryAfter else {
            return completion(status, json, retryAfter)
        }
        let delay = max(retryAfter ?? 0, pow(2, Double(attempt - 1)) * Double.random(in: 1...1.1))
        log(.info, "Retrying POST /\(path) in \(String(format: "%.1f", delay)) s.")
        after(delay) { [weak self] in
            self?.post(path, body, attempt: attempt + 1, completion: completion)
        }
    }
}
