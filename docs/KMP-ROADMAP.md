# Kotlin Multiplatform roadmap

Skiff has two apps today: Android (Kotlin, `app/`) and iOS (Swift, `ios/`). The iOS app is a direct port, file for
file, so that moving to **Kotlin Multiplatform** is a matter of deleting Swift, not redesigning anything. This is the
plan for getting there, one step at a time, each one shippable.

## Why not KMP from day one

- The Android app is a single module with Android types threaded through its logic (`Context`, `Uri`, `org.json`,
  `SharedPreferences`, `HttpURLConnection`, the Android Keystore). Making it multiplatform first would have meant
  rewriting the Android app before shipping anything on iOS, without a way to test it on iOS.
- The two parts that are hardest to share are platform code anyway: TLS with a client certificate (Keychain vs
  Android Keystore), finding TVs (Bonjour vs NSD), the gyroscope, the share sheet.
- A native iOS app now gives iPhone users Skiff now, and gives KMP a working reference to check against.

## What's shareable

| Layer | Android | iOS | Shareable |
|---|---|---|---|
| Titles, shares, IMDb ids | `Title.kt` | `Core/Title.swift` | Yes: pure logic |
| Cinemeta search and lookup | `Meta.kt` | `Core/Meta.swift` | Yes, with Ktor |
| Links, page titles (oEmbed, Open Graph, slug) | `Links.kt` | `Core/Links.swift` | Yes, with Ktor |
| Link rules | `Rules.kt` + `rules.json` | `Core/Rules.swift` + the same `rules.json` | Yes (the data already is) |
| Trakt, Simkl, Letterboxd, MDBList, WeTrakr | one file each | `Core/TitleSources.swift` | Yes |
| History and Saved | `Library.kt` | `Core/Library.swift` (same JSON fields) | Yes, with kotlinx.serialization and Okio |
| Activity log, connection choice | `ActivityLog.kt`, `Connection.kt` | `Core/ActivityLog.swift`, `Core/Connection.swift` | Yes, with multiplatform-settings |
| Update check | `Updates.kt` | `Core/Updates.swift` | The check, yes; installing stays per platform |
| Remote protocol messages, protobuf | `atv/Messages.kt`, `atv/Proto.kt` | `TV/Messages.swift`, `TV/Proto.swift` | Yes: bytes in, bytes out |
| Pairing secret, ADB key format, ADB transport | `atv/Atv.kt`, dadb | `TV/Atv.swift`, `TV/Adb.swift` | The protocol state machines yes; sockets and keys behind an interface |
| TLS socket with client certificate | `SSLSocket` + Android Keystore | `Network.framework` + Keychain | No: `expect`/`actual` |
| Finding TVs | `NsdManager` | `NetServiceBrowser` | No: `expect`/`actual` |
| Air cursor | `SensorManager` | Core Motion | The math (`AirCursor.step`) yes; the sensors no |
| Screens | Compose (Material 3 Expressive) | SwiftUI | Later, maybe: Compose Multiplatform |
| Strings | `res/values-*/strings.xml` (6 languages) | English | Yes: Compose Multiplatform resources, or moko-resources |

## The steps

1. **Done: native iOS app, mirrored structure.** Every Swift file names the Kotlin file it ports, the iOS unit tests
   are the Android ones, and both read the same `rules.json`. Rule of thumb until step 3: a logic change lands in
   both apps in the same pull request.

2. **A `shared` module, Android only.** Add `shared/` (`kotlin("multiplatform")`, `androidTarget()` only at first)
   and move the pure logic into `commonMain`: `Title`, `TitleSources` and the five sites, `Rules`, `Meta`, `Links`,
   `Library`, `ActivityLog`, `Connection`, `Updates.newer`, `atv/Proto`, `atv/Messages`. Replace `org.json` with
   kotlinx.serialization, `HttpURLConnection` with Ktor, `Uri` with a small parser, `SharedPreferences` with
   multiplatform-settings, `File` with Okio. The JVM unit tests move to `commonTest`. The Android app depends on
   `:shared` and ships unchanged. No iOS change yet.

3. **iOS uses `shared`.** Add `iosArm64()` and `iosSimulatorArm64()` targets, build an XCFramework (`Shared`) in CI,
   and link it from `ios/project.yml`. Delete `Skiff/Core/*.swift` and the message and protobuf code in
   `Skiff/TV/`, calling the shared Kotlin instead (SKIE makes the coroutines and sealed classes read naturally in
   Swift). The iOS tests become a smoke test of the bridge; the logic's tests are `commonTest`.

4. **The connections behind interfaces.** In `commonMain`: `TvSocket` (connect, read, write, close; TLS with a pinned
   peer), `KeyStore` (make and use an RSA key, a self-signed certificate), `TvDiscovery` (a flow of TVs). `actual`
   implementations: the current Android code, and the current Swift code exposed to Kotlin (or rewritten in Kotlin/
   Native over Network.framework and Security). Then pairing, the remote (`Atv.Remote`, its IME editing) and ADB
   (replacing dadb) live once, in `commonMain`, with `TvLink` on top.

5. **Screens: Compose Multiplatform (optional).** With the logic shared, the screens are what's left. Compose
   Multiplatform on iOS would make Skiff one codebase; SwiftUI keeps the iOS app feeling native. Decide then, screen
   by screen if need be (the remote's D-pad and the main screen are the candidates; the share extension and Settings
   stay native). Translations move to shared resources here, and iOS gets the six languages.

6. **One release.** Already the case: the Release workflow publishes the APK, the app bundle and the .ipa together,
   from one version (`version.properties`). With KMP, the iOS job also builds the `shared` framework.

## Keeping the two apps in step until then

- Same file and type names (`Title`, `Meta`, `Rules`, `TvLink`, `Atv`…), same comments, same behavior.
- Same data: `rules.json` is one file; the history JSON has the same fields on both.
- Same tests: a new Kotlin test gets its Swift twin in `ios/SkiffTests`.
