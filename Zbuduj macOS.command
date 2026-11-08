#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
SILIQUE_FLUTTER="$HOME/.local/share/silique-toolchains/flutter/bin/flutter"
if [[ ! -x "$SILIQUE_FLUTTER" ]]; then
  SILIQUE_FLUTTER="$(command -v flutter || true)"
fi
if [[ -z "$SILIQUE_FLUTTER" ]]; then
  echo 'Zainstaluj Flutter 3.47.7 i uruchom ten plik ponownie.'
  exit 1
fi
if ! xcodebuild -version >/dev/null 2>&1 && [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
xcodebuild -version
"$SILIQUE_FLUTTER" pub get
"$SILIQUE_FLUTTER" build macos --release
SILIQUE_MAC_APP='build/macos/Build/Products/Release/Silique.app'
# Incremental Flutter builds can update App.framework after Xcode seals the app.
# Pin the same local publisher on each build. macOS can still request access
# after an update because its legacy Keychain also checks the code hash.
python3 tool/sign_macos.py "$SILIQUE_MAC_APP" macos/Runner/Release.entitlements
mkdir -p packages
python3 tool/macos_dmg.py build --app "$SILIQUE_MAC_APP" --image packages/Silique-macOS.dmg --replace
shasum -a 256 packages/Silique-macOS.dmg > packages/Silique-macOS.dmg.sha256
python3 tool/install_macos.py
echo "Gotowe: $(pwd)/packages/Silique-macOS.dmg"
