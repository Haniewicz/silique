import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:livemd_flutter/livemd_flutter.dart';
import 'package:silique/main.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';

import '../test/core_test.dart' show MemoryKeys, TestCrypto;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('phone swipe, real keyboard viewport, emoji and empty task', (
    tester,
  ) async {
    final dir = await Directory.systemTemp.createTemp('silique-editor-native-');
    final repo = Notebook(
      storage: NativeStorage(dir.path),
      keys: MemoryKeys(),
      crypto: TestCrypto(),
    );
    await repo.initialize();
    await repo.createVault('Test gestów');
    final note = await repo.createNote(
      repo.vaults.single.id,
      folder: 'Projekty/Telefon',
    );
    await repo.save(
      note.copyWith(
        title: 'Test telefonu',
        body:
            '- [ ] Pierwsze zadanie\n${List.filled(50, 'Linia treści').join('\n')}\n',
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [notebookProvider.overrideWithValue(repo)],
        child: const SiliqueApp(),
      ),
    );
    await tester.pumpAndSettle();
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    await tester.dragFrom(Offset(80, screen.height * .5), const Offset(170, 0));
    await tester.pumpAndSettle();
    final scaffold = tester.state<ScaffoldState>(find.byType(Scaffold).first);
    expect(scaffold.isDrawerOpen, true);
    scaffold.closeDrawer();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('note-card-${note.id}')));
    await tester.pumpAndSettle();
    expect(find.text('Telefon'), findsOneWidget);
    await tester.tap(find.byTooltip('Wstaw emotkę'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('😊'));
    await tester.pumpAndSettle();
    final editor = tester.widget<LiveMarkdownEditor>(
      find.byType(LiveMarkdownEditor),
    );
    expect(editor.controller.text, endsWith('😊'));
    final field = find.byKey(const ValueKey('livemd-document-field'));
    await tester.tap(field);
    await tester.pumpAndSettle();
    final text = '${editor.controller.text}\n- [ ] ';
    editor.controller.setText(
      text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final editable = tester
        .state<EditableTextState>(find.byType(EditableText).last)
        .renderEditable;
    final caret = editable.getLocalRectForCaret(
      TextPosition(offset: text.length),
    );
    final keyboard =
        tester.view.viewInsets.bottom / tester.view.devicePixelRatio;
    expect(
      keyboard,
      greaterThan(0),
      reason: 'The native keyboard must really be open',
    );
    expect(
      editable.localToGlobal(caret.bottomLeft).dy,
      lessThan(screen.height - keyboard),
    );
    expect(
      find.byKey(ValueKey('task-${text.lastIndexOf('- [ ] ')}')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    // Dispose the app and drain native storage without touching the owner's vaults.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await repo.close();
    await dir.delete(recursive: true);
  });
}
