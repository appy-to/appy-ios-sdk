# Changelog

All notable changes to the Appy iOS SDK are documented in this file. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Release tags equal `Appy.sdkVersion`.

## [1.0.0] - Unreleased

First public release.

### Added

- `Appy.configure(_:)` with `AppyConfiguration`: publishable key, link domains, API base URL, log level, launch link wait interval, request timeout, `openDeferredDeepLinks` and `deferredDeepLinkTimeout`. Keys without the `appy_pk_` prefix are reported, keys are only ever logged by their first 12 characters, and repeated `configure` calls are ignored with an error log.
- Link handling through `handle(url:)` and `handle(userActivity:)`, covering Universal Links on the configured link domains and any URL carrying `appy_click_id`. Up to 10 links received before `configure` are resolved right after it.
- A launch window that merges the launch link and the session start into exactly one `POST /v1/sdk/open` per launch.
- First-launch reporting that is marked complete only after a 2xx JSON response, so the deferred deep link is requested again on the next launch after a failure. A launch with tracking disabled never counts as the first launch.
- `onDeepLink` with an `AppyDeepLinkResult`, called on the main thread: `.found(AppyDeepLink)`, `.notFound` or `.failed(AppyError)`. The first launch gets exactly one result; `.failed(.timeout)` is delivered when Appy has not answered within `deferredDeepLinkTimeout` (5 s by default), and a later answer does not call `onDeepLink` again. Every Appy link that opens the app is delivered as `.found`. A result that arrives before a handler is set is delivered once when one is set, and a pending link is never replaced by a later `.notFound` or `.failed`.
- `AppyDeepLink` with URL, destination URL, slug, parameters, deferred flag and click time, and a public initializer where every argument except `slug` has a default. `latestDeepLink` holds the most recent link.
- `AppyError` with `timeout` (no answer within `deferredDeepLinkTimeout`), `network` (no response, or HTTP 429 or 5xx through all retries) and `invalidResponse` (any other 4xx, or a 2xx body that cannot be decoded).
- `onAttribution` and the persisted `attribution` with an `AppyAttribution`: organic or attributed, the link's slug and title, `utm_source`, `utm_medium`, `utm_campaign` and click time. It is delivered once on the main thread when Appy answers the first launch, also after a deep link timeout, and to a handler set later during that launch.
- `openDeferredDeepLinks`, which opens a deferred link's `deeplinkURL` with `UIApplication.open` after `onDeepLink`, only for URL schemes the app registers under URL Types.
- A link parsed from the URL itself for handled URLs, delivered as `.found` when the server cannot be reached or returns no link.
- `emailLinkDomains` for email click-tracking domains that open the app. `handle` resolves their links with GET requests that do not follow redirects (at most 5, while they stay on those domains), then treats an Appy destination like any Appy link and delivers any other destination, or the tracking URL when it cannot be resolved, as `.found` with an empty slug. An email link in the launch window holds the launch open until it is resolved.
- Event tracking with `track(_:properties:revenue:currency:deduplicationId:)`:
  - validation of names, property types, key and value lengths, and revenue and currency;
  - an optional `deduplicationId`, such as a StoreKit transaction ID, sent as the event ID so a purchase tracked twice, or reported by both the app and your backend, counts once. It is trimmed and must be 1-128 printable ASCII characters without spaces; other values are logged as errors and the event keeps a generated ID. A call whose ID is still in the queue is dropped with an info log;
  - a persistent queue of up to 1,000 events, with coalesced writes;
  - batches of at most 100 events and 256 KB;
  - sending 2 seconds after the last event, at 20 queued events, in the background inside a background task, or on `flush()`, and never before the launch open has finished.
- Per-event rejections in 202 responses are logged as warnings. Rejected batches (4xx other than 429) are dropped with an error log.
- Retries for network errors, 429 and 5xx: three attempts with 1 and 2 second backoff, and `Retry-After` honored inline up to 10 seconds. Queued events are retried with backoff capped at 5 minutes.
- `setUserId(_:)`, persisted and limited to 128 characters, and a persisted `isTrackingEnabled` opt-out. The opt-out clears the queue, skips the launch open, and resolves explicit links without the user ID. Turning tracking back on before any open request was sent sends the skipped launch open.
- `link(slug:parameters:)` for share links with sorted, percent-encoded parameters.
- Apple Ads attribution: the first launch sends the AdServices attribution token (`appleAdsToken`, iOS 14.3 and newer). AdServices is loaded at run time, so apps targeting iOS 13 need no extra linking. Simulators and devices without AdServices send no token.
- `AppyAttribution.network` (`AppyAdNetwork`) when Google Ads or Meta attributed the install instead of an Appy link.
- Unified logging under subsystem `to.appy.sdk` with an `[Appy]` prefix and five log levels.
- A privacy manifest (`PrivacyInfo.xcprivacy`) declaring no tracking, the collected data types Device ID, User ID, Product Interaction, Purchase History, Advertising Data and Other Data Types, and `UserDefaults` with reason `CA92.1`. Opens send only platform, OS version, model identifier and locale as device data.
- Support for iOS 13 and later with no third-party dependencies. The source is 940 non-blank lines in 7 files, and the SDK adds about 161 KB of code and data to a stripped Release app. The package uses the Swift 5 language mode and can be used from Swift 6 apps.
