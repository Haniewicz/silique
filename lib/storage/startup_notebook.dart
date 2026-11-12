import 'dart:io';

import '../core/contracts.dart';
import '../core/server_trust.dart';
import '../l10n/strings.dart';
import '../services/notebook.dart';
import 'native_crypto.dart';
import 'native_storage.dart';

/// Construct and initialize a notebook with the existing key namespace. A
/// successful activation is the only point allowed to update the root pointer.
Future<Notebook> openStartupNotebook(
  String root, {
  required KeyStore keys,
  String? applicationSupport,
  StorageRootExpectation? expectedRoot,
  ServerTrustStore? trustStore,
}) async {
  final expectation =
      expectedRoot ??
      (applicationSupport == null
          ? null
          : StorageRootExpectation(
              NativeStorage.recordedRoot(applicationSupport),
            ));
  // An existing vault is only opened once the folder itself is proven writable:
  // a folder blocked by the system (Windows Controlled folder access, antivirus,
  // read-only mount) is reported by SQLite as a generic I/O error that points at
  // the database, and SQLite cannot even read it, because publishing the WAL
  // index needs a write. Diagnosing the folder keeps the message honest.
  NativeStorage.verifyRootWritable(root);
  // Pins live beside the app's own support files, not in the vault, so they are
  // readable before unlock. When no support directory was passed it is resolved
  // here, so a confirmed pin survives a process restart. The in-memory store is
  // test-only and must be requested explicitly via [trustStore].
  final store = trustStore ??
      (applicationSupport == null
          ? await FileTrustStore.inApplicationSupport()
          : FileTrustStore(
              File(
                '$applicationSupport${Platform.pathSeparator}server-trust.json',
              ),
            ));
  final trust = ServerTrust(store: store);
  final notebook = Notebook(
    storage: NativeStorage(root),
    keys: keys,
    crypto: NativeCrypto(),
    trust: trust,
  );
  try {
    // Missing credentials are a recovery condition, not a fresh installation.
    // Never replace the wrapping key while existing vaults still depend on it.
    if (notebook.storage.vaults().isNotEmpty &&
        await keys.read('nova.localKey') == null) {
      throw StateError(
        tr(
          'Brakuje klucza istniejących vaultów. Przywróć dostęp do wybranego '
              'magazynu poświadczeń lub jego kopię zapasową. Nie utworzono nowego klucza.',
          'The key for existing vaults is missing. Restore access to the selected '
              'credential store or its backup. No new key was created.',
        ),
      );
    }
    await notebook.initialize();
    if (applicationSupport != null) {
      NativeStorage.persistChosenRoot(
        applicationSupport,
        root,
        expected: expectation,
      );
    }
    return notebook;
  } catch (_) {
    await notebook.close();
    rethrow;
  }
}
