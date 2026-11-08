#!/usr/bin/env bash
# Creates a separate SDK. Never patches an existing Flutter installation.
set -euo pipefail
app_root="$(cd "$(dirname "$0")/.." && pwd)"
: "${SILIQUE_GTK4_SDK:?Choose a new absolute directory for the GTK4 SDK}"
: "${SILIQUE_DEPOT_TOOLS:?Set the path to depot_tools pinned at the documented revision}"
[[ "$SILIQUE_GTK4_SDK" == /* && ! -e "$SILIQUE_GTK4_SDK" ]] || { echo 'SDK destination must be a new absolute directory.' >&2; exit 1; }
[[ "$(git -C "$SILIQUE_DEPOT_TOOLS" rev-parse HEAD)" == 1eb46f8b23b4c6b3caa2be8e05999b6d1f4d0253 ]] || { echo 'Unexpected depot_tools revision.' >&2; exit 1; }
export PATH="$SILIQUE_DEPOT_TOOLS:$PATH"
export DEPOT_TOOLS_UPDATE=0
git clone --depth 1 --single-branch --branch 3.47.7 https://github.com/flutter/flutter.git "$SILIQUE_GTK4_SDK"
cd "$SILIQUE_GTK4_SDK"
[[ "$(git rev-parse HEAD)" == abaf9c523780a608bd46686fd5e53740a07077f8 ]]
cat > .gclient <<'CONFIG'
solutions = [{"name": ".", "url": "https://github.com/flutter/flutter.git", "deps_file": "DEPS", "managed": False, "custom_deps": {}, "custom_vars": {"download_android_deps": False, "download_fuchsia_deps": False, "download_windows_deps": False, "download_emsdk": False}}]
CONFIG
gclient sync --no-history --shallow --jobs=4 -D
git apply --check "$app_root/tool/gtk4/flutter-3.47.7-gtk4.patch"
git apply --index "$app_root/tool/gtk4/flutter-3.47.7-gtk4.patch"
cd engine/src
./flutter/tools/gn --linux --linux-cpu=x64 --runtime-mode=release --no-goma --no-lto --no-default-linux-sysroot \
  --gn-args='angle_use_wayland=false angle_build_tests=false angle_enable_libdrm=false angle_enable_vulkan_validation_layers=false angle_enable_vulkan_api_dump_layer=false angle_vulkan_headers_dir="//flutter/third_party/vulkan-deps/vulkan-headers/src" angle_vulkan_loader_dir="//flutter/third_party/vulkan-deps/vulkan-loader/src" angle_vulkan_tools_dir="//flutter/third_party/vulkan-deps/vulkan-tools/src" angle_lunarg_vulkantools_dir="//flutter/third_party/vulkan-deps/lunarg-vulkantools/src" angle_vulkan_validation_layers_dir="//flutter/third_party/vulkan-deps/vulkan-validation-layers/src"'
/usr/bin/ninja -C out/linux_release_x64 -j4 \
  flutter/shell/platform/linux:flutter_linux_gtk4 \
  flutter/shell/platform/linux:publish_headers_linux \
  flutter/third_party/dart/runtime/bin:gen_snapshot \
  flutter/tools/const_finder flutter/tools/font_subset flutter/build/dart:dart_sdk \
  flutter/lib/snapshot:kernel_platform_files flutter/sky/packages
