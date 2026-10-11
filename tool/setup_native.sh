#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  tool/setup_native.sh — one-shot native project hardening, including the
#  deep-link registration and the application id the Kotlin in this repo expects.
#
#  Run from the repository root:  bash tool/setup_native.sh
#  Idempotent: safe to re-run after `flutter create --platforms=android,ios .`
#  It patches; it never overwrites a file that already has the key it adds.
#
#  What it does, in order (docs/PLATFORM_SETUP.md and docs/DEEP_LINKS.md have
#  the reasoning and the on-device checklist):
#    0 · scaffold android/ + ios/ if they are missing
#    1 · Gradle: namespace + applicationId = com.khata.pro, NDK, SDK levels,
#        jniLibs, and the removal of the template's MainActivity
#    2 · AndroidManifest: no-backup flags, the two deep-link intent-filters and
#        flutter_deeplinking_enabled; plus the xml resource the manifest names
#    3 · iOS: entitlements, plist keys, the URL scheme, Flutter deep linking
#    4 · Drive OAuth placeholders (BYOC: the user owns the client id)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "▶ KhataPro · native setup"

# ── 0 · Ensure the Flutter platform folders exist ───────────────────────────
if [ ! -d android ] || [ ! -d ios ]; then
  echo "  · scaffolding android/ + ios/ via flutter create"
  flutter create --platforms=android,ios --org com.khata --project-name khata_pro .
fi

# ── 1 · Gradle: applicationId, NDK, min/target SDK, jniLibs packaging ───────
GRADLE=android/app/build.gradle.kts
if [ -f "$GRADLE" ]; then
  echo "  · patching $GRADLE"
  python3 - "$GRADLE" <<'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
def setkv(src, key, value):
    # replaces `key = ...` inside the android { } block, or appends via `kv(...)`
    if re.search(rf'^\s*{key}\s*=\s*', src, re.M):
        return re.sub(rf'^\s*{key}\s*=\s*.*$', f'    {key} = {value}', src, count=1, flags=re.M)
    return src

# The Kotlin in this repository lives in com.khata.pro (MainActivity.kt and
# security/SecurityChannel.kt) and the manifest names `.MainActivity`, which
# resolves against the *namespace*. `flutter create` derives the package from
# --org and --project-name, so unless both of these are pinned the app compiles
# and runs against the template's plain FlutterActivity -- no FragmentActivity,
# no khata_pro/security channel, and the custody ladder silently steps down to
# a passphrase. See docs/PLATFORM_SETUP.md §1.
s = setkv(s, 'namespace', '"com.khata.pro"')
s = setkv(s, 'applicationId', '"com.khata.pro"')
s = setkv(s, 'ndkVersion', '"27.2.12479018"')
if 'minSdk' not in s:
    s = s.replace('defaultConfig {', 'defaultConfig {\n        minSdk = 23', 1)
s = setkv(s, 'minSdk', '23')
s = setkv(s, 'targetSdk', '36')
if 'jniLibs' not in s:
    s = s.replace('buildTypes {', '''packaging {
        jniLibs {
            // Never extract the SQLCipher .so to /data — load it in place,
            // keeps the cipher binary out of world-readable app storage.
            useLegacyPackaging = false
        }
    }
    buildTypes {''', 1)
p.write_text(s)
PY

  # The template's MainActivity is a plain `FlutterActivity` in the org-derived
  # package. This repository ships its own — `FlutterFragmentActivity` with the
  # security channel — so the generated one is removed: two classes with the same
  # simple name is a coin flip decided by the namespace, and losing that flip is
  # silent.
  find android/app/src/main/kotlin -name 'MainActivity.kt' \
       -not -path '*/com/khata/pro/*' -delete 2>/dev/null || true
  find android/app/src/main/kotlin -depth -type d -empty -delete 2>/dev/null || true
fi

GPROPS=android/gradle.properties
# The property name is `android.experimental.enable16kbPageSize`, and the guard has to
# quote it in full: an earlier version of this line grepped for the name *without*
# `experimental.`, which never matched the line it had itself written, so every run
# appended another copy. Gradle tolerates the duplicate; the bug was invisible.
[ -f "$GPROPS" ] && grep -q 'android.experimental.enable16kbPageSize' "$GPROPS" 2>/dev/null || \
  printf '\n# Play Console requirement (2026): 16 KB memory page alignment\nandroid.experimental.enable16kbPageSize=true\n' >> "$GPROPS"

# ── 2 · AndroidManifest: backup flags, then the deep links ──────────────────
MANIFEST=android/app/src/main/AndroidManifest.xml
if [ -f "$MANIFEST" ]; then
  grep -q 'android:allowBackup="false"' "$MANIFEST" || python3 - <<'PY'
import pathlib
p = pathlib.Path('android/app/src/main/AndroidManifest.xml')
s = p.read_text()
s = s.replace('<application', '<application\n        android:allowBackup="false"\n        android:fullBackupContent="false"\n        android:dataExtractionRules="@xml/data_extraction_rules"', 1)
p.write_text(s)
PY

  # Deep links (docs/DEEP_LINKS.md). Written in the same style as the rest of this
  # script: idempotent, and only if the scheme is not already there.
  if ! grep -q 'android:scheme="khatapro"' "$MANIFEST"; then
    echo "  · injecting deep-link intent-filters into $MANIFEST"
    python3 - "$MANIFEST" <<'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()

filters = '''
        <!-- Deep links. `flutter_deeplinking_enabled` is what delivers the uri to
             Dart: platformDispatcher.defaultRouteName on a cold start, and
             didPushRouteInformation when the app is already running. Both are
             implemented in lib/apps/khata_app.dart, and both are checked. -->
        <meta-data
            android:name="flutter_deeplinking_enabled"
            android:value="true" />

        <!-- 1 · khatapro://… — no domain, no verification, works today. This is what
             an SMS/WhatsApp reminder carries. -->
        <intent-filter android:autoVerify="false">
            <action android:name="android.intent.action.VIEW" />
            <category android:name="android.intent.category.DEFAULT" />
            <category android:name="android.intent.category.BROWSABLE" />
            <!-- No host on purpose: `khatapro://party/<id>` arrives with `party` in
                 the uri's *host* slot. -->
            <data android:scheme="khatapro" />
        </intent-filter>

        <!-- 2 · https app links. Inert until the two association files in
             docs/DEEP_LINKS.md §4 are served from this exact host — a failing
             app-link verification opens the browser instead, which looks like
             nothing happened. -->
        <intent-filter android:autoVerify="true">
            <action android:name="android.intent.action.VIEW" />
            <category android:name="android.intent.category.DEFAULT" />
            <category android:name="android.intent.category.BROWSABLE" />
            <data android:scheme="https" android:host="khatapro.app" />
        </intent-filter>
'''

m = re.search(r'<activity\b[^>]*android:name="\.MainActivity".*?</activity>', s, re.S)
if m is None:
    raise SystemExit(
        '  ! AndroidManifest.xml has no `.MainActivity` <activity> element — '
        'paste the blocks from docs/DEEP_LINKS.md §2 by hand.'
    )
block = m.group(0)
head = block.split('>', 1)[0]
# A link tapped from a notification must reach the *running* activity instead of
# stacking a second one (which is what the default launchMode does).
if 'launchMode' not in head:
    block = block.replace('<activity', '<activity\n        android:launchMode="singleTop"', 1)
if 'flutter_deeplinking_enabled' not in block:
    block = block.replace('</activity>', filters + '    </activity>', 1)
s = s[:m.start()] + block + s[m.end():]
p.write_text(s)
PY
  fi

  # The manifest names @xml/data_extraction_rules; without the file, AAPT fails
  # the build with "resource xml/data_extraction_rules not found" — a one-line
  # reference, a whole compile.
  if [ ! -f android/app/src/main/res/xml/data_extraction_rules.xml ]; then
    mkdir -p android/app/src/main/res/xml
    cat > android/app/src/main/res/xml/data_extraction_rules.xml <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<!-- The books are encrypted with a key that never leaves the device, so a cloud
     copy of the database file is either useless or a liability. Nothing is
     extracted and nothing is transferred; the app's own encrypted backup is the
     answer (docs/SYNC.md). Android 12+ reads this file, older versions read
     android:fullBackupContent="false". -->
<data-extraction-rules>
    <cloud-backup>
        <exclude domain="root" />
        <exclude domain="file" />
        <exclude domain="database" />
        <exclude domain="sharedpref" />
        <exclude domain="external" />
    </cloud-backup>
    <device-transfer>
        <exclude domain="root" />
        <exclude domain="file" />
        <exclude domain="database" />
        <exclude domain="sharedpref" />
        <exclude domain="external" />
    </device-transfer>
</data-extraction-rules>
XML
  fi
fi

# ── 3 · iOS: entitlements, plist keys, deep links ───────────────────────────
mkdir -p ios/Runner
cat > ios/Runner/Runner.entitlements <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <!-- BYOC backup target: the user's own iCloud container. Free 5 GB quota. -->
  <key>com.apple.developer.icloud-container-identifiers</key>
  <array><string>iCloud.$(CFBundleIdentifier)</string></array>
  <key>com.apple.developer.icloud-services</key>
  <array><string>CloudDocuments</string></array>
  <key>com.apple.developer.ubiquity-container-identifiers</key>
  <array><string>iCloud.$(CFBundleIdentifier)</string></array>
  <!-- Local Network: LAN peer sync + mDNS discovery (no servers involved). -->
  <key>com.apple.developer.networking.multicast</key><true/>
  <!-- Universal links. Needs a *paid* Apple account (Associated Domains is not in
       the free personal team's capability list) and the apple-app-site-association
       file from docs/DEEP_LINKS.md §4. The custom scheme below needs neither, which
       is why it is the recommended path. Uncomment to enable:
  <key>com.apple.developer.associated-domains</key>
  <array><string>applinks:khatapro.app</string></array>
  -->
</dict>
</plist>
XML

PLIST=ios/Runner/Info.plist
[ -f "$PLIST" ] && grep -q 'NSLocalNetworkUsageDescription' "$PLIST" || python3 - <<'PY'
import pathlib
p = pathlib.Path('ios/Runner/Info.plist')
if not p.exists():
    raise SystemExit
s = p.read_text()
inject = """\t<key>NSLocalNetworkUsageDescription</key>
\t<string>KhataPro syncs ledgers directly with your other devices on this Wi-Fi network. Nothing is sent to any server.</string>
\t<key>NSBonjourServices</key>
\t<array><string>_khata-sync._tcp</string><string>_khata-sync._udp</string></array>
\t<key>NSCameraUsageDescription</key>
\t<string>Scan a pairing QR code or photograph a receipt.</string>
\t<key>NSUbiquitousContainers</key>
\t<dict>
\t\t<key>iCloud.$(CFBundleIdentifier)</key>
\t\t<dict>
\t\t\t<key>NSUbiquitousContainerIsDocumentScopePublic</key><false/>
\t\t\t<key>NSUbiquitousContainerName</key><string>KhataPro</string>
\t\t\t<key>NSUbiquitousContainerSupportedFolderLevels</key><string>Any</string>
\t\t</dict>
\t</dict>
"""
s = s.replace('</dict>\n</plist>', inject + '</dict>\n</plist>')
p.write_text(s)
PY

# The custom URL scheme + Flutter's own deep linking. Both are needed for a tapped
# reminder to reach the parser: the scheme so iOS opens *this* app, the flag so the
# engine hands the uri to didPushRouteInformation instead of ignoring it.
[ -f "$PLIST" ] && grep -q 'CFBundleURLSchemes' "$PLIST" || python3 - <<'PY'
import pathlib
p = pathlib.Path('ios/Runner/Info.plist')
if not p.exists():
    raise SystemExit
s = p.read_text()
if 'khatapro' in s:
    raise SystemExit
inject = """\t<key>CFBundleURLTypes</key>
\t<array>
\t\t<dict>
\t\t\t<key>CFBundleTypeRole</key><string>Editor</string>
\t\t\t<key>CFBundleURLName</key><string>com.khata.pro</string>
\t\t\t<key>CFBundleURLSchemes</key>
\t\t\t<array><string>khatapro</string></array>
\t\t</dict>
\t</array>
\t<key>FlutterDeepLinkingEnabled</key><true/>
"""
s = s.replace('</dict>\n</plist>', inject + '</dict>\n</plist>')
p.write_text(s)
PY

# ── 4 · Google Drive OAuth client IDs (BYOC: the *user* is the owner) ───────
if [ ! -f android/app/src/main/res/values/secrets.xml ]; then
  mkdir -p android/app/src/main/res/values
  cat > android/app/src/main/res/values/secrets.xml <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<!-- Placeholders. Replace with the SHA-1-bound OAuth client you create in your
     own Google Cloud console (free). No API keys of ours ever ship. -->
<resources>
  <string name="default_web_client_id">REPLACE_ME.apps.googleusercontent.com</string>
  <string name="khata_drive_app_folder">KhataPro/backups</string>
</resources>
XML
fi

echo "✔ native setup complete — open Xcode once to enable the iCloud capability."
echo "  Pocket check before you build (docs/DEEP_LINKS.md §5):"
echo "    adb shell am start -a android.intent.action.VIEW -d \"khatapro://party/<uuid>\" com.khata.pro"
