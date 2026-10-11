# Deep links — the native half

The Dart half of deep linking is written, committed and verified: a uri is parsed by
`lib/apps/deep_links.dart` (pure, no Flutter import), mapped to a screen by `lib/ui/routes.dart`,
and read at both entrances by `lib/apps/khata_app.dart` — cold start through
`platformDispatcher.defaultRouteName`, warm start through `WidgetsBindingObserver.didPushRouteInformation`.
23 checks in `tool/ui_commands_verify.dart` cover that chain, including a real one they caught
(`?action=receive` was being dropped, so a "receive payment" notification opened a screen that did
nothing).

**None of it can work until the operating system knows to hand the uri to this app.** That is the
other half, it is entirely native, and it cannot be written into this repository because there is no
`flutter create` output here to patch: `android/` currently holds only `MainActivity.kt` and
`security/SecurityChannel.kt`, and `ios/` only `AppDelegate.swift` and
`security/SecurityChannel.swift`. This document is that half, as exact blocks to paste.

> **Do this after `flutter create --org com.khata --project-name khata_pro --platforms=android,ios .`
> (see `docs/PLATFORM_SETUP.md` §6, and the handover section of the README).** The command adds the
> manifest, the plist, the Gradle files and the Xcode project *around* the hand-written native files
> that are already here; it does not overwrite `lib/`.

---

## 1 · The grammar — what this app answers to

Two schemes reach the same parser:

| Form | Example | Needs a domain? | Where it comes from |
| --- | --- | --- | --- |
| custom scheme | `khatapro://party/019a1b2c-0000-7000-8000-0000000000aa` | **no** | any SMS, WhatsApp message, QR code, or another app |
| https app link | `https://<host>/party/019a…` | yes | a browser, or a chat client that strips unknown schemes |
| bare path | `/party/019a…` | — | what the engine hands a **running** app on Android |

The path table, exactly as `deep_links.dart` parses it (everything else returns `null`, and a `null`
leaves the user where they are — a link for another app must not open an error page):

| Path | Opens | Extra |
| --- | --- | --- |
| `/` · `/dashboard` · `/home` | Dashboard | |
| `/parties` | Party list | `?kind=2` opens the **supplier** list |
| `/party/<uuid>` | that party's ledger | `?action=receive` opens the receipt form once the row loads |
| `/bills` | Bill book (the worklist) | `?doc=<uuid>` opens that bill once |
| `/bill/<uuid>` | same as `/bills?doc=` | `?no=INV-0007` is carried for humans and ignored by routing |
| `/cash` | Cash book | |
| `/stock` | Stock book | |
| `/staff` | Staff book | |
| `/settings` | Settings | `?invite=<ticket>` starts the LAN pairing flow |
| `/join?t=<ticket>` | redirects to `/settings?invite=…` | the QR in the sync screen |

Two details the Dart side already handles and the native side must not undo:

* **`khatapro://party/<id>` puts `party` in `uri.host`, not in `pathSegments`.** The parser
  normalises that (`deep_links.dart:130`). A manifest that declares the data as
  `android:scheme="khatapro" android:host="party"` would be fighting it; declare the scheme only.
* **A wrapped url is unwrapped, at most twice** — `…/open?url=https%3A%2F%2F…` is what some
  forwarders emit. Nothing native is needed for this; it is mentioned so nobody "fixes" it in the
  manifest.

---

## 2 · Android — `android/app/src/main/AndroidManifest.xml`

Replace the template's single `<activity …>` element with this one. The two `intent-filter`s are
deliberately separate: the first needs no domain and always works, the second is the app-link form
and only verifies if `assetlinks.json` is served (see §4).

```xml
<activity
    android:name=".MainActivity"
    android:exported="true"
    android:launchMode="singleTop"
    android:taskAffinity=""
    android:excludeFromRecents="false"
    android:theme="@style/LaunchTheme"
    android:configChanges="orientation|keyboardHidden|keyboard|screenSize|smallestScreenSize|locale|layoutDirection|fontScale|screenLayout|density|uiMode"
    android:hardwareAccelerated="true"
    android:windowSoftInputMode="adjustResize">

    <!-- Flutter's own deep linking: this is what turns an incoming uri into
         `platformDispatcher.defaultRouteName` (cold start) and into
         `didPushRouteInformation` (warm start). Both are implemented in
         `lib/apps/khata_app.dart`. Set it explicitly rather than relying on the
         default, because "the default changed in some version" is not a thing to
         discover on a customer's phone. -->
    <meta-data
        android:name="flutter_deeplinking_enabled"
        android:value="true" />

    <!-- The launcher. Unchanged from the template. -->
    <intent-filter>
        <action android:name="android.intent.action.MAIN" />
        <category android:name="android.intent.category.LAUNCHER" />
    </intent-filter>

    <!-- 1 · Our own scheme. No server, no verification, works from any app that
previews sent a clickable link. This is the zero-cost path and the one to
standardise on for SMS/WhatsApp reminders. -->
    <intent-filter android:autoVerify="false">
        <action android:name="android.intent.action.VIEW" />
        <category android:name="android.intent.category.DEFAULT" />
        <category android:name="android.intent.category.BROWSABLE" />
        <!-- Declare the scheme with NO host: this app uses `khatapro://party/<id>`,
             where `party` arrives as the uri's host. -->
        <data android:scheme="khatapro" />
    </intent-filter>

    <!-- 2 · The https app link. Only add this if you actually serve the two files
     in §4 from this exact host, and change `khataLinkHost` in
     `lib/apps/deep_links.dart` to match. `autoVerify="true"` makes Android
     check the host at install time; without a valid assetlinks.json the link
     still opens — in the browser, which is exactly the bug this filter exists to
     prevent, so it fails *silently*. Verify it (§5). -->
    <intent-filter android:autoVerify="true">
        <action android:name="android.intent.action.VIEW" />
        <category android:name="android.intent.category.DEFAULT" />
        <category android:name="android.intent.category.BROWSABLE" />
        <data android:scheme="https" android:host="khatapro.app" />
    </intent-filter>
</activity>
```

**Why `launchMode="singleTop"`:** the app is a single-activity Flutter app. With the default
(`standard`) a link tapped from a notification while the app is in the background creates a
*second* `MainActivity`, and the user ends up with two ledgers stacked in the app switcher. With
`singleTop` the running activity receives the new intent and the warm-start path
(`didPushRouteInformation`) runs — which is the path this codebase implements.

**Why `android:taskAffinity=""`:** keeps the app out of the launcher's "recent tasks" grouping
tricks that some OEM launchers use to hand links to the wrong activity. It is optional; it is here
because the cost of being wrong is a link opening a blank task.

**Nothing else in the manifest changes.** `FLAG_SECURE`, the backup flags and the permissions live
in `docs/PLATFORM_SETUP.md` §1 — paste that `<application>` element as well, it is not repeated here.

### Testing on Android, without a store or a domain

```bash
# cold start: kill the app first, then:
adb shell am start -a android.intent.action.VIEW \
  -d "khatapro://party/019a1b2c-0000-7000-8000-0000000000aa" com.khata.pro

# warm start: leave the app open, run the same command again — it must route without a restart
adb shell am start -a android.intent.action.VIEW \
  -d "khatapro://party/019a1b2c-0000-7000-8000-0000000000aa?action=receive" com.khata.pro

# what the OS thinks it will do with a link (the first line is the answer):
adb shell pm get-app-links com.khata.pro
```

`✗` if the app does not appear in the chooser at all: the `intent-filter` is missing or the
`<activity>` block was pasted outside `<application>`.

---

## 3 · iOS — `ios/Runner/Info.plist`

Three keys. Paste them as siblings inside the top-level `<dict>`.

```xml
<!-- 1 · The custom scheme. Equivalent to Android's first intent-filter, and the one
     that works with no domain. -->
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleTypeRole</key>
        <string>Editor</string>
        <key>CFBundleURLName</key>
        <string>com.khata.pro</string>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>khatapro</string>
        </array>
    </dict>
</array>

<!-- 2 · Flutter's deep linking. Like the Android meta-data: this is what delivers the
     uri to `didPushRouteInformation`. Without it the app launches and ignores the
     link. -->
<key>FlutterDeepLinkingEnabled</key>
<true/>

<!-- 3 · Universal links need the associated-domains entitlement, which lives in the
     entitlements file, not here — see below. -->
```

`ios/Runner/Runner.entitlements` (the entitlements file `docs/PLATFORM_SETUP.md` §2 already
creates) gains one key:

```xml
<key>com.apple.developer.associated-domains</key>
<array>
    <string>applinks:khatapro.app</string>
</array>
```

Universal links also require the App ID to have the **Associated Domains** capability enabled in
the Apple Developer portal. With a **free** Apple ID (personal team) that capability is not
available — universal links need a paid account. The custom scheme above needs no capability and no
paid account, which is why it is the recommended path for this project.

### Testing on iOS

```bash
# The simulator, both start types behave the same way here:
xcrun simctl openurl booted "khatapro://party/019a1b2c-0000-7000-8000-0000000000aa"
xcrun simctl openurl booted "khatapro://party/019a1b2c-0000-7000-8000-0000000000aa?action=receive"

# Universal links must be tested on a *device* with a developer-signed build; the
# simulator does not fetch the association file.
```

---

## 4 · The two association files (only needed for the https form)

Both are plain static files. They exist for exactly one reason: to prove to Google and Apple that
`https://<host>/party/<uuid>` belongs to *your* signed app, so the OS opens the app instead of the
browser.

### `https://khatapro.app/.well-known/assetlinks.json`

```json
[
  {
    "relation": ["delegate_permission/common.handle_all_urls"],
    "target": {
      "namespace": "android_app",
      "package_name": "com.khata.pro",
      "sha256_cert_fingerprints": [
        "AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99"
      ]
    }
  }
]
```

(The digest above is a placeholder shape — 32 hex pairs, upper case, colon-separated. Replace it.)

```bash
# debug certificate (the one `flutter run` uses):
keytool -list -v -keystore ~/.android/debug.keystore \
        -alias androiddebugkey -storepass android -keypass android | grep SHA256

# your release key:
keytool -list -v -keystore ~/khata-upload.jks -alias upload | grep SHA256

# and, if Play App Signing is on, the *other* certificate:
#   Play Console → Release → Setup → App signing → "App signing key certificate"
#   Both fingerprints belong in the array (debug for testing, both for production),
#   because Play re-signs the APK with a key you never see.
```

### `https://khatapro.app/.well-known/apple-app-site-association`

No file extension, served over HTTPS, `Content-Type: application/json`, no redirects.

```json
{
  "applinks": {
    "details": [
      {
        "appIDs": ["TEAMID.com.khata.pro"],
        "components": [
          { "/": "/party/*", "comment": "a customer's ledger" },
          { "/": "/bills",  "comment": "the bill book" },
          { "/": "/bills*", "query": { "doc": "?*" } },
          { "/": "/join*" },
          { "/": "/parties*" },
          { "/": "/cash" },
          { "/": "/stock" },
          { "/": "/staff" },
          { "/": "/settings*" },
          { "/": "/", "comment": "the dashboard" }
        ]
      }
    ]
  }
}
```

`TEAMID` is the 10-character team id from your Apple Developer account. Older iOS (≤ 12) reads a
`"paths"` array instead of `"components"`; if you must support it, keep both keys — the extra one is
ignored by newer versions.

### Where to host them, for $0

* **You do not have to host anything.** The custom scheme (§2, §3) needs no domain, no file and no
  server. For this app that is enough: every link the app *sends* is built by `buildPartyLink` /
  `buildBillLink`, i.e. always `khatapro://`.
* If you want browser-clickable links as well, a **GitHub Pages** site on a repository you already
  own can serve `/.well-known/assetlinks.json` and `/.well-known/apple-app-site-association`
  for free. On Pages you cannot set headers, but both files are served as `application/json` by
  default for a `.json` name — and the AASA file must be named without an extension, which Pages
  cannot do; a Cloudflare-Worker-free workaround is to keep it at `/.well-known/apple-app-site-association`
  in the repo and let Pages serve it as an octet-stream, which iOS **rejects**. If universal links
  matter, use a static host that lets you set a content type (Netlify's free tier, or a
  Cloudflare Worker in front of Pages).
* **If you pick your own host, three places must agree**, and this is where a mismatch costs an
  afternoon: `khataLinkHost` in `lib/apps/deep_links.dart`, `android:host` in the manifest, and
  `applinks:` in the entitlements + the AASA path list.

---

## 5 · The on-device checklist

Run these in order; each one isolates one layer, and a failure tells you which layer it is.

| # | Check | How | If it fails |
| --- | --- | --- | --- |
| 1 | the OS sees the scheme | `adb shell pm query-activities -a android.intent.action.VIEW -d "khatapro://party/x"` lists `com.khata.pro/.MainActivity` | the intent-filter is missing/misplaced |
| 2 | cold start routes | force-stop the app, then `am start … /party/<real-uuid>` | `initialLocation` — check `_initialLocation()` in `khata_app.dart` |
| 3 | warm start routes | leave the app open, send the same intent | `didPushRouteInformation` — check the `WidgetsBindingObserver` mixin is still there |
| 4 | the action reaches the form | send `…?action=receive` | check §1's warning about the action riding in the *location* |
| 5 | an unknown party is explained | send `/party/019a1b2c-ffff-7000-8000-000000000000` (not in this book) | the router's `errorBuilder` should show "not in this khata", not a blank screen |
| 6 | app-link verification (only if you added filter 2) | `adb shell pm get-app-links com.khata.pro` → `verified` | `assetlinks.json`: wrong package, wrong fingerprint, or served with a redirect |
| 7 | the message round-trips | ledger screen → phone icon → share to yourself → tap the link | `reminders.dart` built it, so if it does not parse, the two halves of §1 disagree |

---

## 6 · What is deliberately not here

* **No deferred deep links** (a link that survives an install). That needs a server — the one thing
  this product cannot have.
* **No branch/Firebase Dynamic Links.** Same reason, and a paid dependency besides.
* **No QR deep links.** The LAN pairing flow already carries its ticket as a QR *body*, not a url;
  if you want `khatapro://join?t=…` in a QR, the parser already handles it and any free QR app will
  render it.
