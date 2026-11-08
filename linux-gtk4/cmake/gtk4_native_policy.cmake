# GTK4 (linux-gtk4) runner policy: keep the produced bundle independent of the
# builder's JDK.
#
# Why this is needed:
#   path_provider -> path_provider_android -> jni pulls the `jni` FFI plugin into
#   the Linux plugin list even though no Linux code path calls Java. `jni`
#   declares `linux: ffiPlugin: true` (pubspec), and jni 1.1.0 builds its dartjni
#   bridge only when CMake finds a JVM (jni/src/CMakeLists.txt:
#   `find_package(JNI COMPONENTS JVM)`). A JDK that merely happens to be installed
#   on the builder therefore silently adds libdartjni.so with a `NEEDED libjvm.so`
#   and an absolute RUNPATH, making the bundle depend on the builder's JDK.
#
#   On Linux, GTK4 uses pure-Dart implementations only: share_plus
#   (SharePlusLinuxPlugin), path_provider_linux and file_selector_linux. Nothing
#   in the GTK4 app loads Java, so the bridge is dead weight.
#
# What this does:
#   Disables the *optional* JNI lookup for this runner only, before any plugin is
#   configured. In the Flutter-plugin path the find is not REQUIRED, so disabling
#   it is graceful: JNI_FOUND stays false, the `jni` target is never created and
#   no libdartjni.so is bundled -- no post-build deletion and no relaxed
#   dependency audit.
#
# Scope:
#   linux-gtk4 only. Android is built by Gradle (never reads this file), and the
#   macOS and Windows runners are separate build trees; all keep their own JNI.
#
# To verify: tool/test_linux_native_dependencies.py configures and builds the real
# pinned `jni` sources through real CMake with and without this file.
set(CMAKE_DISABLE_FIND_PACKAGE_JNI TRUE)