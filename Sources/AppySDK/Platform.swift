import Foundation
import os.log
#if canImport(UIKit)
import UIKit
#endif

enum Platform {
    private static let osLog = OSLog(subsystem: "to.appy.sdk", category: "Appy")

    static let eventsFile = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("AppySDK/events.json")

    static var fileWritingOptions: Data.WritingOptions {
        #if os(iOS)
        return [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        return [.atomic]
        #endif
    }

    static let model: String = {
        #if targetEnvironment(simulator)
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        #endif
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }()

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: RedirectRefusal(), delegateQueue: nil)
    }

    static func log(_ level: AppyLogLevel, _ message: String) {
        let types: [AppyLogLevel: OSLogType] = [.error: .error, .warning: .default, .info: .info]
        os_log("%{public}@", log: osLog, type: types[level] ?? .debug, message)
    }

    static func deviceValues() -> [String: Any] {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let patch = version.patchVersion > 0 ? ".\(version.patchVersion)" : ""
        return [
            "platform": "ios",
            "osVersion": "\(version.majorVersion).\(version.minorVersion)\(patch)",
            "model": model,
            "locale": Locale.current.identifier
        ]
    }

    static func mainThreadDeviceValues() -> [String: Any] {
        #if canImport(UIKit) && os(iOS)
        return ["osVersion": UIDevice.current.systemVersion]
        #else
        return [:]
        #endif
    }

    static func openURL(_ url: URL) -> Bool {
        #if canImport(UIKit) && os(iOS)
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        guard let scheme = url.scheme, schemes.contains(where: { $0.caseInsensitiveCompare(scheme) == .orderedSame }) else {
            return false
        }
        UIApplication.shared.open(url)
        return true
        #else
        return false
        #endif
    }

    static func appleAdsToken() -> String? {
        #if os(iOS)
        guard #available(iOS 14.3, *) else { return nil }
        _ = dlopen("/System/Library/Frameworks/AdServices.framework/AdServices", RTLD_LAZY)
        guard let attribution: AnyClass = NSClassFromString("AAAttribution") else { return nil }
        let selector = NSSelectorFromString("attributionTokenWithError:")
        guard let method = class_getClassMethod(attribution, selector) else { return nil }
        typealias TokenFunction = @convention(c) (AnyClass, Selector, AutoreleasingUnsafeMutablePointer<NSError?>?) -> NSString?
        let token = unsafeBitCast(method_getImplementation(method), to: TokenFunction.self)
        var error: NSError?
        guard let value = token(attribution, selector, &error) as String?, !value.isEmpty else { return nil }
        return value
        #else
        return nil
        #endif
    }

    static func appValues() -> [String: Any] {
        var values: [String: Any] = [:]
        values["bundleId"] = Bundle.main.bundleIdentifier
        values["version"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        values["build"] = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return values
    }

    static func observeBackground(_ flush: @escaping (_ done: @escaping () -> Void) -> Void) {
        #if canImport(UIKit) && !os(watchOS)
        _ = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let application = notification.object as? UIApplication else { return }
            var task = UIBackgroundTaskIdentifier.invalid
            let end = {
                if task != .invalid {
                    application.endBackgroundTask(task)
                    task = .invalid
                }
            }
            task = application.beginBackgroundTask(withName: "to.appy.sdk.flush", expirationHandler: end)
            flush { DispatchQueue.main.async(execute: end) }
        }
        #endif
    }
}

final class RedirectRefusal: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
