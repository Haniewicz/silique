#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 ]]; then
  echo 'Build GTK4 packages on an isolated Linux x64 desktop.' >&2
  exit 1
fi
: "${SILIQUE_GTK4_SDK:?Set the absolute path to the patched Flutter 3.47.7 SDK}"
: "${SILIQUE_FEDORA_ROOTFS:?Set the Fedora 44 rootfs with rpm-build installed}"
engine_src="$SILIQUE_GTK4_SDK/engine/src"
engine_out="$engine_src/out/linux_release_x64"
# Artefakt silnika MUSI odpowiadać źródłom i patchowi. `git apply --reverse --check` w
# `silique linux-build` sprawdza tylko ŹRÓDŁA, więc bez tego kroku paczka może zawierać stary
# `libflutter_linux_gtk4.so` przy zielonej bramce integralności (pomiar 2026-11-07: build
# przeszedł tylko dlatego, że koordynator wcześniej ręcznie uruchomił `ninja`).
if [[ -f "$engine_out/build.ninja" ]]; then
  echo 'Rebuilding GTK4 engine incrementally (ninja)...'
  ( cd "$engine_out" && ninja libflutter_linux_gtk4.so )
fi
[[ -f "$engine_out/libflutter_linux_gtk4.so" ]] || { echo 'Build the GTK4 engine first.' >&2; exit 1; }
echo "Engine: $(sha256sum "$engine_out/libflutter_linux_gtk4.so" | cut -c1-16) ($(stat -c %y "$engine_out/libflutter_linux_gtk4.so" | cut -d. -f1))"
[[ ! -e packages/linux ]] || { echo 'Use a fresh packages/linux directory.' >&2; exit 1; }
flutter="$SILIQUE_GTK4_SDK/bin/flutter"
engine_options=(--local-engine-src-path="$engine_src" --local-engine=linux_release_x64 --local-engine-host=linux_release_x64)
build_options=(build linux --release --linux-dir=linux-gtk4 --linux-gtk=gtk4)
"$flutter" --disable-analytics
"$flutter" pub get
python3 tool/prepare_linux_gtk4.py
probe_runtime="$(mktemp -d /tmp/silique-gtk4-runtime-XXXXXXXX)"
probe_result="$probe_runtime/result.json"
trap 'rm -rf -- "$probe_runtime"' EXIT
"$flutter" "${engine_options[@]}" "${build_options[@]}" --target=tool/desktop_release_probe.dart \
  --dart-define=SILIQUE_ISOLATED_TEST=true --dart-define=SILIQUE_PROBE_GUI=true \
  --dart-define="SILIQUE_PROBE_RESULT=$probe_result"
bundle=build/linux-gtk4/x64/release/bundle
probe_hash="$(sha256sum "$bundle/lib/libapp.so" | cut -d ' ' -f1)"
XDG_RUNTIME_DIR="$probe_runtime" dbus-run-session -- xvfb-run -a -s '-screen 0 1920x1080x24' \
  python3 tool/run_linux_gtk4_probe.py "$bundle/silique" "$probe_result"
# Rebuild the production entrypoint; never package a probe binary.
"$flutter" "${engine_options[@]}" "${build_options[@]}" --target=lib/main.dart
production_hash="$(sha256sum "$bundle/lib/libapp.so" | cut -d ' ' -f1)"
[[ "$probe_hash" != "$production_hash" ]] || { echo 'Production build still contains the probe entrypoint.' >&2; exit 1; }
python3 tool/package_linux_gtk4.py --bundle "$bundle" --probe-result "$probe_result" \
  --engine-source "$SILIQUE_GTK4_SDK" --fedora-rootfs "$SILIQUE_FEDORA_ROOTFS" \
  --proot "${SILIQUE_PROOT:-proot}" --out packages/linux
