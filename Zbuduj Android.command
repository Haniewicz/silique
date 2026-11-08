#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
SILIQUE_TOOLS="$HOME/.local/share/silique-toolchains"
SILIQUE_FLUTTER="${SILIQUE_TOOLS}/flutter/bin/flutter"
if [[ ! -x "$SILIQUE_FLUTTER" ]]; then
  SILIQUE_FLUTTER="$(command -v flutter || true)"
fi
if [[ -z "$SILIQUE_FLUTTER" ]]; then
  echo 'Zainstaluj Flutter 3.47.7 i uruchom ten plik ponownie.'
  exit 1
fi
if [[ -d "${SILIQUE_TOOLS}/jdk17/Contents/Home" ]]; then
  export JAVA_HOME="${SILIQUE_TOOLS}/jdk17/Contents/Home"
fi
if [[ -d "${SILIQUE_TOOLS}/android-sdk" ]]; then
  export ANDROID_HOME="${SILIQUE_TOOLS}/android-sdk"
  export ANDROID_SDK_ROOT="$ANDROID_HOME"
fi
if [[ ! -f android/key.properties ]]; then
  echo 'Brakuje lokalnej konfiguracji podpisu android/key.properties. Zobacz docs/releases.md.'
  exit 1
fi
"$SILIQUE_FLUTTER" pub get
"$SILIQUE_FLUTTER" build apk --release
mkdir -p packages
cp build/app/outputs/flutter-apk/app-release.apk packages/Silique.apk
shasum -a 256 packages/Silique.apk > packages/Silique.apk.sha256
echo "Gotowe: $(pwd)/packages/Silique.apk"
