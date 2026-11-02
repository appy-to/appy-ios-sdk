// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AppySDK",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15)
    ],
    products: [
        .library(name: "AppySDK", targets: ["AppySDK"])
    ],
    targets: [
        .target(
            name: "AppySDK",
            path: "Sources/AppySDK",
            resources: [.copy("Resources/PrivacyInfo.xcprivacy")]
        ),
        .testTarget(
            name: "AppySDKTests",
            dependencies: ["AppySDK"],
            path: "Tests/AppySDKTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
