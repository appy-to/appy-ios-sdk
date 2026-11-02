import Foundation

extension Appy {
    static let maximumQueuedEvents = 1000
    static let maximumBatchEvents = 100
    static let maximumBatchBytes = 256 * 1024

    public func track(_ name: String, properties: [String: Any] = [:], revenue: Decimal? = nil, currency: String? = nil, deduplicationId: String? = nil) {
        let timestamp = now()
        queue.async { self.record(name, properties, revenue, currency, deduplicationId, at: timestamp) }
    }

    func record(_ rawName: String, _ properties: [String: Any], _ revenue: Decimal?, _ currency: String?, _ deduplicationId: String?, at timestamp: Date) {
        guard trackingOn else {
            return log(.debug, "Tracking is disabled; event \"\(rawName)\" was not recorded.")
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...64).contains(name.unicodeScalars.count) else {
            return log(.error, "Event names must be 1-64 characters; \"\(rawName.prefix(64))\" was dropped.")
        }
        let customId = deduplicationId.flatMap { validDeduplicationId($0, event: name) }
        if let customId, events.contains(where: { $0["id"] as? String == customId }) {
            return log(.info, "Event \"\(name)\" with deduplicationId \(customId) is already queued; this one was dropped.")
        }
        var event: [String: Any] = [
            "id": customId ?? UUID().uuidString.lowercased(),
            "name": name,
            "timestamp": Links.timestamp(timestamp),
            "properties": sanitized(properties, event: name)
        ]
        event["userId"] = userIdValue
        if let revenue {
            let code = currency?.trimmingCharacters(in: .whitespaces).uppercased() ?? ""
            let isCurrency = code.unicodeScalars.count == 3 && code.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) }
            if revenue.isFinite, revenue.magnitude < 1_000_000_000_000, isCurrency {
                event["revenue"] = "\(revenue)"
                event["currency"] = code
            } else {
                log(.warning, "Event \"\(name)\": revenue needs a finite amount below 1e12 and a three-letter currency code; both were dropped.")
            }
        } else if currency != nil {
            log(.debug, "Event \"\(name)\": currency without revenue is ignored.")
        }
        events.append(event)
        if events.count > Self.maximumQueuedEvents {
            events.removeFirst(events.count - Self.maximumQueuedEvents)
            log(.warning, "The event queue is full; the oldest event was dropped.")
        }
        saveEvents()
        log(.debug, "Queued event \"\(name)\".")
        if events.count >= 20 {
            requestFlush()
        } else {
            scheduleDebouncedFlush()
        }
    }

    func validDeduplicationId(_ raw: String, event name: String) -> String? {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = id.unicodeScalars
        let problem: String
        if scalars.isEmpty {
            problem = "is empty"
        } else if scalars.count > 128 {
            problem = "has \(scalars.count) characters"
        } else if let character = scalars.first(where: { !(0x21...0x7E).contains($0.value) }) {
            problem = character == " " ? "contains a space" : "contains \(String(format: "U+%04X", character.value)), which is not printable ASCII"
        } else {
            return id
        }
        log(.error, "Event \"\(name)\": deduplicationId \(problem); it must be 1-128 printable ASCII characters without spaces. A generated ID was used.")
        return nil
    }

    func sanitized(_ properties: [String: Any], event name: String) -> [String: Any] {
        var kept: [String: Any] = [:]
        for (key, value) in properties.sorted(by: { $0.key < $1.key }) {
            guard (1...64).contains(key.unicodeScalars.count), let scalar = Self.jsonScalar(value) else {
                log(.debug, "Event \"\(name)\": property \"\(key.prefix(64))\" was dropped; keys have 1-64 characters, values are strings, finite numbers or booleans.")
                continue
            }
            guard kept.count < 50 else {
                log(.debug, "Event \"\(name)\": properties after the first 50 in key order were dropped.")
                break
            }
            kept[key] = scalar
        }
        return kept
    }

    static func jsonScalar(_ value: Any) -> Any? {
        if let string = value as? String {
            return String(string.unicodeScalars.prefix(512))
        }
        guard let number = value as? NSNumber, number.doubleValue.isFinite else { return nil }
        return number
    }

    func scheduleDebouncedFlush() {
        debounceGeneration += 1
        let generation = debounceGeneration
        after(2) { [weak self] in
            if self?.debounceGeneration == generation {
                self?.requestFlush()
            }
        }
    }

    func requestFlush() {
        flushWanted = true
        pump()
    }

    func flushBeforeSuspension(_ done: @escaping () -> Void) {
        suspensionWaiters.append(done)
        requestFlush()
    }

    func clearEvents() {
        events.removeAll()
        saveEvents()
        pump()
    }

    func pump() {
        guard !isSending else { return }
        if events.isEmpty {
            flushWanted = false
        }
        let canSend = flushWanted && configuration != nil && !isBackingOff
        if canSend && launch != .finished && launch != .skipped {
            return
        }
        guard canSend else {
            let waiters = suspensionWaiters
            suspensionWaiters.removeAll()
            return waiters.forEach { $0() }
        }
        var batch: [[String: Any]] = []
        var bytes = 128
        for event in events.prefix(Self.maximumBatchEvents) {
            let wire = Self.wireEvent(event)
            let size = (try? JSONSerialization.data(withJSONObject: wire).count) ?? 0
            if !batch.isEmpty, bytes + size > Self.maximumBatchBytes {
                break
            }
            batch.append(wire)
            bytes += size + 1
        }
        let ids = Set(batch.compactMap { $0["id"] as? String })
        isSending = true
        log(.debug, "Sending \(batch.count) event(s).")
        post("v1/sdk/events", ["installId": installId, "events": batch]) { [weak self] status, json, retryAfter in
            self?.finishBatch(ids, status: status, json: json, retryAfter: retryAfter)
        }
    }

    static func wireEvent(_ event: [String: Any]) -> [String: Any] {
        var wire = event
        let revenue = (event["revenue"] as? String).map { NSDecimalNumber(string: $0, locale: Locale(identifier: "en_US_POSIX")) }
        wire["revenue"] = revenue.flatMap { $0.doubleValue.isFinite ? $0 : nil }
        return wire
    }

    func finishBatch(_ ids: Set<String>, status: Int, json: [String: Any]?, retryAfter: TimeInterval?) {
        isSending = false
        let accepted = (200...299).contains(status)
        if accepted || ((400...499).contains(status) && status != 429) {
            events.removeAll { ids.contains($0["id"] as? String ?? "") }
            saveEvents()
            if accepted {
                failedFlushes = 0
                log(.info, "Sent \(ids.count) event(s).")
            } else {
                log(.error, "The server rejected \(ids.count) event(s) with HTTP \(status); they were dropped.")
            }
            for rejection in json?["rejected"] as? [[String: Any]] ?? [] {
                let event = rejection["id"] as? String ?? "#\(rejection["index"] as? Int ?? -1)"
                log(.warning, "Event \(event) was rejected: \(rejection["message"] as? String ?? "no reason given").")
            }
        } else {
            failedFlushes += 1
            isBackingOff = true
            let delay = max(retryAfter ?? 0, min(pow(2, Double(failedFlushes + 1)), 300))
            log(.warning, "\(events.count) event(s) stay queued; sending is retried in \(Int(delay)) s.")
            after(delay) { [weak self] in
                self?.isBackingOff = false
                self?.requestFlush()
            }
        }
        pump()
    }

    func loadEvents() {
        guard let file = eventsFile, let data = try? Data(contentsOf: file) else { return }
        let stored = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        events = stored?["events"] as? [[String: Any]] ?? []
        flushWanted = !events.isEmpty
        if !trackingOn {
            clearEvents()
        }
    }

    func saveEvents() {
        guard !isSaveScheduled else { return }
        isSaveScheduled = true
        queue.async {
            self.isSaveScheduled = false
            self.writeEvents()
        }
    }

    func writeEvents() {
        guard let file = eventsFile else { return }
        guard !events.isEmpty else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        do {
            var directory = file.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try directory.setResourceValues(values)
            }
            let data = try JSONSerialization.data(withJSONObject: ["version": 1, "events": events])
            try data.write(to: file, options: Platform.fileWritingOptions)
        } catch {
            log(.warning, "Could not save the event queue: \(error.localizedDescription)")
        }
    }
}
