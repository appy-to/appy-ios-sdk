# Add Appy to your iOS app

Use Appy to open the right screen in **your existing iOS app** when someone taps one of your links. Requires iOS 13+ and Swift 5.9+.

## 1. Get the two values for your app

In the [Appy dashboard](https://appy.to), open **Apps & SDK → New app**, register your own app, and open its **SDK setup** card. Copy **Publishable key** and **Link domain**. If it is already registered, open that app instead of creating another one.

[Which dashboard fields do I fill in?](SETUP.md#1-add-your-app-in-the-dashboard)

In every snippet below:

- Replace `YOUR_PUBLISHABLE_KEY` with the **entire key** copied from the dashboard.
- Replace `your-app.appy.to` with the **Link domain** copied from the dashboard.
- Keep names such as `Appy`, `AppySDK` and the package imports. They name the library you are adding; your own app keeps its name and identifiers.

The hosted SDK features require an Enterprise plan. You do not need a secret API key or a `curl` registration request for these steps.

## 2. Add the library in Xcode

1. Choose **File → Add Package Dependencies…**.
2. Enter `https://github.com/appy-to/appy-ios-sdk.git`.
3. Select **Up to Next Major Version**, starting at `1.0.0`.
4. Add the **AppySDK** library to your app target. Keep this library name.

## 3. Connect your link domain to your app

In your app target's **Signing & Capabilities**, add **Associated Domains**. Add `applinks:` followed by the Link domain you copied. For the example domain, the entry would be `applinks:your-app.appy.to`.

If your app also uses a custom URL scheme, register **your own scheme** under **Info → URL Types**. [Full platform setup](README.md#2-enable-associated-domains).

## 4. Paste your values and handle incoming links

At the top of your Swift file, add `import AppySDK`. Call the following once when your app starts:

```swift
Appy.configure(AppyConfiguration(
    publishableKey: "YOUR_PUBLISHABLE_KEY",
    linkDomains: ["your-app.appy.to"]
))

Appy.shared.onDeepLink = { result in
    if case .found(let link) = result {
        // Use link.slug and link.parameters to choose a screen in your app.
    }
}
```

The comment inside the callback is where **your app's navigation code** goes; there is no required screen or app called Appy.

Finally, forward the URLs that iOS gives your app to the SDK. Use the example matching your project type: [SwiftUI, SceneDelegate or AppDelegate](README.md#5-pass-incoming-links-to-the-sdk).

## 5. Test a real link

Create a link for this dashboard app, install your app on a device, and tap the link from Notes or Messages. Check that the deep-link callback runs. A fresh-install test is a separate check for deferred linking; a match is not guaranteed on every platform.

For events, consent and troubleshooting, see the [full guide](README.md). If an example value is unclear, use [this replacement table](SETUP.md#2-know-which-values-to-replace).
