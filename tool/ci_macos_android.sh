#!/usr/bin/env bash
# Run only on a disposable GitHub macOS runner; output belongs in encrypted logs.
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_ENVIRONMENT:-} == github-hosted ]]
[[ $(uname -s) == Darwin ]]
umask 077
cd "$(dirname "$0")/.."
tools="$HOME/.local/share/silique-toolchains"
signing="$HOME/.local/share/silique-signing"
mkdir -p "$tools/jdk17/Contents" "$signing"
ln -s "${FLUTTER_ROOT:?}" "$tools/flutter"
ln -s "${ANDROID_HOME:?}" "$tools/android-sdk"
ln -s "${JAVA_HOME:?}" "$tools/jdk17/Contents/Home"
python3 - <<'PY'
import base64, os
from pathlib import Path
root = Path.home() / '.local/share/silique-signing'
for name, variable in [('publisher.p12', 'SILIQUE_MACOS_P12'),
                       ('macos-preview.crt', 'SILIQUE_MACOS_CERT')]:
    (root / name).write_bytes(base64.b64decode(os.environ[variable], validate=True))
(root / 'macos-preview.password').write_text(os.environ['SILIQUE_MACOS_PASSWORD'])
Path('android/app/silique-release.jks').write_bytes(base64.b64decode(os.environ['ANDROID_KEYSTORE_BASE64'], validate=True))
Path('android/key.properties').write_text('storeFile=silique-release.jks\nkeyAlias=nova-notes\n'
    + 'storePassword=' + os.environ['ANDROID_STORE_PASSWORD'].strip() + '\n'
    + 'keyPassword=' + os.environ['ANDROID_KEY_PASSWORD'].strip() + '\n')
PY
cleanup() {
  security lock-keychain "$signing/macos-preview.keychain-db" >/dev/null 2>&1 || true
  rm -f android/key.properties android/app/silique-release.jks
  rm -rf "$signing"
}
trap cleanup EXIT
security create-keychain -p "$SILIQUE_MACOS_PASSWORD" "$signing/macos-preview.keychain-db"
security set-keychain-settings -lut 21600 "$signing/macos-preview.keychain-db"
security unlock-keychain -p "$SILIQUE_MACOS_PASSWORD" "$signing/macos-preview.keychain-db"
security import "$signing/publisher.p12" -k "$signing/macos-preview.keychain-db" -P "$SILIQUE_MACOS_P12_PASSWORD" -T /usr/bin/codesign
rm -f "$signing/publisher.p12"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$SILIQUE_MACOS_PASSWORD" "$signing/macos-preview.keychain-db" >/dev/null
security list-keychains -d user -s "$signing/macos-preview.keychain-db" "$HOME/Library/Keychains/login.keychain-db"
security find-identity -p codesigning "$signing/macos-preview.keychain-db"
fingerprint="$(openssl x509 -in "$signing/macos-preview.crt" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d :)"
cp /usr/bin/true "$RUNNER_TEMP/silique-signing-probe"
codesign --force --sign "$fingerprint" --keychain "$signing/macos-preview.keychain-db" --timestamp=none "$RUNNER_TEMP/silique-signing-probe"
codesign --verify --strict "$RUNNER_TEMP/silique-signing-probe"
# Portable release contracts only; GTK4 dependency harness requires Linux/ELF.
for suite in test_macos_dmg.py test_prepare_update.py test_publish_update.py test_hermes_collect.py test_branding_compatibility.py; do
  python3 -m unittest discover -s tool -p "$suite" -v
done
# Exercise native packaging tools before the slow app build. This is the
# immutable historical ZIP, not a new ZIP artifact or an owner installation.
preflight="$(mktemp -d "$RUNNER_TEMP/macos-dmg-preflight.XXXXXX")"
curl --fail --location --proto '=https' --tlsv1.2 https://github.com/Haniewicz/silique-releases/releases/download/v0.2.29/Silique-0.2.29-macOS.zip -o "$preflight/previous.zip"
printf '%s  %s\n' cf5bdf69cc45f9cf5e36068c578a17932af03ff3a16c4a51c98d070b2b1b6285 "$preflight/previous.zip" | shasum -a 256 -c -
ditto -x -k "$preflight/previous.zip" "$preflight/input"
python3 tool/macos_dmg.py build --app "$preflight/input/Silique.app" --image "$preflight/preflight.dmg" --version 0.2.29 --build 38
rm -rf "$preflight"
flutter pub get
flutter analyze
# Server integration tests are run separately against a disposable API on Hermes.
flutter test --reporter expanded
flutter test integration_test/desktop_polish_ux_owner_test.dart -d macos --dart-define=SILIQUE_ISOLATED_TEST=true
flutter test integration_test/macos_keychain_scope_owner_test.dart -d macos --dart-define=SILIQUE_ISOLATED_TEST=true
# Native fixtures have a different entry point; never package their executable.
flutter clean
flutter pub get
flutter build macos --release --target=lib/main.dart
python3 tool/sign_macos.py build/macos/Build/Products/Release/Silique.app macos/Runner/Release.entitlements
mkdir -p packages/macos-android
python3 tool/macos_dmg.py build --app build/macos/Build/Products/Release/Silique.app --image packages/macos-android/Silique-macOS.dmg
python3 tool/macos_dmg.py verify --image packages/macos-android/Silique-macOS.dmg
flutter build apk --release
cp build/app/outputs/flutter-apk/app-release.apk packages/macos-android/Silique.apk
apksigner="$(find "$ANDROID_HOME/build-tools" -name apksigner -type f | sort | tail -1)"
"$apksigner" verify --verbose --print-certs packages/macos-android/Silique.apk
python3 - <<'PROVENANCE'
import json, os
from pathlib import Path
Path('packages/macos-android/build-provenance.json').write_text(json.dumps({
    'source_commit': os.environ['SOURCE_REF'], 'run_id': os.environ['GITHUB_RUN_ID']}))
PROVENANCE
shasum -a 256 packages/macos-android/Silique* > packages/macos-android/SHA256SUMS-macos-android.txt
