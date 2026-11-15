import 'models.dart';

/// One run of notes rendered under a single section header inside the list.
///
/// [titlePl] / [titleEn] are null for a flat (headerless) section; the caller
/// renders them through `tr(titlePl!, titleEn!)`.
class NoteSection {
  const NoteSection._(this.titlePl, this.titleEn, this.notes);

  final String? titlePl;
  final String? titleEn;
  final List<Note> notes;

  bool get hasTitle => titlePl != null && titleEn != null;
}

const _titlePinned = ('Przypięte', 'Pinned');
const _titleToday = ('Dziś', 'Today');
const _titleYesterday = ('Wczoraj', 'Yesterday');
const _titleOlder = ('Starsze', 'Older');

/// Splits a note list into ordered render sections.
///
/// Grouping by date happens only for `sort == 'updated'` with an empty trimmed
/// query; every other combination yields a single flat, headerless section that
/// preserves the input order. Favorite notes are pinned once and removed from
/// any date group, so a note never appears twice. Dates are compared in the
/// local time zone at day granularity (midnight boundaries).
List<NoteSection> buildNoteSections(
  List<Note> notes, {
  required String sort,
  required String filter,
  required String query,
  required DateTime now,
}) {
  if (sort != 'updated' || query.trim().isNotEmpty) {
    return [
      NoteSection._(null, null, List.unmodifiable(notes)),
    ];
  }

  // With the Favorites filter there is no separate pinned section, so favorited
  // notes flow into the date groups like any other note.
  final groupPinned = <Note>[];
  final hasPinnedSection = filter != 'Ulubione';
  if (hasPinnedSection) {
    groupPinned.addAll(notes.where((n) => n.favorite));
  }

  final today = <Note>[];
  final yesterday = <Note>[];
  final older = <Note>[];

  final nowLocal = now.toLocal();
  final todayStart = DateTime(nowLocal.year, nowLocal.month, nowLocal.day);
  final yesterdayStart = todayStart.subtract(const Duration(days: 1));

  for (final note in notes) {
    if (hasPinnedSection && note.favorite) {
      continue;
    }
    final updated = note.updatedAt.toLocal();
    final day = DateTime(updated.year, updated.month, updated.day);
    if (!day.isBefore(todayStart)) {
      today.add(note);
    } else if (!day.isBefore(yesterdayStart)) {
      yesterday.add(note);
    } else {
      older.add(note);
    }
  }

  final sections = <NoteSection>[];
  if (groupPinned.isNotEmpty) {
    sections.add(NoteSection._(_titlePinned.$1, _titlePinned.$2, groupPinned));
  }
  if (today.isNotEmpty) {
    sections.add(NoteSection._(_titleToday.$1, _titleToday.$2, today));
  }
  if (yesterday.isNotEmpty) {
    sections.add(
      NoteSection._(_titleYesterday.$1, _titleYesterday.$2, yesterday),
    );
  }
  if (older.isNotEmpty) {
    sections.add(NoteSection._(_titleOlder.$1, _titleOlder.$2, older));
  }
  return sections;
}