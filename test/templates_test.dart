import 'package:flutter_test/flutter_test.dart';
import 'package:silique/core/models.dart';
import 'package:silique/core/templates.dart';
import 'package:silique/l10n/strings.dart';

Note makeNote({
  required String id,
  required String title,
  String folder = '',
  bool deleted = false,
  bool hidden = false,
}) => Note(
  id: id,
  vaultId: 'vault',
  title: title,
  body: '',
  folder: folder,
  deleted: deleted,
  hidden: hidden,
  updatedAt: DateTime(2026, 1, 1),
);

void main() {
  group('templatesOf', () {
    test('selects only notes directly in the templates folder', () {
      final notes = [
        makeNote(id: 'a', title: 'Meeting', folder: 'Szablony'),
        makeNote(id: 'b', title: 'Daily', folder: 'Szablony/Podfolder'),
        makeNote(id: 'c', title: 'Note', folder: ''),
        makeNote(id: 'd', title: 'Other', folder: 'Inne'),
      ];
      final templates = templatesOf(notes);
      expect(templates.map((n) => n.id), ['a']);
    });

    test('excludes deleted and hidden notes', () {
      final notes = [
        makeNote(id: 'a', title: 'Live', folder: 'Szablony'),
        makeNote(id: 'b', title: 'Trashed', folder: 'Szablony', deleted: true),
        makeNote(id: 'c', title: 'Hidden', folder: 'Szablony', hidden: true),
      ];
      final templates = templatesOf(notes);
      expect(templates.map((n) => n.id), ['a']);
    });

    test('sorts by title case-insensitively', () {
      final notes = [
        makeNote(id: 'a', title: 'zebra', folder: 'Szablony'),
        makeNote(id: 'b', title: 'Apple', folder: 'Szablony'),
        makeNote(id: 'c', title: 'mango', folder: 'Szablony'),
      ];
      final templates = templatesOf(notes);
      expect(templates.map((n) => n.title), ['Apple', 'mango', 'zebra']);
    });
  });

  group('renderTemplate', () {
    test('replaces every known placeholder', () {
      final body = '{{date}} {{time}} {{title}} {{weekday}} {{vault}}';
      final rendered = renderTemplate(
        body,
        now: DateTime(2026, 11, 16, 9, 5),
        title: 'Spotkanie',
        vaultName: 'Osobiste',
        weekday: 'poniedziałek',
      );
      expect(rendered, '2026-11-16 09:05 Spotkanie poniedziałek Osobiste');
    });

    test('leaves unknown placeholders untouched', () {
      const body = '{{date}} {{unknown}} {{TITLE}} {{Date}}';
      final rendered = renderTemplate(
        body,
        now: DateTime(2026, 11, 16, 9, 5),
        title: 'X',
        vaultName: 'V',
        weekday: 'w',
      );
      expect(rendered, '2026-11-16 {{unknown}} {{TITLE}} {{Date}}');
    });

    test('formats date and time in local time with padding', () {
      final rendered = renderTemplate(
        '{{date}}/{{time}}',
        now: DateTime(2026, 1, 2, 3, 4),
        title: '',
        vaultName: '',
        weekday: '',
      );
      expect(rendered, '2026-01-02/03:04');
    });

    test('weekday is passed through verbatim', () {
      final rendered = renderTemplate(
        '{{weekday}}',
        now: DateTime(2026, 11, 16),
        title: '',
        vaultName: '',
        weekday: 'niedziela',
      );
      expect(rendered, 'niedziela');
    });
  });

  group('weekdayName', () {
    test('maps Monday..Sunday to weekday names', () {
      currentLanguageCode = 'en';
      addTearDown(() => currentLanguageCode = 'pl');
      // 2026-11-16 is a Monday.
      expect(weekdayName(DateTime(2026, 11, 16)), 'Monday');
      expect(weekdayName(DateTime(2026, 11, 22)), 'Sunday');
    });
  });

  group('validateTemplateName', () {
    test('rejects empty and whitespace-only names', () {
      expect(validateTemplateName(''), isNotNull);
      expect(validateTemplateName('   '), isNotNull);
    });

    test('accepts a non-empty name', () {
      expect(validateTemplateName('Notatka ze spotkania'), isNull);
    });
  });
}