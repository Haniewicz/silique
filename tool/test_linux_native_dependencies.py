#!/usr/bin/env python3
"""Dependency-level regression for the GTK4 runner: no JNI, no libdartjni.

The tests drive *real CMake* against the *real, pinned* upstream ``jni`` plugin
sources that Flutter resolves for Linux (through ``.dart_tool/package_config.json``),
mirroring the GTK4 runner's plugin-inclusion path. They are not text/regex checks:
the harness configures and builds the actual ``jni`` ``linux``/``src`` CMake
projects and inspects the produced artifacts.

Why this exists
---------------
``path_provider`` (a desktop dependency of this app, reached transitively through
``share_plus`` -> ``share_plus_platform_interface``) pulls ``path_provider_android``,
which depends on ``jni``. ``jni`` declares ``linux: ffiPlugin: true`` in its
pubspec, so Flutter adds it to ``FLUTTER_FFI_PLUGIN_LIST`` for Linux even though no
Linux code path uses Java. ``jni`` 1.1.0 builds its ``dartjni`` bridge only when
CMake finds a JVM, so a JDK that merely happens to be installed on the builder
silently produces ``libdartjni.so`` with a ``NEEDED libjvm.so`` and an absolute
RUNPATH. Linux GTK4 uses pure-Dart implementations (share_plus
``SharePlusLinuxPlugin``, ``path_provider_linux``, ``file_selector_linux``), so
that bridge is dead weight and makes the bundle depend on the builder's JDK.

Expected behaviour
------------------
RED  (policy absent): the real ``jni`` sources build ``libdartjni.so`` linked to
     ``libjvm.so`` whenever a JDK is present.
GREEN (policy present): the GTK4 runner's policy disables the optional JNI
     lookup, so the ``jni`` target is never created and no ``libdartjni.so``
     exists -- independently of the builder's JDK.

The policy is scoped to the GTK4 runner only; Android (Gradle), macOS and Windows
build trees are untouched.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
import tempfile
import unittest
import urllib.parse
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PACKAGE_CONFIG = REPO / ".dart_tool/package_config.json"
POLICY_FILE = REPO / "linux-gtk4/cmake/gtk4_native_policy.cmake"
GTK4_CMAKE = REPO / "linux-gtk4/CMakeLists.txt"
PLUGIN_INCLUDE = "include(flutter/gtk4_plugins.cmake)"

JNI_PACKAGE = "jni"
# Upstream release the plugin graph is pinned to in pubspec.lock. The CMake
# behaviour exercised below is validated against exactly this version.
JNI_VERSION = "1.1.0"

HARNESS = """\
cmake_minimum_required(VERSION 3.13)
project(silique_gtk4_native_dependency_harness LANGUAGES C CXX)
{policy}add_subdirectory("{jni_linux}" "${{CMAKE_BINARY_DIR}}/jni")
if(TARGET jni)
  message(STATUS "SILIQUE_JNI_TARGET=1")
else()
  message(STATUS "SILIQUE_JNI_TARGET=0")
endif()
"""


def _package_path(name: str) -> Path:
    """Resolve a package's source directory from .dart_tool/package_config.json."""
    if not PACKAGE_CONFIG.exists():
        raise RuntimeError(
            f"{PACKAGE_CONFIG} is missing; run `flutter pub get` in {REPO} first."
        )
    for item in json.loads(PACKAGE_CONFIG.read_text())["packages"]:
        if item["name"] != name:
            continue
        uri = item["rootUri"]
        if uri.startswith("file:"):
            return Path(urllib.parse.urlparse(uri).path)
        return (PACKAGE_CONFIG.parent / uri).resolve()
    raise RuntimeError(f"package {name!r} is not in {PACKAGE_CONFIG}")


def _jni_source() -> Path:
    """Real upstream `jni` source tree, pinned-version checked."""
    root = _package_path(JNI_PACKAGE)
    match = re.search(r'^version:\s*[\'"]?([^\s\'"]+)', (root / "pubspec.yaml").read_text(), re.M)
    version = match.group(1) if match else "?"
    if version != JNI_VERSION:
        raise RuntimeError(
            f"{JNI_PACKAGE} sources are {version}, expected the pinned {JNI_VERSION}; "
            "review the GTK4 native dependency policy for this release."
        )
    return root


def _run(cmd: list[str], cwd: Path | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)


def _build_harness(with_policy: bool) -> dict:
    """Configure + build real CMake against the real jni plugin sources."""
    jni_linux = _jni_source() / "linux"
    if not (jni_linux / "CMakeLists.txt").exists():
        raise RuntimeError(f"{jni_linux}/CMakeLists.txt not found")
    policy = ""
    if with_policy:
        policy = f'include("{POLICY_FILE}")\n'
    with tempfile.TemporaryDirectory(prefix="silique-gtk4-jni-") as tmp:
        source = Path(tmp) / "src"
        build = Path(tmp) / "build"
        source.mkdir()
        (source / "CMakeLists.txt").write_text(
            HARNESS.format(policy=policy, jni_linux=jni_linux.as_posix())
        )
        configure = _run(["cmake", "-S", str(source), "-B", str(build)])
        result = {
            "configure_ok": configure.returncode == 0,
            "configure_out": configure.stdout + configure.stderr,
            "jni_target": None,
            "dartjni": None,
            "needed": [],
            "build_out": "",
        }
        if not result["configure_ok"]:
            return result
        match = re.search(r"SILIQUE_JNI_TARGET=(\d)", result["configure_out"])
        result["jni_target"] = int(match.group(1)) if match else None
        compile_ = _run(["cmake", "--build", str(build)])
        result["build_ok"] = compile_.returncode == 0
        result["build_out"] = compile_.stdout + compile_.stderr
        libs = sorted(build.rglob("libdartjni.so"))
        result["dartjni"] = libs[0] if libs else None
        if result["dartjni"]:
            readelf = _run(["readelf", "-d", str(result["dartjni"])])
            result["needed"] = re.findall(r"\(NEEDED\)\s+Shared library: \[([^\]]+)\]", readelf.stdout)
        return result


class Gtk4NativeDependencyTest(unittest.TestCase):
    """GTK4 bundle must be independent of the builder's JDK."""

    _no_policy: dict | None = None
    _policy: dict | None = None

    @classmethod
    def _baseline(cls) -> dict:
        """Real jni sources without the GTK4 policy (pre-fix behaviour)."""
        if Gtk4NativeDependencyTest._no_policy is None:
            Gtk4NativeDependencyTest._no_policy = _build_harness(with_policy=False)
        return Gtk4NativeDependencyTest._no_policy

    @classmethod
    def _with_policy(cls) -> dict:
        """Real jni sources with the GTK4 runner policy applied."""
        if Gtk4NativeDependencyTest._policy is None:
            Gtk4NativeDependencyTest._policy = _build_harness(with_policy=True)
        return Gtk4NativeDependencyTest._policy

    def test_baseline_real_jni_builds_dartjni_with_jvm(self):
        """Characterisation of the bug: a builder JDK adds libdartjni + libjvm."""
        baseline = self._baseline()
        if not baseline["configure_ok"] or baseline["jni_target"] != 1:
            self.skipTest(
                "no JDK found on this builder; the optional jni bridge cannot "
                "reproduce the failure here (GTK4 CI builders do have one)"
            )
        self.assertIsNotNone(
            baseline["dartjni"],
            "jni target was created but libdartjni.so is missing:\n" + baseline["build_out"],
        )
        self.assertIn(
            "libjvm.so",
            baseline["needed"],
            "expected the optional bridge to link the builder JVM, got "
            f"NEEDED={baseline['needed']}",
        )

    def test_gtk4_policy_keeps_dartjni_out_of_bundle(self):
        """Real CMake + real jni sources + the actual GTK4 policy => no JNI."""
        self.assertTrue(
            POLICY_FILE.exists(),
            f"GTK4 native dependency policy is missing: {POLICY_FILE} must exist "
            "and disable the optional JNI lookup for the GTK4 runner",
        )
        result = self._with_policy()
        self.assertTrue(
            result["configure_ok"],
            "CMake could not configure the GTK4 policy harness:\n" + result["configure_out"],
        )
        self.assertEqual(
            result["jni_target"],
            0,
            "the jni target must not exist once the GTK4 policy disables the "
            "optional JNI lookup:\n" + result["configure_out"],
        )
        self.assertIsNone(
            result["dartjni"],
            "libdartjni.so must not be produced for the GTK4 runner:\n" + result["build_out"],
        )

    def test_gtk4_runner_applies_policy_before_plugins(self):
        """The GTK4 runner must include the policy before configuring plugins."""
        text = GTK4_CMAKE.read_text()
        self.assertIn(
            "gtk4_native_policy.cmake",
            text,
            f"{GTK4_CMAKE} does not reference the GTK4 native dependency policy",
        )
        policy_at = text.find("gtk4_native_policy.cmake")
        plugins_at = text.find(PLUGIN_INCLUDE)
        self.assertNotEqual(plugins_at, -1, f"{GTK4_CMAKE} no longer includes GTK4 plugins")
        self.assertLess(
            policy_at,
            plugins_at,
            "the policy must load before 'include(flutter/gtk4_plugins.cmake)', "
            "otherwise add_subdirectory(jni/linux) runs before the disable",
        )

    def test_jni_policy_is_scoped_to_gtk4_runner(self):
        """Android/macOS/Windows/stock-Linux runners must not disable JNI."""
        offenders = []
        for cmake in REPO.glob("*/CMakeLists.txt"):
            if cmake.parent.name == "linux-gtk4":
                continue
            if "CMAKE_DISABLE_FIND_PACKAGE_JNI" in cmake.read_text():
                offenders.append(str(cmake.relative_to(REPO)))
        for cmake in (REPO / "windows").rglob("CMakeLists.txt"):
            if "CMAKE_DISABLE_FIND_PACKAGE_JNI" in cmake.read_text():
                offenders.append(str(cmake.relative_to(REPO)))
        self.assertEqual(
            offenders,
            [],
            "the JNI disable must stay GTK4-only; found in: " + ", ".join(offenders),
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)