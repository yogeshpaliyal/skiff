# Skiff for iOS

The iPhone and iPad app: the same Skiff, in Swift and SwiftUI (iOS 17 and later). It talks to the same TVs the same
two ways, reads the same links, and uses the same [link rules](../RULES.md) (`app/src/main/assets/rules.json`, shared
with the Android app, and refreshed from `main` once a day).

## Install

Every [release](https://github.com/yogeshpaliyal/skiff/releases/latest) has `skiff-<version>.ipa` beside the APK. It's **unsigned** (Skiff isn't on
the App Store): install it with a sideloading app, which signs it with your Apple ID:

- [AltStore](https://altstore.io) or [SideStore](https://sidestore.io): add the .ipa from Files.
- [Sideloadly](https://sideloadly.io): from a Mac or PC, over USB.

With a free Apple ID the app has to be re-signed every 7 days (AltStore and SideStore do it in the background).

The first time, iOS asks to allow Skiff to **find devices on your local network**: allow it, or no TV is found (later:
Settings → Privacy & Security → Local Network → Skiff).

## What's the same, and what differs

| Android | iOS |
|---|---|
| Share a page to Skiff | Share sheet → **Skiff** (an extension that hands the page to the app) |
| Search a title, paste a link, IMDb / Trakt / Simkl / Letterboxd / MDBList / WeTrakr pages, any other link | Same |
| Pairing (the code on the TV, Android TV Remote protocol v2) | Same: the client certificate is made on the phone and kept in the Keychain |
| USB debugging (ADB over Wi-Fi, port 5555): Nuvio's stream picker, Open with, ADB tools | Same: Skiff speaks ADB itself (its key in the Keychain; the TV asks to allow it once) |
| Remote: D-pad, Home/Back/Menu, volume, playback, power, Type on the TV | Same |
| Cursor and Air (gyroscope) | Same |
| The phone's volume buttons turn the TV's volume | Same, while the remote is open (iOS has no API for the buttons: the phone's volume is watched and put back) |
| Quick Settings tile | Home screen quick action (long-press Skiff's icon → **Remote**), or open `skiff://remote` (Shortcuts, Back Tap) |
| History and Saved for later | Same (swipe to remove, long-press to edit) |
| Install an APK on the TV | Same: pick it in Files |
| Updates from GitHub, installed by Skiff | Settings → About says when there's a newer release and opens it; install the new .ipa as above |
| Crash reports and usage (Firebase) | None: the iOS app sends nothing |
| Translations | English for now ([roadmap](../docs/KMP-ROADMAP.md)) |
| Demo mode (store screenshots) | Not yet |

## Build

```bash
brew install xcodegen
cd ios
xcodegen            # makes Skiff.xcodeproj from project.yml
open Skiff.xcodeproj
```

Pick your team under Signing & Capabilities (for both **Skiff** and **SkiffShare**) to run it on a phone. The Xcode
project isn't in git: [project.yml](project.yml) is.

```
ios/
  project.yml       the project (XcodeGen)
  Skiff/Core/       titles, links, rules, sites, history, updates: plain Swift, no UI (what KMP will share)
  Skiff/TV/         the remote protocol (pairing, TLS, protobuf), ADB, finding TVs, the cursor
  Skiff/UI/         the screens (SwiftUI)
  Share/            the share extension
  SkiffTests/       the Android app's unit tests, in Swift
```

Each Swift file says which Kotlin file it mirrors: a change to one app's logic should go to the other's (until
[KMP](../docs/KMP-ROADMAP.md) makes it one).

## CI and releases

[ios.yml](../.github/workflows/ios.yml) runs on a Mac:

- on pull requests and `main` that touch `ios/` (or the link rules): builds, runs the tests on a simulator, and keeps
  the unsigned .ipa as the run's artifact for a week;
- after the [Release workflow](../.github/workflows/release.yml): builds the .ipa from the new tag and attaches it to
  the release. Actions → iOS → Run workflow with a tag (`v1.11.1`) does the same for an existing release.

### Signing (optional)

To publish a signed .ipa (installable without a sideloading app, on the devices in its profile), add these repository
secrets; without them the .ipa is unsigned.

| Secret | What |
|---|---|
| `IOS_CERTIFICATE_P12_BASE64` | An Apple Development or Distribution certificate with its private key, exported as .p12, base64 (`base64 -i cert.p12`) |
| `IOS_CERTIFICATE_PASSWORD` | The .p12's password |
| `IOS_PROVISIONING_PROFILE_BASE64` | A provisioning profile (ad hoc or development) for the app's bundle id, `dev.skiff`, base64 |
| `IOS_SHARE_PROVISIONING_PROFILE_BASE64` | One for the share extension, `dev.skiff.share`, base64 |

If those bundle ids aren't available to your Apple developer account, change `PRODUCT_BUNDLE_IDENTIFIER` for both
targets in [project.yml](project.yml) (the extension's must start with the app's).
