import '../l10n/strings.dart';

import 'dart:convert';

import 'package:cryptography/cryptography.dart';

const updateRepository = 'Haniewicz/silique-releases';
const updatePublicKey = 'gISI1x7vljf/QRt50r3fmP4D8v8LwCJIkAFO2qUaCpc=';
final updateFeed = Uri.https(
  'raw.githubusercontent.com',
  '/$updateRepository/main/latest.json',
);
final publicReleasesPage = Uri.https(
  'github.com',
  '/$updateRepository/releases',
);

/// Canonical file-name suffix per platform. A signed release is only accepted
/// when every artifact URL exactly matches this allowlist, so even a valid
/// signature can never redirect a platform to another file, tag or format.
/// `linux` is the portable GTK4 tar; it is validated but never installed
/// automatically. `macos` remains the historical ZIP wire key; new feeds use
/// `macos-dmg` so older clients ignore the new format without rejecting updates
/// for Android/Linux. Both map to the internal `macos` platform after validation.
const updateSuffixes = <String, String>{
  'macos': '-macOS.zip',
  'macos-dmg': '-macOS.dmg',
  'android': '.apk',
  'windows': '-Setup-Windows-x64.exe',
  'linux': '-Linux-GTK4-x64.tar.gz',
  'linux-deb': '-Linux-GTK4-amd64.deb',
  'linux-rpm': '-Linux-GTK4-x86_64.rpm',
};

class InstalledApp {
  const InstalledApp(this.version, this.build, this.platform);
  final String version, platform;
  final int build;
  bool get supported =>
      platform == 'macos' ||
      platform == 'android' ||
      platform == 'windows' ||
      packagedLinux.contains(platform);

  /// The two Linux formats the updater can install with the system package
  /// manager. A portable tar (`linux`) stays a manual download so an update
  /// never adds a second, package-managed copy of the application.
  static const packagedLinux = {'linux-deb', 'linux-rpm'};
}

class UpdateArtifact {
  const UpdateArtifact({
    required this.url,
    required this.sha256,
    required this.size,
  });
  final Uri url;
  final String sha256;
  final int size;
}

class AppRelease {
  const AppRelease({
    required this.version,
    required this.build,
    required this.notes,
    required this.artifacts,
  });
  final String version, notes;
  final int build;
  final Map<String, UpdateArtifact> artifacts;

  static Future<AppRelease> verify(
    String envelope, {
    String publicKey = updatePublicKey,
  }) async {
    if (utf8.encode(envelope).length > 128 * 1024) {
      throw FormatException(
        tr(
          'Informacja o aktualizacji jest zbyt duża.',
          'The update information is too large.',
        ),
      );
    }
    final wrapper = jsonDecode(envelope) as Map<String, dynamic>;
    final payload = base64Decode(wrapper['payload'] as String);
    final signature = base64Decode(wrapper['signature'] as String);
    final verified =
        signature.length == 64 &&
        await Ed25519().verify(
          payload,
          signature: Signature(
            signature,
            publicKey: SimplePublicKey(
              base64Decode(publicKey),
              type: KeyPairType.ed25519,
            ),
          ),
        );
    if (!verified) {
      throw FormatException(
        tr('Nieprawidłowy podpis aktualizacji.', 'Invalid update signature.'),
      );
    }
    final data = jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;
    final version = data['version'] as String;
    final build = data['build'] as int;
    if (data['schema'] != 1 ||
        !RegExp(r'^\d{1,4}\.\d{1,4}\.\d{1,4}$').hasMatch(version) ||
        build < 1) {
      throw FormatException(
        tr('Nieprawidłowa wersja aktualizacji.', 'Invalid update version.'),
      );
    }
    final notes = data['notes'] as String;
    if (notes.length > 20000) {
      throw FormatException(
        tr(
          'Opis aktualizacji jest zbyt długi.',
          'The update description is too long.',
        ),
      );
    }
    final artifacts = <String, UpdateArtifact>{};
    final platforms = data['platforms'] as Map<String, dynamic>;
    if (platforms.containsKey('macos') && platforms.containsKey('macos-dmg')) {
      throw FormatException(
        tr(
          'Niejednoznaczny plik aktualizacji macOS.',
          'Ambiguous macOS update file.',
        ),
      );
    }
    for (final platform in updateSuffixes.keys) {
      if (platforms[platform] == null) continue;
      final item = platforms[platform] as Map<String, dynamic>;
      final suffix = updateSuffixes[platform];
      final expected =
          'https://github.com/$updateRepository/releases/download/v$version/Silique-$version$suffix';
      final url = item['url'] as String;
      final sha = item['sha256'] as String;
      final size = item['size'] as int;
      if (url != expected ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha) ||
          size < 1 ||
          size > 512 * 1024 * 1024) {
        throw FormatException(
          tr('Nieprawidłowy plik aktualizacji.', 'Invalid update file.'),
        );
      }
      artifacts[platform == 'macos-dmg' ? 'macos' : platform] = UpdateArtifact(
        url: Uri.parse(url),
        sha256: sha,
        size: size,
      );
    }
    if (artifacts.isEmpty) {
      throw FormatException(
        tr('Brak plików aktualizacji.', 'No update files available.'),
      );
    }
    return AppRelease(
      version: version,
      build: build,
      notes: notes,
      artifacts: Map.unmodifiable(artifacts),
    );
  }
}

abstract interface class UpdateInstaller {
  Future<InstalledApp?> info();
  Future<String> downloadDirectory();
  Future<String> installAndroid(String path);
  Future<void> installMac();
}

/// Outcome of a privileged Linux package installation.
enum LinuxInstallOutcome { installed, cancelled, failed }

/// Optional capability of an [UpdateInstaller] that can install a verified
/// RPM/DEB with the system package manager after the user confirms the system
/// authorization dialog. It is a separate interface so the existing
/// macOS/Android installer and tests stay unchanged.
abstract interface class LinuxUpdateInstaller {
  /// Installs the already downloaded and hash-verified package at the absolute
  /// [path] for [platform] ('linux-deb' or 'linux-rpm'). The caller has already
  /// verified size and SHA256: this never downloads or re-verifies.
  Future<LinuxInstallOutcome> installLinux(String platform, String path);
}

/// A launch acknowledgment is not evidence of a completed installation.
enum WindowsInstallOutcome { launched, cancelled, failed }

abstract interface class WindowsUpdateInstaller {
  Future<WindowsInstallOutcome> installWindows(
    String path,
    AppRelease release,
    UpdateArtifact artifact,
  );
}

/// Editor/repository quiescence, reversible only before native launch.
abstract interface class WindowsUpdateHandoff {
  /// Called only after launch: irreversibly retain the fences before closing.
  /// A failed close may be retried by calling commit again; it must not abort.
  Future<void> commit();

  /// Restore admission only before commit has begun. After launch this is a no-op.
  Future<void> abort();
}
