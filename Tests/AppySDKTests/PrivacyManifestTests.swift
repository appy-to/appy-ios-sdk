import XCTest
@testable import AppySDK

final class PrivacyManifestTests: XCTestCase {
    private func manifest() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func testDeclaresNoTracking() throws {
        let plist = try manifest()
        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual((plist["NSPrivacyTrackingDomains"] as? [String])?.isEmpty, true)
    }

    func testDeclaresWhatTheSDKSends() throws {
        let types = try XCTUnwrap(manifest()["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        let declared = Dictionary(uniqueKeysWithValues: types.compactMap { entry -> (String, [String: Any])? in
            guard let type = entry["NSPrivacyCollectedDataType"] as? String else { return nil }
            return (type, entry)
        })
        XCTAssertEqual(Set(declared.keys), [
            "NSPrivacyCollectedDataTypeDeviceID",
            "NSPrivacyCollectedDataTypeUserID",
            "NSPrivacyCollectedDataTypeProductInteraction",
            "NSPrivacyCollectedDataTypePurchaseHistory",
            "NSPrivacyCollectedDataTypeAdvertisingData",
            "NSPrivacyCollectedDataTypeOtherDataTypes"
        ])
        for (type, entry) in declared {
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeLinked"] as? Bool, true, type)
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool, false, type)
            let purposes = Set(entry["NSPrivacyCollectedDataTypePurposes"] as? [String] ?? [])
            XCTAssertTrue(purposes.contains("NSPrivacyCollectedDataTypePurposeAnalytics"), type)
            XCTAssertFalse(purposes.contains("NSPrivacyCollectedDataTypePurposeThirdPartyAdvertising"), type)
        }
    }

    func testDeclaresUserDefaultsForTheSDKsOwnSuite() throws {
        let apis = try XCTUnwrap(manifest()["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        XCTAssertEqual(apis.count, 1)
        XCTAssertEqual(apis.first?["NSPrivacyAccessedAPIType"] as? String, "NSPrivacyAccessedAPICategoryUserDefaults")
        XCTAssertEqual(apis.first?["NSPrivacyAccessedAPITypeReasons"] as? [String], ["CA92.1"])
    }

    func testOpenSendsOnlyTheDeclaredDeviceFields() throws {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.configure()
        harness.advance(0.5)
        let body = try XCTUnwrap(harness.opens.first)
        let device = try XCTUnwrap(body["device"] as? [String: Any])
        XCTAssertEqual(Set(device.keys), ["platform", "osVersion", "model", "locale"])
        XCTAssertEqual(Set(body.keys).subtracting(["url", "userId", "appleAdsToken"]), ["installId", "firstLaunch", "trackingEnabled", "device", "app", "sdkVersion"])
    }
}
