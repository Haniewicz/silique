import 'package:flutter_test/flutter_test.dart';
import 'package:silique/core/fuzzy_match.dart';
import 'package:silique/core/models.dart';

Note _note(String id, String title, {String folder = '', DateTime? updatedAt}) =>
    Note(
      id: id,
      vaultId: 'vault',
      title: title,
      body: '',
      folder: folder,
      updatedAt: updatedAt ?? DateTime.utc(2026, 1, 1),
    );

void main() {
  test('subsequence matches in order, not necessarily contiguous', () {
    final match = fuzzyMatchNote(_note('1', 'Project Alpha'), 'pral');
    expect(match, isNotNull);
    expect(match!.titleHit, isTrue);
    expect(match.titleIndices, isNotEmpty);
  });

  test('case is ignored', () {
    final match = fuzzyMatchNote(_note('1', 'Meeting Notes'), 'MEET');
    expect(match, isNotNull);
    expect(match!.titleHit, isTrue);
  });

  test('Polish diacritics fold onto ASCII', () {
    final match = fuzzyMatchNote(_note('1', 'Żółta notatka'), 'zolta');
    expect(match, isNotNull);
    expect(match!.titleHit, isTrue);
  });

  test('folder-only hits are found and marked folderOnly', () {
    final match = fuzzyMatchNote(
      _note('1', 'Untitled', folder: 'Projekty/Dom'),
      'dom',
    );
    expect(match, isNotNull);
    expect(match!.folderOnly, isTrue);
    expect(match.titleHit, isFalse);
  });

  test('title hit ranks before folder-only hit', () {
    final titleHit = fuzzyMatchNote(_note('1', 'Domowe', folder: 'x'), 'do');
    final folderHit = fuzzyMatchNote(
      _note('2', 'Inne', folder: 'Dom'),
      'do',
    );
    expect(titleHit, isNotNull);
    expect(folderHit, isNotNull);
    expect(titleHit!.rank, lessThan(folderHit!.rank));
  });

  test('no result when query does not match either field', () {
    expect(fuzzyMatchNote(_note('1', 'Hello', folder: 'A'), 'zzz'), isNull);
  });

  test('empty query returns null', () {
    expect(fuzzyMatchNote(_note('1', 'Hello'), ''), isNull);
    expect(fuzzyMatchNote(_note('1', 'Hello'), '   '), isNull);
  });
}