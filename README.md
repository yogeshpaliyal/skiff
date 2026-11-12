<p align="center"><img src="docs/brand/logo.svg" width="128" alt="Skiff"></p>

# Skiff — Send to TV

Send what you found on your phone to your Android TV / Google TV: share a page to Skiff, and it opens on the TV.

- **A title by name:** type it in the box ("panchayat") and pick it from the results (Cinemeta's search), then
  **Play**.
- **An IMDb page** (from Chrome or the IMDb app) opens in [Nuvio](https://github.com/NuvioMedia/NuvioTV): on that
  title's stream picker over USB debugging (for a series, pick the season and episode, then **Play**), or on its page
  when paired. Or in [Stremio](https://www.stremio.com), at the streams: pick it under **Open with**.
- **A Trakt, Simkl, Letterboxd, MDBList or WeTrakr page** (a movie, a show, or one episode of it) opens the same way:
  Skiff finds its IMDb id through that site (or, failing that, searches its name), and an episode's link goes straight
  to that episode.
- **A stream's link** (a video file or a live stream: `.m3u8`, `.mp4`, `.mkv`, `.mpd`, `rtsp://`…, pasted or shared)
  plays in the TV's video player, VLC first (or MX Player, Just Player, Kodi: pick it under **Open with**). Over USB
  debugging; over pairing the TV picks the app, which for a stream is often its browser.
- **Any other link** (JioHotstar, YouTube, Netflix, Prime Video, Stremio…) opens in the TV app that opens such links, when the TV has one. How each
  kind of link opens is set by [link rules](RULES.md): a fix there reaches the app without a new release.

No developer options needed: pair once with the code the TV shows, like the Google TV app.

Not affiliated with Nuvio or any streaming service.

![Skiff — Send to TV](docs/brand/banner.png)

## Remote

The remote button, beside **Play**, opens a remote for the TV: a D-pad with OK, Home, Back and Menu, a volume rocker,
playback, power, and **Type on the TV** (text straight into the TV's search box, instead of its on-screen keyboard).
Arrows, volume and seek repeat when held, and the phone's own volume buttons turn the TV's volume while it's open. A
**Quick Settings tile** (Skiff remote) opens it from anywhere.

**Cursor** (over USB debugging) swaps the D-pad for a touchpad and puts a mouse pointer on the TV, for apps that
don't follow the D-pad: drag to move it, tap to click, the strip at the edge scrolls. With **Air** on, turning the
phone, held like a remote, moves it (the gyroscope). The pointer is a USB mouse made up on the TV with Android's own
`hid` command (Android 9 and later); pairing's protocol has no pointer.

## History and Saved for later

Every title and link you share, paste or play goes to **History** (newest first, with its episode and when), and the bookmark
saves one **for later**. Tap one to load it, ▶ to play it on the TV; ⋮ edits it (name, movie or series, episode) or
removes it, and so does a swipe, with Undo. Kept on the phone (`files/library.json`).

## Two ways to reach the TV

| | Pairing | USB debugging |
|---|---|---|
| Setup on the TV | None: type the code it shows, once | Developer options → USB debugging, then allow the phone |
| Remote and typing | Yes | Yes |
| Cursor (air mouse) | No | Yes |
| Shared links | Yes; the TV picks the app | Yes; you pick the app under **Open with** |
| IMDb titles in Nuvio | Opens the title's page | Straight to the stream picker, with the episode |
| IMDb titles in Stremio | The streams, with the episode | The streams, with the episode |
| ADB tools (Settings) | No | Run a command, install an APK |

Skiff uses USB debugging when the TV allows this phone, else pairing. Settings → Connection can fix either one per TV,
and Settings → Activity shows how each thing was sent.

**Pairing** is the Android TV Remote protocol (v2), the one the Google TV app speaks: pairing on port 6467 with a
6-character code, then keys, text and app links over TLS on 6466. The phone's certificate is made once in the Android
Keystore; the TV's is pinned at pairing ([atv/](app/src/main/java/dev/skiff/atv), after
[androidtvremote2](https://github.com/tronikos/androidtvremote2)).

## How it works

- **Finding the TV.** Google TVs announce themselves on the Wi-Fi (mDNS): `_androidtvremote2._tcp` gives the TV's
  name ("Living room TV"), `_adb._tcp` on port 5555 means network debugging is on. No address to type
  ([TvFinder.kt](app/src/main/java/dev/skiff/TvFinder.kt)).
- **Which Nuvio.** The TV says which apps open `nuvio://` (the Play Store and GitHub builds, forks that kept the
  scheme), plus those opening `stremio://` with Nuvio's activity class `com.nuvio.tv.MainActivity` (forks with their
  own scheme), and Stremio (the other apps opening `stremio://`). Pick one under **Open with**; titles open in its
  own activity. Paired, the TV doesn't list its apps: **Open with** offers Nuvio and Stremio.
- **The title.** The IMDb id (from the shared link, or typed) gives the name and whether it's a movie or a series,
  through [Cinemeta](https://v3-cinemeta.strem.io), the free catalog Stremio and Nuvio use
  ([Meta.kt](app/src/main/java/dev/skiff/Meta.kt)).
- **Opening it, paired.** Nuvio's own link, `nuvio://movie/tt…` or `nuvio://series/tt…`, sent as an app link: the
  title's page.
- **Opening it in Stremio.** Stremio's deep link to the streams, `stremio:///detail/movie/tt0120737/tt0120737` or
  `stremio:///detail/series/tt42127457/tt42127457:1:4` for an episode: as an app link when paired, to Stremio's
  activity over USB debugging.
- **Opening it, over USB debugging.** Straight to the streams, from these intent extras (the ones it writes to its
  own "Continue Watching" home-screen row). The phone sends them over the TV's ADB, with
  [dadb](https://github.com/mobile-dev-inc/dadb) ([TvLink.kt](app/src/main/java/dev/skiff/TvLink.kt)):

  ```
  am start -n com.nuvio.tv/.MainActivity -f 0x14000000 \
    --es contentId tt42127457 --es contentType series --es videoId tt42127457:1:4 \
    --ei season 1 --ei episode 4 --es launchMode stream --es name 'Agent Kim Reactivated'
  ```

  `launchMode=stream` with a `name` goes to the stream picker; without the name, Nuvio opens the title's page.
  For a movie, `contentType=movie` and `videoId` is just the IMDb id.

- **Other links.** The TV says which apps open the link (`cmd package query-activities`), without the ones that
  open any web page (browsers). The [link rules](RULES.md) can change the link for the TV app first (JioHotstar's
  TV app opens `hotstar://in/movies/…` but not `https://www.hotstar.com/in/movies/…`), order the apps, set how
  the app starts, and say where the title comes from ([Rules.kt](app/src/main/java/dev/skiff/Rules.kt),
  [Links.kt](app/src/main/java/dev/skiff/Links.kt)).

## Setup

1. Phone and TV on the same Wi-Fi. Open Skiff: the TV shows up under **Nearby TVs**; pick it.
2. **Connect to <your TV>**: tap **Show a code on the TV**, type the code. That's it.

For the stream picker and **Open with** (optional): on the TV, Settings → System → About → press *Android TV OS
build* 7 times; then Developer options → turn on **USB debugging**, and allow the phone when the TV asks (tick
*Always allow*). It stays on for this to work: anything you allowed on the TV can control it.

## Privacy

Skiff sends crash reports and errors (Firebase Crashlytics) and usage (Firebase Analytics): which screens and
features are used, whether opening a link, playing a title, connecting the remote, pairing, an ADB command or an APK
install worked, with how (pairing or USB debugging) and, for links, the site (youtube.com); and where something
failed, with the kind of error. Never titles, links, typed or searched text, or commands. **Settings → Privacy** turns both off. Titles' names and art come from Cinemeta; history stays on the phone.
Details: [PRIVACY.md](PRIVACY.md).

## Languages

English, Hindi, Spanish, Portuguese (Brazil), French and German, following the phone's language; on Android 13+,
Settings → Apps → Skiff → Language picks one for Skiff alone. A translation is one file,
`app/src/main/res/values-<language>/strings.xml`, with the names of [the English one](app/src/main/res/values/strings.xml):
corrections and new languages are welcome.

## Download

Get the APK from [Releases](../../releases/latest). Up to 1.2.0 the app was *Nuvio Remote* (`dev.nuvioremote`); Skiff
(`dev.skiff`) is a new app for Android, so uninstall the old one. Every release is signed with the same release key,
so a new version installs over the old one.

## Stats

Download counts, stars, forks and open issues are saved daily to the [`stats` branch](../../tree/stats) (CSV files and
a summary in its README) by the **Stats snapshot** workflow ([stats.yml](.github/workflows/stats.yml)). It reads
GitHub's own APIs only; nothing comes from the app. Totals add up every release file ever uploaded, so a re-uploaded
file doesn't lose its earlier downloads.

Repo views, clones and referrers are optional: GitHub keeps them for 14 days, and the workflow's own token can't read
them. To keep them, create a fine-grained token for this repository with **Administration: Read-only** and save it as
the `TRAFFIC_TOKEN` repository secret (Settings → Secrets and variables → Actions). Without it, the workflow skips
them and saves the rest.

## Build

```bash
./gradlew assembleGithubDebug
adb install app/build/outputs/apk/github/debug/app-github-debug.apk
```

Two flavors, the same app (`dev.skiff`): **github** (the APK on GitHub releases; updates from GitHub) and **play**
(the bundle for Google Play; updates through Play's in-app updates, as Play requires). `BuildConfig.STORE` says
which; what differs lives in `app/src/github` and `app/src/play`.

The debug build is **Skiff Debug** (`dev.skiff.debug`, an amber icon): it installs beside the release one. Release
builds are shrunk with R8 ([proguard-rules.pro](app/proguard-rules.pro)).

Kotlin, Jetpack Compose with Material 3 Expressive and Material You colors, minSdk 26.

The version is in [version.properties](version.properties). A release (`assembleRelease`, `bundleRelease`) is signed
when `KEYSTORE_FILE`, `KEYSTORE_PASSWORD` and `KEY_ALIAS` are set.

**Releasing:** Actions → Release → Run workflow, and pick patch, minor or major. The
[release workflow](.github/workflows/release.yml) raises the version, builds and signs the APK and app bundle with the
repo's secrets, and only then commits the new version to `main`, tags it (`v1.9.0`) and publishes the release.
