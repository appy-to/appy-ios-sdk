# iOS quickstart

Install the public Swift package from GitHub. The hosted SDK endpoints require an Appy Enterprise app.

## 1. Get your app values

Register your Apple Team ID and bundle ID in **Apps & SDK** in the Appy dashboard. Copy the publishable key and link domain. Use `appy_pk_…` in the app; secret keys belong on a server.

## 2. Install

Requires iOS 13+ and Swift 5.9+. In Xcode choose **File → Add Package Dependencies…**, enter `https://github.com/appy-to/appy-ios-sdk.git`, select version `1.0.0` or later within major version 1, and add **AppySDK** to the app target.

## 3. Enable links

In your target's **Signing & Capabilities**, add **Associated Domains** and `applinks:YOUR_SUBDOMAIN.appy.to`. Under **Info → URL Types**, add your app's custom scheme. Match these to the app registered in Appy.

## 4. Configure and receive links

Call once during app startup, replacing the example values:

```swift
import AppySDK

Appy.configure(AppyConfiguration(
    publishableKey: "appy_pk_REPLACE_WITH_YOUR_PUBLISHABLE_KEY",
    linkDomains: ["YOUR_SUBDOMAIN.appy.to"]
))

Appy.shared.onDeepLink = { result in
    if case .found(let link) = result {
        // Route using link.slug and link.parameters.
    }
}
```

Forward incoming URLs to `Appy.shared.handle(url:)`, including the URL in a Universal Link's `NSUserActivity`. Choose the forwarding example for your app lifecycle in [Pass incoming links to the SDK](README.md#5-pass-incoming-links-to-the-sdk).

## 5. Check the integration

On a device, tap a link from Notes or Messages with the app installed and verify the deep-link callback. Then test a fresh install through an Appy link for deferred delivery; a match is not guaranteed on every platform. Verify the install in the dashboard.

Keep debug logs off in production. Handle link parameters as untrusted input and select routes from an allowlist. See the [full guide](README.md) for events, consent, attribution and troubleshooting.
