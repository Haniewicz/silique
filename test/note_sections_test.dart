import 'package:flutter_test/flutter_test.dart';
import 'package:silique/core/models.dart';
import 'package:silique/core/note_sections.dart';

Note note(
  String id,
  DateTime updatedAt, {
  bool favorite = false,
}) => Note(
  id: id,
  vaultId: 'v',
  title: id,
  body: '',
  updatedAt: updatedAt,
  createdAt: updatedAt,
  favorite: favorite,
);

void main() {
  final now = DateTime(2026, 11, 16, 12, 0);

  group('date grouping is only for updated sort with an empty query', () {
    test('sort title flattens to a single headerless section', () {
      final notes = [
        note('a', now),
        note('b', now.subtract(const Duration(days: 2))),
        note('c', now.subtract(const Duration(days: 5))),
      ];
      final sections = buildNoteSections(
        notes,
        sort: 'title',
        filter: 'Wszystkie',
        query: '',
        now: now,
      );
      expect(sections, hasLength(1));
      expect(sections.single.hasTitle, isFalse);
      expect(sections.single.notes.map((n) => n.id), ['a', 'b', 'c']);
    });

    test('a non-empty query disables grouping even with updated sort', () {
      final notes = [note('a', now), note('b', now.subtract(const Duration(days: 2)))];
      final sections = buildNoteSections(
        notes,
        sort: 'updated',
        filter: 'Wszystkie',
        query: 'x',
        now: now,
      );
      expect(sections, hasLength(1));
      expect(sections.single.hasTitle, isFalse);
    });

    test('created-asc keeps input order in one flat section', () {
      final notes = [note('a', now), note('b', now.subtract(const Duration(days: 1)))];
      final sections = buildNoteSections(
        notes,
        sort: 'created-asc',
        filter: 'Wszystkie',
        query: '',
        now: now,
      );
      expect(sections, hasLength(1));
      expect(sections.single.notes.length, 2);
    });
  });

  group('favorite pinning', () {
    test('pinned favorites are removed from date groups', () {
      final notes = [
        note('fav', now, favorite: true),
        note('today', now),
      ];
      final sections = buildNoteSections(
        notes,
        sort: 'updated',
        filter: 'Wszystkie',
        query: '',
        now: now,
      );
      final titles = sections.map((s) => s.titlePl).toList();
      expect(titles, ['Przypięte', 'Dziś']);
      expect(sections[0].notes.map((n) => n.id), ['fav']);
      expect(sections[1].notes.map((n) => n.id), ['today']);
    });

    test('Ulubione filter omits the pinned section entirely', () {
      final notes = [note('fav', now, favorite: true)];
      final sections = buildNoteSections(
        notes,
        sort: 'updated',
        filter: 'Ulubione',
        query: '',
        now: now,
      );
      // Favorites flow into the date groups; no separate Pinned section.
      final titles = sections.map((s) => s.titlePl).toList();
      expect(titles, isNot(contains('Przypięte')));
      expect(sections, hasLength(1));
      expect(sections.single.titlePl, 'Dziś');
      expect(sections.single.notes.map((n) => n.id), ['fav']);
    });
  });

  group('day boundaries use local midnight', () {
    test('23:59 yesterday vs 00:01 today', () {
      final yesterdayLate = DateTime(now.year, now.month, now.day - 1, 23, 59);
      final todayEarly = DateTime(now.year, now.month, now.day, 0, 1);
      final notes = [
        note('y', yesterdayLate),
        note('t', todayEarly),
      ];
      final sections = buildNoteSections(
        notes,
        sort: 'updated',
        filter: 'Wszystkie',
        query: '',
        now: now,
      );
      final titles = sections.map((s) => s.titlePl).toList();
      expect(titles, ['Dziś', 'Wczoraj']);
      expect(sections[0].notes.map((n) => n.id), ['t']);
      expect(sections[1].notes.map((n) => n.id), ['y']);
    });

    test('older notes land in Starsze', () {
      final notes = [
        note('old', now.subtract(const Duration(days: 3))),
        note('today', now),
        note('yesterday', now.subtract(const Duration(days: 1))),
      ];
      final sections = buildNoteSections(
        notes,
        sort: 'updated',
        filter: 'Wszystkie',
        query: '',
        now: now,
      );
      final titles = sections.map((s) => s.titlePl).toList();
      expect(titles, ['Dziś', 'Wczoraj', 'Starsze']);
      expect(sections[0].notes.map((n) => n.id), ['today']);
      expect(sections[1].notes.map((n) => n.id), ['yesterday']);
      expect(sections[2].notes.map((n) => n.id), ['old']);
    });

    test('sections preserve input order within each group', () {
      final notes = [
        note('b', now),
        note('a', now),
        note('d', now.subtract(const Duration(days: 1))),
        note('c', now.subtract(const Duration(days: 1))),
      ];
      final sections = buildNoteSections(
        notes,
        sort: 'updated',
        filter: 'Wszystkie',
        query: '',
        now: now,
      );
      expect(sections[0].notes.map((n) => n.id), ['b', 'a']);
      expect(sections[1].notes.map((n) => n.id), ['d', 'c']);
    });
  });
}