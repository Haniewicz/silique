import 'models.dart';

/// A single fuzzy match result over one note: the note plus the scores and
/// character indices for highlight rendering.
class FuzzyMatch {
  const FuzzyMatch({
    required this.note,
    required this.titleScore,
    required this.folderScore,
    required this.titleIndices,
  });

  /// The matched note, kept alongside its scoring for the UI.
  final Note note;

  /// Score for a subsequence hit in the title (higher is better; 0 = no hit).
  final int titleScore;

  /// Score for a subsequence hit in the folder path (0 = no hit).
  final int folderScore;

  /// Indices into `note.title` that matched, for highlighting.
  final List<int> titleIndices;

  bool get titleHit => titleScore > 0;
  bool get folderOnly => !titleHit && folderScore > 0;

  /// Sort key: title hits before folder-only hits, then by recency.
  /// Tie-break is the raw `updatedAt` descending.
  int get rank => titleHit ? 0 : 1;
}

/// Case-insensitive fuzzy subsequence matcher over note titles and folders.
///
/// [query] letters must all appear in order (not necessarily contiguously) in
/// the haystack. Polish diacritics are folded onto their ASCII base via
/// `toLowerCase()` plus an explicit fold table so `ź` matches `z` and `ó`
/// matches `o`, with no extra dependencies.
///
/// Returns `null` when the query produces no match in either field.
FuzzyMatch? fuzzyMatchNote(Note note, String query) {
  final q = normalize(query);
  if (q.isEmpty) return null;
  final title = normalize(note.title);
  final folder = normalize(note.folder);
  final titleIndices = <int>[];
  final titleScore = subsequenceScore(q, title, titleIndices);
  final folderScore = subsequenceScore(q, folder, <int>[]);
  if (titleScore == 0 && folderScore == 0) return null;
  return FuzzyMatch(
    note: note,
    titleScore: titleScore,
    folderScore: folderScore,
    titleIndices: titleIndices,
  );
}

/// Scores [query] as a subsequence of [text]. Returns 0 when it is not a match.
/// Higher scores reward tighter matches (fewer gaps, an early start) and an
/// exact substring. [indices] receives the text positions that matched, when
/// non-const (used only for the title so far).
int subsequenceScore(String query, String text, List<int> indices) {
  if (query.isEmpty) return 0;
  if (query.length > text.length) return 0;
  var qi = 0;
  var gap = 0;
  var start = -1;
  var contiguous = 0;
  var maxContiguous = 0;
  var prev = -1;
  for (var ti = 0; ti < text.length && qi < query.length; ti++) {
    if (text.codeUnitAt(ti) == query.codeUnitAt(qi)) {
      if (start == -1) start = ti;
      indices.add(ti);
      if (prev != -1 && ti == prev + 1) {
        contiguous++;
        if (contiguous > maxContiguous) maxContiguous = contiguous;
      } else {
        contiguous = 0;
      }
      prev = ti;
      qi++;
    } else if (start != -1) {
      gap++;
    }
  }
  if (qi != query.length) {
    indices.clear();
    return 0;
  }
  // 1000 base + up to 100 for contiguity − gaps; larger = better.
  return 1000 + (maxContiguous * 20) - gap;
}

/// Folds case and Polish diacritics to a plain ASCII, lowercase form.
String normalize(String input) {
  final lower = input.toLowerCase();
  if (lower.isEmpty) return lower;
  const map = {
    'ą': 'a',
    'ć': 'c',
    'ę': 'e',
    'ł': 'l',
    'ń': 'n',
    'ó': 'o',
    'ś': 's',
    'ź': 'z',
    'ż': 'z',
  };
  final buffer = StringBuffer();
  for (final rune in lower.runes) {
    final ch = String.fromCharCode(rune);
    final replacement = map[ch];
    buffer.write(replacement ?? ch);
  }
  return buffer.toString();
}
