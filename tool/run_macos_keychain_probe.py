"""Compile the pinned plugin and run real Keychain operations on macOS."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import urljoin, urlparse, unquote


def main():
    if sys.platform != "darwin":
        raise SystemExit("Requires native macOS")
    root = Path(__file__).resolve().parents[1]
    config = root / ".dart_tool/package_config.json"
    package = next(p for p in json.loads(config.read_text())["packages"]
                   if p["name"] == "flutter_secure_storage_darwin")
    source_root = Path(unquote(urlparse(urljoin(config.as_uri(), package["rootUri"])).path))
    source = (source_root / "darwin/flutter_secure_storage_darwin/Sources/"
              "flutter_secure_storage_darwin/FlutterSecureStorage.swift")
    with tempfile.TemporaryDirectory(prefix="silique-keychain-probe-", dir=os.environ.get("TMPDIR")) as directory:
        temp = Path(directory)
        shutil.copyfile(root / "test/native/macos_keychain_probe.swift", temp / "main.swift")
        executable = temp / "probe"
        subprocess.run(["xcrun", "swiftc", str(source), str(temp / "main.swift"),
                        "-o", str(executable)], check=True)
        subprocess.run([str(executable)], check=True)


if __name__ == "__main__":
    main()
