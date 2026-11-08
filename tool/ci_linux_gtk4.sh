#!/usr/bin/env bash
# Dedicated GTK4 builder for an ephemeral, standard GitHub-hosted Ubuntu runner.
# Compiler output must be redirected to the owner-encrypted workflow log.
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true && "${RUNNER_ENVIRONMENT:-}" == github-hosted ]]
[[ "$(uname -m)" == x86_64 ]]
: "${RUNNER_TEMP:?GitHub-hosted runner required}"
app_root="$(cd "$(dirname "$0")/.." && pwd)"
work="$RUNNER_TEMP/silique-linux-builder"
[[ ! -e "$work" ]]
mkdir -p "$work"
stage() { printf '%s\n' "$1" > "$work/stage"; }
stage dependencies
export TMPDIR="$work/tmp"
mkdir -m 700 "$TMPDIR"
export DEBIAN_FRONTEND=noninteractive
# These are disposable runner images, never the owner's workstation.
sudo rm -rf /usr/local/lib/android /opt/ghc /opt/hostedtoolcache /usr/share/dotnet
python3 -c 'import shutil; assert shutil.disk_usage(".").free >= 50*1024**3, "GTK4 engine build needs at least 50 GiB free"'
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  build-essential clang lld cmake ninja-build pkg-config git curl unzip ca-certificates \
  python3 python3-venv python3-pil libgtk-3-dev libgtk-4-dev libsecret-1-dev \
  libjsoncpp-dev libssl-dev libgl1-mesa-dev libegl1-mesa-dev libepoxy-dev \
  libx11-dev libxext-dev libxi-dev libxrandr-dev libxrender-dev libxcursor-dev \
  libxdamage-dev libxfixes-dev libxtst-dev libfontconfig1-dev libfreetype6-dev \
  libdbus-1-dev libdrm-dev libgbm-dev xvfb openbox scrot xdotool gnome-keyring \
  dbus-x11 patchelf dpkg-dev skopeo umoci libtalloc-dev zlib1g-dev
cd "$app_root"
stage pointer-regression
python3 tool/test_gtk4_pointer_position.py --report "$work/pointer-position.json"

git init "$work/depot_tools"
git -C "$work/depot_tools" remote add origin https://chromium.googlesource.com/chromium/tools/depot_tools.git
git -C "$work/depot_tools" fetch --depth 1 origin 1eb46f8b23b4c6b3caa2be8e05999b6d1f4d0253
git -C "$work/depot_tools" checkout --detach FETCH_HEAD
export SILIQUE_DEPOT_TOOLS="$work/depot_tools"
export SILIQUE_GTK4_SDK="$work/flutter-gtk4"
export DEPOT_TOOLS_UPDATE=0
stage engine-bootstrap
bash tool/bootstrap_linux_gtk4.sh

# Fedora's own RPM tooling resolves Fedora ABI requirements, not Ubuntu names.
stage fedora-rootfs
git init "$work/proot"
git -C "$work/proot" remote add origin https://github.com/proot-me/proot.git
git -C "$work/proot" fetch --depth 1 origin 25dc6a3134891f98a79f57ce1c2c1b23ff15cad1
git -C "$work/proot" checkout --detach FETCH_HEAD
make -C "$work/proot/src" -j4
export SILIQUE_PROOT="$work/proot/src/proot"
image='docker://registry.fedoraproject.org/fedora:44'
skopeo inspect "$image" > "$work/fedora-image.json"
digest="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["Digest"])' "$work/fedora-image.json")"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]
fedora_image="registry.fedoraproject.org/fedora@$digest"
image="docker://$fedora_image"
skopeo copy "$image" "oci:$work/fedora-oci:fedora44"
umoci unpack --rootless --image "$work/fedora-oci:fedora44" "$work/fedora-unpacked"
export SILIQUE_FEDORA_ROOTFS="$work/fedora-unpacked/rootfs"
# PRoot's simulated root cannot perform Fedora 44 DNF transactions reliably.
# Use a real container on this disposable runner, writing only the guest rootfs.
# PRoot remains unprivileged for rpmbuild and GUI/runtime compatibility tests.
mkdir -p "$work/fedora-packages"
docker pull "$fedora_image"
fedora_container=(docker run --rm \
  --mount "type=bind,source=$SILIQUE_FEDORA_ROOTFS,target=/target" \
  --mount "type=bind,source=$work/fedora-packages,target=/packages,readonly" \
  "$fedora_image")
"${fedora_container[@]}" /usr/bin/dnf --installroot=/target --releasever=44 \
  install -y rpm-build gtk4 libsecret libstdc++ glibc mesa-libGL mesa-libEGL libepoxy libX11 gnome-keyring dbus-daemon

stage application-tests
"$SILIQUE_GTK4_SDK/bin/flutter" pub get
"$SILIQUE_GTK4_SDK/bin/flutter" analyze
python3 tool/test_linux_native_dependencies.py
"$SILIQUE_GTK4_SDK/bin/flutter" test --reporter expanded
stage native-build-and-package
bash tool/build_linux_gtk4.sh
stage production-wheel-regression
python3 tool/check_linux_settings_scroll.py \
  --executable build/linux-gtk4/x64/release/bundle/silique \
  --report "$work/settings-scroll.json"
# Install and exercise the actual DEB on this disposable Ubuntu 24.04 runner.
stage installed-package-tests
sudo apt-get install -y "$app_root"/packages/linux/Silique-*-Linux-GTK4-amd64.deb
xvfb-run -a -s '-screen 0 1920x1080x24' dbus-run-session -- \
  python3 tool/check_linux_installed.py --report "$work/installed-ubuntu.json"
rpm_files=("$app_root"/packages/linux/Silique-*-Linux-GTK4-x86_64.rpm)
[[ ${#rpm_files[@]} == 1 && -f "${rpm_files[0]}" ]]
cp "${rpm_files[0]}" "$work/fedora-packages/"
# Exercise the exact local-RPM upgrade used by the updater, not only a fresh
# install. The previous public installer is pinned by its verified SHA256.
previous_rpm=Silique-0.2.6-Linux-GTK4-x86_64.rpm
curl --fail --location --proto '=https' --tlsv1.2 \
  "https://github.com/Haniewicz/silique-releases/releases/download/v0.2.6/$previous_rpm" \
  --output "$work/fedora-packages/$previous_rpm"
python3 -c 'import hashlib,sys; from pathlib import Path; assert hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest() == "896cb55a826fe2547f62d75b9792b8b6d8592f3cc1f82bf26280eb19aa5b8663"' \
  "$work/fedora-packages/$previous_rpm"
"${fedora_container[@]}" /usr/bin/dnf --installroot=/target --releasever=44 \
  install -y "/packages/$previous_rpm"
"${fedora_container[@]}" /usr/bin/dnf --installroot=/target --releasever=44 \
  upgrade -y "/packages/$(basename "${rpm_files[0]}")"
installed_rpm="$("${fedora_container[@]}" /usr/bin/rpm --root=/target -q \
  --queryformat '%{VERSION}-%{RELEASE}' silique)"
expected_rpm="$(python3 -c 'import re; from pathlib import Path; m=re.search(r"^version: ([0-9.]+)\+([0-9]+)$", Path("pubspec.yaml").read_text(), re.M); print(f"{m[1]}-{m[2]}.fc44")')"
[[ "$installed_rpm" == "$expected_rpm" ]]
printf 'Verified upgraded RPM version: %s\n' "$installed_rpm"
xvfb-run -a -s '-screen 0 1920x1080x24' dbus-run-session -- \
  python3 tool/check_linux_installed.py --fedora-rootfs "$SILIQUE_FEDORA_ROOTFS" \
  --proot "$SILIQUE_PROOT" --report "$work/installed-fedora.json"
mkdir -p packages/linux/verification
cp "$work/pointer-position.json" "$work/settings-scroll.json" \
  "$work/installed-ubuntu.json" "$work/installed-fedora.json" "$work/fedora-image.json" \
  packages/linux/verification/
stage complete
printf 'Linux GTK4 engine, application, native wheel regression and installed packages verified.\n'
