#!/usr/bin/env bash
set -euo pipefail

# Resolve the public tag in a new consumer, without using the monorepo checkout.
version="${1:-1.0.0}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Usage: $0 [version]" >&2; exit 64; }
consumer="$(mktemp -d "${TMPDIR:-/tmp}/appy-spm-consumer.XXXXXX")"
trap 'rm -rf "$consumer"' EXIT
mkdir -p "$consumer/Sources/AppySPMConsumer"
cat > "$consumer/Package.swift" <<EOF
// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "AppySPMConsumer",
    platforms: [.iOS(.v13), .macOS(.v10_15)],
    products: [.library(name: "AppySPMConsumer", targets: ["AppySPMConsumer"])],
    dependencies: [.package(url: "https://github.com/appy-to/appy-ios-sdk.git", exact: "$version")],
    targets: [.target(name: "AppySPMConsumer", dependencies: [.product(name: "AppySDK", package: "appy-ios-sdk")])]
)
EOF
cat > "$consumer/Sources/AppySPMConsumer/Consumer.swift" <<'EOF'
import AppySDK
public func configuration() -> AppyConfiguration {
    AppyConfiguration(publishableKey: "YOUR_PUBLISHABLE_KEY", linkDomains: ["your-app.appy.to"])
}
EOF
swift build --package-path "$consumer"
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
swift build --package-path "$consumer" --triple arm64-apple-ios13.0-simulator --sdk "$sdk"
manifest="$(find "$consumer/.build" -path '*.bundle/PrivacyInfo.xcprivacy' -print -quit)"
[[ -n "$manifest" ]] || { echo "The built SDK resource bundle is missing PrivacyInfo.xcprivacy." >&2; exit 1; }
echo "Privacy manifest included in built resource bundle."
echo "Public SPM $version resolved and compiled for macOS and the iOS simulator."
