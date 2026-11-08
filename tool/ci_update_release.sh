#!/usr/bin/env bash
# Prepare signed metadata or publish one explicitly owner-approved artifact.
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_ENVIRONMENT:-} == github-hosted ]]
[[ $(uname -s) == Darwin ]]
umask 077
app_root="$(cd "$(dirname "$0")/.." && pwd)"
tools="$HOME/.local/share/silique-toolchains"
signing="$HOME/.local/share/silique-signing"
mkdir -p "$tools/sparkle-2.10.0" "$tools/jdk17/Contents" "$signing"
ln -s "${FLUTTER_ROOT:?}" "$tools/flutter"
ln -s "${ANDROID_HOME:?}" "$tools/android-sdk"
ln -s "${JAVA_HOME:?}" "$tools/jdk17/Contents/Home"
python3 - <<'PY'
import os
from pathlib import Path
key = Path.home() / '.local/share/silique-signing/updater-ed25519.key'
key.write_text(os.environ['SILIQUE_UPDATER_KEY'])
key.chmod(0o600)
PY
trap 'rm -f "$signing/updater-ed25519.key"' EXIT
curl --fail --location --proto '=https' --tlsv1.2 https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz -o "$RUNNER_TEMP/sparkle.tar.xz"
echo 'c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c  '"$RUNNER_TEMP/sparkle.tar.xz" | shasum -a 256 -c -
tar -xJf "$RUNNER_TEMP/sparkle.tar.xz" -C "$tools/sparkle-2.10.0"
cd "$app_root"
# Portable release contracts only; GTK4 dependency harness requires Linux/ELF.
for suite in test_macos_dmg.py test_prepare_update.py test_publish_update.py test_hermes_collect.py; do
  python3 -m unittest discover -s tool -p "$suite" -v
done
flutter pub get
case "${RELEASE_OPERATION:?}" in
  prepare)
    [[ ${CANDIDATE_TAG:-} =~ ^candidate-[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$ ]]
    mkdir "$RUNNER_TEMP/installers"
    gh release download "$CANDIDATE_TAG" --repo Haniewicz/silique-releases --dir "$RUNNER_TEMP/installers"
    gh release view "$CANDIDATE_TAG" --repo Haniewicz/silique-releases --json isDraft,body > "$RUNNER_TEMP/candidate.json"
    python3 - "$app_root" <<'PY'
import json, os, re, subprocess, sys
from pathlib import Path
root = Path(os.environ['RUNNER_TEMP'])
candidate = json.loads((root / 'candidate.json').read_text())
if candidate['isDraft'] is not True:
    raise ValueError('Preparation requires a private draft candidate')
version, build = re.search(r'^version: ([0-9.]+)\+([0-9]+)$', (Path(sys.argv[1]) / 'pubspec.yaml').read_text(), re.M).groups()
if os.environ['CANDIDATE_TAG'] != f'candidate-{version}-{build}':
    raise ValueError('Candidate and source versions differ')
(root / 'notes.txt').write_text(candidate['body'])
sys.path.insert(0, str(Path(sys.argv[1]) / 'tool'))
from prepare_update import ASSET_SUFFIXES
suffixes = ASSET_SUFFIXES
args = ['python3', 'tool/prepare_update.py', '--version', version, '--build', build,
        '--notes', str(root / 'notes.txt'), '--out', str(root / 'prepared')]
for platform, suffix in suffixes.items():
    path = root / 'installers' / f'Silique-{version}{suffix}'
    if not path.is_file():
        raise ValueError(f'Missing installer: {platform}')
    args.extend(['--' + platform, str(path)])
subprocess.run(args, check=True)
# The checksum-pinned Sparkle binary must really extract the prepared DMG;
# a fresh cache and exact extracted root metadata are asserted by this smoke.
subprocess.run(['python3', 'tool/smoke_sparkle_dmg.py',
    '--image', str(root / 'prepared' / f'Silique-{version}-macOS.dmg'),
    '--version', version, '--build', build], check=True)
PY
    ;;
  publish)
    [[ ${OWNER_APPROVED:-} == true && ${PREPARED_RUN:-} =~ ^[0-9]+$ ]]
    gh run view "$PREPARED_RUN" --repo Haniewicz/silique-releases --json workflowName,conclusion > "$RUNNER_TEMP/run.json"
    python3 - <<'PY'
import json, os
from pathlib import Path
run = json.loads((Path(os.environ['RUNNER_TEMP']) / 'run.json').read_text())
assert run == {'workflowName': 'Signed update preparation and approved publication', 'conclusion': 'success'}, 'Select a successful signing workflow'
PY
    gh run download "$PREPARED_RUN" --repo Haniewicz/silique-releases --name silique-prepared-update --dir "$RUNNER_TEMP/prepared"
    git config --global user.name 'Silique release automation'
    git config --global user.email '41898282+github-actions[bot]@users.noreply.github.com'
    gh auth setup-git
    python3 tool/publish_update.py --prepared "$RUNNER_TEMP/prepared" --repository "$GITHUB_WORKSPACE/distribution" --publish
    ;;
  *) exit 2 ;;
esac
