# Platform setup — what a release build needs

Deliverable 3 added code that only compiles with the Android SDK, Xcode and the
Flutter SDK in place. This is the complete list of what those files require. Nothing
here costs money; the Google Cloud project needed for Drive is free and stays free.

The three platform security files were authored without a toolchain in reach, so read
this as the build checklist for the first `flutter build`. The Dart policy they sit
under is verified in `tool/security_verify.dart` (54/54).

---

## 1 · Android

### `android/app/build.gradle.kts`

```kotlin
android {
    defaultConfig {
        // Keystore AES-GCM keys need API 23; StrongBox needs 28; the app targets 34+.
        minSdk = 23
        targetSdk = 34
    }
    // The SQLCipher binaries arrive through the sqlite3 build hooks (pubspec
    // `hooks: user_defines:`), so no NDK cross-compile is needed here.
}

dependencies {
    // BiometricPrompt. alpha05+ is the version with setAllowedAuthenticators;
    // 1.2.0-alpha05 or newer also lets you skip the deprecated
    // setDeviceCredentialAllowed. Check the Play policy for the current minimum
    // before a store release.
    implementation("androidx.biometric:biometric:1.2.0-alpha05")
    // A FragmentActivity, which BiometricPrompt requires — FlutterFragmentActivity
    // satisfies this.
    implementation("androidx.fragment:fragment-ktx:1.6.2")
}
```

### `MainActivity.kt` — must be a `FlutterFragmentActivity`

```kotlin
package com.khata.pro

import com.khata.pro.security.SecurityChannel
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Registers the `khata_pro/security` channel. Without this line the Dart
        // side sees MissingPluginException and the custody ladder steps down to
        // passphrase custody — correct, but not what you want on a phone that has
        // a keystore.
        SecurityChannel(this, flutterEngine.dartExecutor.binaryMessenger)
    }
}
```

`SecurityChannel` needs a `FragmentActivity`; passing anything else is a compile
error, which is the good kind.

### `AndroidManifest.xml`

```xml
<application
    android:allowBackup="false"
    android:dataExtractionRules="@xml/data_extraction_rules"
    android:fullBackupContent="false"
    android:icon="@mipmap/ic_launcher"
    android:label="Digi Khata"
    android:theme="@style/LaunchTheme">

    <!-- LAN sync. mDNS/DNS-SD needs these two; NEARBY_WIFI_DEVICES is NOT needed
         for discovery on Android 13+ (it is for Wi-Fi Direct scanning), and asking
         for it would put a scary permission prompt in front of a user who only
         wants to sync two phones. -->
    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
    <uses-permission android:name="android.permission.ACCESS_WIFI_STATE" />

    <!-- Notifications for reminders; POST_NOTIFICATIONS is runtime on 13+. -->
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />

    <!-- Biometrics. USE_BIOMETRIC is normal-level: no prompt. -->
    <uses-permission android:name="android.permission.USE_BIOMETRIC" />

    <!-- A `foregroundServiceType="dataSync"` service is only needed if you want a
         long upload to survive the app being backgrounded *while the user watches*.
         WorkManager's periodic worker (the default here) needs none of this. -->
</application>
```

Notes that matter:

* `allowBackup="false"` is deliberate: an encrypted database without its key in a
  Google cloud backup is either useless or a liability, and the keystore key never
  leaves the device. The app's own encrypted backup (Deliverable 3) is the answer.
* `FLAG_SECURE` on the main activity hides amounts in the recents thumbnail; turn it
  on in `MainActivity.onCreate` (`window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, …)`).
* Keystore keys are unusable until the device has been unlocked once since boot. That
  is why the sync worker reports "waiting for first unlock" instead of failing.

### Background sync (WorkManager)

`workmanager: ^0.10.10` is already in `pubspec.yaml`. Register one periodic worker
with `ExistingPeriodicWorkPolicy.keep`, a 15-minute minimum interval (the OS floor),
and network *unmetered* as a constraint if the user chooses "Wi-Fi only". The worker
only needs `KhataDb.open(...)`, which unlocks with the after-first-unlock key and asks
for nothing.

## 2 · iOS

### Entitlements — `ios/Runner/Runner.entitlements`

```xml
<key>com.apple.developer.icloud-container-identifiers</key>
<array><string>iCloud.$(CFBundleIdentifier)</string></array>
<key>com.apple.developer.icloud-services</key>
<array><string>CloudDocuments</string></array>
<key>com.apple.developer.ubiquity-container-identifiers</key>
<array><string>iCloud.$(CFBundleIdentifier)</string></array>

<!-- Keychain access for the custody keys. No keychain-sharing group is needed for
     a single app. -->
<key>keychain-access-groups</key>
<array><string>$(AppIdentifierPrefix)$(CFBundleIdentifier)</string></array>
```

The iCloud container must also be enabled in the Apple Developer portal for the
bundle id (free with any Apple ID / free provisioning profile for development).

### `ios/Runner/Info.plist`

```xml
<key>NSFaceIDUsageDescription</key>
<string>KhataPro uses Face ID to protect the export of your books. Day-to-day use and
background backup do not need it.</string>

<!-- LAN sync. iOS 14+ refuses local-network access without a purpose string, and
     the Bonjour service types must be declared or discovery silently finds nothing. -->
<key>NSLocalNetworkUsageDescription</key>
<string>KhataPro syncs directly with your other phone over your own Wi-Fi. Nothing is
sent to the internet.</string>
<key>NSBonjourServices</key>
<array><string>_khata-sync._tcp</string></array>

<!-- Background refresh for the nightly backup pass. -->
<key>UIBackgroundModes</key>
<array><string>fetch</string><string>processing</string></array>
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array><string>com.khata.pro.backup</string></array>

<key>NSUbiquitousContainers</key>
<dict>
  <key>iCloud.$(CFBundleIdentifier)</key>
  <dict>
    <key>NSUbiquitousContainerIsDocumentScopePublic</key><false/>
    <key>NSUbiquitousContainerName</key><string>KhataPro</string>
    <key>NSUbiquitousContainerSupportedFolderLevels</key><string>Any</string>
  </dict>
</dict>
```

### `AppDelegate.swift` — register the security channel

```swift
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let controller = window?.rootViewController as? FlutterViewController {
      let handler = SecurityChannel()
      let channel = FlutterMethodChannel(
        name: SecurityChannel.channelName,
        binaryMessenger: controller.binaryMessenger)
      channel.setMethodCallHandler { call, result in handler.handle(call, result: result) }
      security = handler            // stored property — see the shipped AppDelegate
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // Blur the snapshot when the app resigns active, so amounts do not appear in the
  // app switcher. (The Android equivalent is FLAG_SECURE.)
  override func applicationWillResignActive(_ application: UIApplication) {
    // attach a blur view here
  }
}
```

### Add `SecurityChannel.swift` to the Xcode target

A file that exists on disk but is not a member of the Runner target is not compiled,
and the symptom is identical to not having written it at all: `MissingPluginException`
on the Dart side and passphrase custody on a phone with a Secure Enclave. After
cloning, either open `ios/Runner.xcworkspace` and add `Runner/Security/SecurityChannel.swift`
to the Runner target (File ▸ Add Files), or drop it into the project with a Ruby
`xcodeproj` script in CI. `flutter run` does **not** add it for you.

The same trap applies to two other new files that are *not* part of the app target:

  * `lib/platform/icloud/icloud_plugin_container.dart` — Dart, compiled by Flutter
    normally, but only reachable once something constructs it (see `docs/SYNC.md` §7:
    the wiring from the sync screen into the backup layer is **not written yet**, so
    none of this runs on a device today);
  * `android/app/src/main/kotlin/com/khata/pro/MainActivity.kt` — picked up by Gradle
    automatically, no action needed. Listed here so the asymmetry is explicit.

### The Secure Enclave, specifically

The enclave holds **EC P-256 keys, not AES keys**, so the iOS wrapping path is ECIES
(`SecKeyCreateEncryptedData` with
`.eciesEncryptionCofactorVariableIVX963SHA256AESGCM`) rather than the Android
AES-GCM path. The Dart side therefore records
`ecies-p256-secure-enclave` in `key_material.wrap_algo` for iOS rows and splits no
tag, because an ECIES blob is self-contained. Both flavours are round-tripped in
`tool/security_verify.dart`.

`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` is what makes background sync
possible; the vault key uses `.biometryCurrentSet`, which invalidates it when Touch
ID / Face ID is re-enrolled. That is intentional and is tested.

## 3 · Google Drive (free, and it stays free)

1. Create a project at <https://console.cloud.google.com> (no billing account).
2. **APIs & Services → Library → Google Drive API → Enable.**
3. **OAuth consent screen:** External, publishing status *Testing* is enough for
   personal use; add your own Google account as a test user. No verification is
   required, because the app requests only `drive.file`.
4. **Credentials → Create OAuth client ID:**
   * **Android:** package name `com.khata.pro` + the SHA-1 of your signing key
     (`keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey
     -storepass android -keypass android` for a debug build; your release key's SHA-1
     for a release build). Add both.
   * **iOS:** bundle id `com.khata.pro` (add the App Store team id if prompted).
5. Put the ids where the app can read them — a build-time define is better than a
   file, because it keeps them out of git:

```bash
flutter run \
  --dart-define=GOOGLE_CLIENT_ID_IOS=1234-abc.apps.googleusercontent.com \
  --dart-define=GOOGLE_CLIENT_ID_ANDROID=1234-android.apps.googleusercontent.com
```

Then set `GoogleSignIn` up with **only** these scopes:

```dart
GoogleSignIn(scopes: const ['https://www.googleapis.com/auth/drive.file']);
```

That single scope is what makes the consent screen say *"See, edit, create and delete
only the specific Google Drive files you use with this app"*. Add `drive` or
`drive.readonly` and you lose that sentence, gain a verification review, and take on
liability for the user's whole Drive for no functional benefit — everything this app
does fits inside `drive.file` plus `appDataFolder`.

Nothing in the Drive path needs a server: the OAuth client is yours, the storage is
the user's, and there is no quota to buy.

## 4 · iCloud (free tier)

Add the iCloud container in Xcode (**Signing & Capabilities → iCloud → Cloud
Documents**), which writes the entitlements shown above. Files land in the user's own
iCloud under the app's container; the free 5 GB covers a ledger many times over
(packs are compressed SQLCipher snapshots plus op-log segments).

## 5 · LAN sync needs no configuration

No STUN, no TURN, no signalling server, no API key, no certificate. That is the point
of the design (`lib/sync/transport/webrtc_lan_transport.dart` uses
`iceServers: []`), and it is why two phones on the shop's Wi-Fi can sync with the
internet unplugged. The mDNS service type is `_khata-sync._tcp` and must be declared
on iOS (above); Android needs no declaration.

## 6 · Building here vs. building locally

**No APK or IPA is built in this workspace** — the deliverable is source, and the
workspace has a storage budget. Build locally:

```bash
cd khata_pro
flutter pub get                 # pulls SQLCipher binaries via the sqlite3 hooks
flutter analyze                 # should be clean apart from generated files
flutter test
flutter build apk --release --split-per-abi     # Android
flutter build ipa --release                     # iOS (needs macOS + Xcode)
```

Two expectations to set before the first build:

* **The Kotlin, Swift and Flutter-plugin files have never been compiled** (no SDKs in
  this environment). Expect ordinary first-compile friction — an import, a nullable,
  a renamed API — rather than design problems. The pure-Dart logic underneath them is
  verified: 54/54 for the custody policy, 133/133 for sync, and the whole of
  lib/ type-checks against the pinned plugin APIs (`tool/plugin_stubs/`).
* **`flutter analyze` will flag `lib/platform/security/method_channel_security_transport.dart`,
  `lib/platform/drive/http_client_transport.dart`,
  `lib/platform/icloud/icloud_plugin_container.dart`,
  `lib/sync/transport/webrtc_lan_transport.dart` and
  `lib/sync/transport/mdns_discovery.dart` only if a dependency is missing** — they are
  the five files that import Flutter or a plugin, and they are the reason the other
  ~20 files in those directories are testable with a bare Dart SDK.
