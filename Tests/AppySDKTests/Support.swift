import XCTest
@testable import AppySDK

enum Reply {
    case status(Int, String = "{}", headers: [String: String] = [:])
    case offline
}

final class MockTransport: AppyTransport {
    typealias Completion = (Data?, URLResponse?, Error?) -> Void

    private let lock = NSLock()
    private var calls: [(request: URLRequest, completion: Completion)] = []
    private var responder: (URLRequest) -> Reply? = MockTransport.defaultReply

    static func defaultReply(_ request: URLRequest) -> Reply? {
        if request.url?.path == "/v1/sdk/open" {
            return .status(200, #"{"installId":"i","firstLaunch":false,"deepLink":null,"attribution":null}"#)
        }
        return .status(202, #"{"accepted":1,"duplicates":0,"rejected":[]}"#)
    }

    func respond(_ responder: @escaping (URLRequest) -> Reply?) {
        lock.lock()
        self.responder = responder
        lock.unlock()
    }

    func respond(to path: String, with reply: @escaping () -> Reply?) {
        respond { request in request.url?.path == path ? reply() : MockTransport.defaultReply(request) }
    }

    func send(_ request: URLRequest, completion: @escaping Completion) {
        lock.lock()
        calls.append((request, completion))
        let reply = responder(request)
        lock.unlock()
        if let reply {
            Self.deliver(reply, for: request, to: completion)
        }
    }

    func requests(to path: String) -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return calls.map(\.request).filter { $0.url?.path == path }
    }

    func bodies(to path: String) -> [[String: Any]] {
        requests(to: path).map { (try? JSONSerialization.jsonObject(with: $0.httpBody ?? Data())) as? [String: Any] ?? [:] }
    }

    func complete(_ path: String, at index: Int, with reply: Reply) {
        lock.lock()
        let call = calls.filter { $0.request.url?.path == path }[index]
        lock.unlock()
        Self.deliver(reply, for: call.request, to: call.completion)
    }

    private static func deliver(_ reply: Reply, for request: URLRequest, to completion: Completion) {
        switch reply {
        case .offline:
            completion(nil, nil, URLError(.notConnectedToInternet))
        case let .status(code, body, headers):
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)
            completion(Data(body.utf8), response, nil)
        }
    }
}

final class ManualClock {
    private let lock = NSLock()
    private var elapsed: TimeInterval = 0
    private var order = 0
    private var pending: [(due: TimeInterval, order: Int, work: () -> Void)] = []
    private var requested: [TimeInterval] = []

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return Date(timeIntervalSince1970: 1_790_330_400 + elapsed)
    }

    var delays: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        lock.lock()
        pending.append((elapsed + delay, order, work))
        order += 1
        requested.append(delay)
        lock.unlock()
    }

    func advance(by interval: TimeInterval, running run: (@escaping () -> Void) -> Void) {
        let target = elapsed + interval
        while let next = takeNext(dueBy: target) {
            run(next)
        }
        lock.lock()
        elapsed = max(elapsed, target)
        lock.unlock()
    }

    private func takeNext(dueBy target: TimeInterval) -> (() -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = pending.indices.filter({ pending[$0].due <= target })
            .min(by: { (pending[$0].due, pending[$0].order) < (pending[$1].due, pending[$1].order) }) else {
            return nil
        }
        elapsed = max(elapsed, pending[index].due)
        return pending.remove(at: index).work
    }
}

final class LogRecorder {
    private let lock = NSLock()
    private var entries: [(level: AppyLogLevel, message: String)] = []

    func record(_ level: AppyLogLevel, _ message: String) {
        lock.lock()
        entries.append((level, message))
        lock.unlock()
    }

    func contains(_ fragment: String, at level: AppyLogLevel) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries.contains { $0.level == level && $0.message.contains(fragment) }
    }

    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries.map(\.message)
    }
}

enum Fixture {
    static let clickedAt = Date(timeIntervalSince1970: 1_790_330_645.25)

    static let deferred = """
    {"installId":"i","firstLaunch":true,\
    "deepLink":{"url":"https://acme.appy.to/spring?item=42","deeplinkUrl":"acme://items?item=42","slug":"spring",\
    "parameters":{"item":"42","utm_source":"instagram"},"isDeferred":true,"clickedAt":"2026-09-25T10:04:05.250Z"},\
    "attribution":{"status":"attributed","link":{"slug":"spring","title":"Spring campaign"},"source":"instagram",\
    "medium":"story","campaign":"spring_sale","clickedAt":"2026-09-25T10:04:05.250Z"}}
    """

    static let organic = """
    {"installId":"i","firstLaunch":true,"deepLink":null,\
    "attribution":{"status":"organic","link":null,"source":null,"medium":null,"campaign":null,"clickedAt":null}}
    """

    static let direct = """
    {"installId":"i","firstLaunch":false,"deepLink":{"url":"https://acme.appy.to/spring?item=42",\
    "deeplinkUrl":"acme://items?item=42","slug":"spring","parameters":{"item":"42"},"isDeferred":false,"clickedAt":null},\
    "attribution":null}
    """

    static let deferredLink = AppyDeepLink(
        url: URL(string: "https://acme.appy.to/spring?item=42"),
        deeplinkURL: URL(string: "acme://items?item=42"),
        slug: "spring",
        parameters: ["item": "42", "utm_source": "instagram"],
        isDeferred: true,
        clickedAt: clickedAt
    )

    static let directLink = AppyDeepLink(
        url: URL(string: "https://acme.appy.to/spring?item=42"),
        deeplinkURL: URL(string: "acme://items?item=42"),
        slug: "spring",
        parameters: ["item": "42"]
    )

    static let attributed = AppyAttribution(
        isOrganic: false,
        linkSlug: "spring",
        linkTitle: "Spring campaign",
        source: "instagram",
        medium: "story",
        campaign: "spring_sale",
        clickedAt: clickedAt
    )
}
