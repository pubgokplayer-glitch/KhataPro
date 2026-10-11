#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  tool/setup_native.sh — one-shot native project hardening.
#  Idempotent: safe to re-run after `flutter create --platforms=android,ios .`
#  Run from the repository root:  bash tool/setup_native.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "▶ KhataPro · native setup"

# ── 0 · Ensure the Flutter platform folders exist ───────────────────────────
if [ ! -d android ] || [ ! -d ios ]; then
  echo "  · scaffolding android/ + ios/ via flutter create"
  flutter create --platforms=android,ios --org pk.khatapro --project-name khata_pro .
fi

# ── 1 · Gradle: NDK, min/target SDK, 16 KB page size, jniLibs packaging ─────
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
fi

GPROPS=android/gradle.properties
[ -f "$GPROPS" ] && grep -q 'android.enable16kbPageSize' "$GPROPS" 2>/dev/null || \
  printf '\n# Play Console requirement (2026): 16 KB memory page alignment\nandroid.experimental.enable16kbPageSize=true\n' >> "$GPROPS"

# Generated plugin registrant uses WorkManager's reflection-free path.
[ -f android/app/src/main/AndroidManifest.xml ] && \
  grep -q 'android:allowBackup="false"' android/app/src/main/AndroidManifest.xml || \
  python3 - <<'PY'
import pathlib
p = pathlib.Path('android/app/src/main/AndroidManifest.xml')
s = p.read_text()
s = s.replace('<application', '<application\n        android:allowBackup="false"\n        android:fullBackupContent="false"\n        android:dataExtractionRules="@xml/data_extraction_rules"', 1)
p.write_text(s)
PY

# ── 2 · iOS: entitlements, plist keys, pods ─────────────────────────────────
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
inject = """	<key>NSLocalNetworkUsageDescription</key>
	<string>KhataPro syncs ledgers directly with your other devices on this Wi-Fi network. Nothing is sent to any server.</string>
	<key>NSBonjourServices</key>
	<array><string>_khata-sync._tcp</string><string>_khata-sync._udp</string></array>
	<key>NSCameraUsageDescription</key>
	<string>Scan a pairing QR code or photograph a receipt.</string>
	<key>NSUbiquitousContainers</key>
	<dict>
		<key>iCloud.$(CFBundleIdentifier)</key>
		<dict>
			<key>NSUbiquitousContainerIsDocumentScopePublic</key><false/>
			<key>NSUbiquitousContainerName</key><string>KhataPro</string>
			<key>NSUbiquitousContainerSupportedFolderLevels</key><string>Any</string>
		</dict>
	</dict>
"""
s = s.replace('</dict>\n</plist>', inject + '</dict>\n</plist>')
p.write_text(s)
PY

# ── 3 · Google Drive OAuth client IDs (BYOC: the *user* is the owner) ───────
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
