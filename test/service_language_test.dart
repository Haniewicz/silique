import 'dart:io';
import 'dart:typed_data';

// file_selector exposes its test platform seam through this transitive package.
// ignore: depend_on_referenced_packages
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/core/workspace.dart';
import 'package:silique/l10n/app_language.dart';
import 'package:silique/services/api.dart';
import 'package:silique/services/app_updates.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_files.dart';
import 'package:silique/storage/native_storage.dart';
import 'package:silique/storage/windows_folder_access.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

class _ImagePicker extends FileSelectorPlatform {
  List<XTypeGroup>? groups;

  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    groups = acceptedTypeGroups;
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'image picker label follows language while its const API stays valid',
    () async {
      final previous = appLanguage.languageCode;
      final originalPlatform = FileSelectorPlatform.instance;
      addTearDown(() async {
        FileSelectorPlatform.instance = originalPlatform;
        await appLanguage.setLanguage(previous);
      });
      final picker = _ImagePicker();
      FileSelectorPlatform.instance = picker;
      const compatibleTypes = [imageTypes];
      for (final code in ['en', 'pl']) {
        await appLanguage.setLanguage(code);
        await pickImage();
        final actual = picker.groups!.single;
        expect(actual.label, code == 'en' ? 'Images' : 'Zdjęcia');
        expect(actual.extensions, compatibleTypes.single.extensions);
        expect(actual.mimeTypes, compatibleTypes.single.mimeTypes);
      }
    },
  );

  test(
    'locked vault placeholder is translated without changing stored wire data',
    () async {
      final previous = appLanguage.languageCode;
      addTearDown(() => appLanguage.setLanguage(previous));
      final directory = Directory.systemTemp.createTempSync(
        'service-vault-language-',
      );
      final repo = Notebook(
        storage: NativeStorage(directory.path),
        keys: MemoryKeys(),
        crypto: TestCrypto(),
      );
      addTearDown(() async {
        await repo.close();
        directory.deleteSync(recursive: true);
      });
      await appLanguage.setLanguage('en');
      await repo.initialize();
      await repo.createVault('Chroniony vault', password: 'fixture-password');
      final vault = repo.vaults.single;
      expect(
        vault.name,
        'Chroniony vault',
      ); // This is the actual user-chosen name.
      repo.lock(vault.id);
      expect(repo.vaults.single.name, 'Protected vault');
      expect(repo.storage.vaults().single.name, 'Chroniony vault');
      expect(repo.vaults.single.toJson()['name'], 'Chroniony vault');
      await appLanguage.setLanguage('pl');
      expect(repo.vaults.single.name, 'Chroniony vault');
      await repo.unlock(repo.vaults.single, password: 'fixture-password');
      await appLanguage.setLanguage('en');
      expect(repo.vaults.single.name, 'Chroniony vault');
    },
  );

  test(
    'new ordinary, hidden and journal defaults use creation language only',
    () async {
      final previous = appLanguage.languageCode;
      addTearDown(() => appLanguage.setLanguage(previous));
      final directory = Directory.systemTemp.createTempSync(
        'service-language-',
      );
      final keys = MemoryKeys();
      var repo = Notebook(
        storage: NativeStorage(directory.path),
        keys: keys,
        crypto: TestCrypto(),
      );
      addTearDown(() async {
        await repo.close();
        directory.deleteSync(recursive: true);
      });
      await appLanguage.setLanguage('en');
      await repo.initialize();
      await repo.createVault('Osobiste');
      final vaultId = repo.vaults.single.id;
      final english = await repo.createNote(vaultId);
      expect(english.title, 'Untitled');
      await repo.setHiddenPassword('language-fixture-password');
      final hiddenEnglish = await repo.createHiddenNote(vaultId);
      expect(hiddenEnglish.title, 'Untitled');
      final journal = await repo.createNote(vaultId, journalDate: '2026-10-28');
      expect(journal.title, '2026-10-28');
      expect(journal.folder, 'Journal');
      expect(journal.body, '## Today\n\n- [ ] \n\n## Thoughts\n\n');
      await repo.save(
        english.copyWith(
          title: 'Bez tytułu',
          body: 'Treść',
          folder: 'Projekty/Żółć',
        ),
      );
      await appLanguage.setLanguage('pl');
      final polish = await repo.createNote(vaultId);
      expect(polish.title, 'Bez tytułu');
      expect((await repo.createHiddenNote(vaultId)).title, 'Bez tytułu');
      expect(
        (await repo.createNote(vaultId, journalDate: '2026-10-28')).id,
        journal.id,
      );
      final polishJournal = await repo.createNote(
        vaultId,
        journalDate: '2026-10-29',
      );
      expect(polishJournal.folder, 'Dziennik');
      expect(polishJournal.body, '## Dzisiaj\n\n- [ ] \n\n## Przemyślenia\n\n');
      final originalKeys = Map.of(keys.values);
      await repo.close();
      await appLanguage.setLanguage('en');
      repo = Notebook(
        storage: NativeStorage(directory.path),
        keys: keys,
        crypto: TestCrypto(),
      );
      await repo.initialize();
      expect(keys.values, originalKeys);
      expect(repo.vaults.single.name, 'Osobiste');
      expect(repo.notes[vaultId]![english.id]!.title, 'Bez tytułu');
      expect(repo.notes[vaultId]![english.id]!.folder, 'Projekty/Żółć');
      expect(repo.notes[vaultId]![english.id]!.body, 'Treść');
      expect(repo.notes[vaultId]![polish.id]!.title, 'Bez tytułu');
      expect(repo.notes[vaultId]![journal.id]!.folder, 'Journal');
      expect(repo.notes[vaultId]![polishJournal.id]!.folder, 'Dziennik');
      await repo.unlockHidden('language-fixture-password');
      expect(
        (await repo.hiddenNotes(vaultId))
            .firstWhere((n) => n.id == hiddenEnglish.id)
            .title,
        'Untitled',
      );
    },
  );

  test(
    'service and storage guidance switches language and preserves diagnostics',
    () async {
      final previous = appLanguage.languageCode;
      addTearDown(() => appLanguage.setLanguage(previous));
      for (final code in ['en', 'pl']) {
        await appLanguage.setLanguage(code);
        final english = code == 'en';
        expect(
          () => SiliqueApi.validateServer('https://example.com/path'),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              english
                  ? 'Enter a server address without a path, e.g. https://notes.example.com'
                  : 'Podaj adres serwera bez ścieżki, np. https://notes.example.com',
            ),
          ),
        );
        expect(
          () => artifactExtension(Uri.parse('https://example.com/file.zip')),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              english
                  ? 'Invalid update file.'
                  : 'Nieprawidłowy plik aktualizacji.',
            ),
          ),
        );
        await expectLater(
          readImageFile(
            XFile.fromData(
              Uint8List.fromList([1, 2, 3]),
              name: 'Żółć.txt',
              path: 'Żółć.txt',
            ),
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              english
                  ? 'File “Żółć.txt” is not a supported image (PNG, JPEG, GIF, WebP, BMP).'
                  : 'Plik „Żółć.txt” nie jest obsługiwanym zdjęciem (PNG, JPEG, GIF, WebP, BMP).',
            ),
          ),
        );
        const osError = FileSystemException(
          'OPAQUE_NATIVE_ERROR',
          '/Projekty/Żółć',
          OSError('VERBATIM_OS_DETAIL', 13),
        );
        final guidance = StorageLocationUnavailable.writeFailure(
          '/Projekty/Żółć',
          osError,
          isWindows: true,
        ).reason;
        expect(
          guidance,
          contains(
            english
                ? 'Check write permissions'
                : 'Sprawdź uprawnienia do zapisu',
          ),
        );
        expect(
          guidance,
          contains(
            english ? 'Do not disable protection.' : 'Nie wyłączaj ochrony.',
          ),
        );
        expect(guidance, contains('OPAQUE_NATIVE_ERROR'));
        expect(guidance, contains('VERBATIM_OS_DETAIL'));
        expect(guidance, contains('/Projekty/Żółć'));
        final access = await WindowsFolderAccess(isWindows: false)
            .inspect('/Projekty/Żółć');
        expect(
          access.message,
          english
              ? 'Windows inspection is unavailable for this installation or location.'
              : 'Inspekcja Windows jest niedostępna dla tej instalacji lub lokalizacji.',
        );
      }
      expect(NativeStorage.vaultsFolderName, 'Silique Vaults');
    },
  );

  test(
    'folder validation follows language without changing path rules',
    () async {
      final previous = appLanguage.languageCode;
      addTearDown(() => appLanguage.setLanguage(previous));
      await appLanguage.setLanguage('en');
      expect(folderSegmentError(''), 'The folder name cannot be empty.');
      expect(
        folderPathError('/Projects'),
        'Folder paths are relative — remove the leading /.',
      );
      expect(normalizeFolderPath(' Projekty / Żółć '), 'Projekty/Żółć');
      await appLanguage.setLanguage('pl');
      expect(folderSegmentError(''), 'Nazwa folderu nie może być pusta.');
      expect(
        folderPathError('/Projects'),
        'Ścieżka folderu jest względna — usuń początkowy znak /.',
      );
      expect(normalizeFolderPath(' Projekty / Żółć '), 'Projekty/Żółć');
    },
  );
}
