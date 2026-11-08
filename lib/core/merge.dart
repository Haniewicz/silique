class MergeResult {
  const MergeResult(this.text, this.conflict);
  final String text;
  final bool conflict;
}

class _Hunk {
  _Hunk(this.start, this.end, this.lines);
  final int start, end;
  final List<String> lines;
}

List<_Hunk> _diff(List<String> a, List<String> b) {
  final matrix = List.generate(
    a.length + 1,
    (_) => List<int>.filled(b.length + 1, 0),
  );
  for (var i = a.length - 1; i >= 0; i--) {
    for (var j = b.length - 1; j >= 0; j--) {
      matrix[i][j] = a[i] == b[j]
          ? matrix[i + 1][j + 1] + 1
          : (matrix[i + 1][j] > matrix[i][j + 1]
                ? matrix[i + 1][j]
                : matrix[i][j + 1]);
    }
  }
  final hunks = <_Hunk>[];
  var i = 0, j = 0;
  while (i < a.length || j < b.length) {
    if (i < a.length && j < b.length && a[i] == b[j]) {
      i++;
      j++;
      continue;
    }
    final start = i, lines = <String>[];
    while (i < a.length || j < b.length) {
      if (i < a.length && j < b.length && a[i] == b[j]) break;
      if (j < b.length &&
          (i == a.length || matrix[i][j + 1] >= matrix[i + 1][j])) {
        lines.add(b[j++]);
      } else {
        i++;
      }
    }
    hunks.add(_Hunk(start, i, lines));
  }
  return hunks;
}

MergeResult threeWayMerge(String base, String left, String right) {
  if (left == right || right == base) return MergeResult(left, false);
  if (left == base) return MergeResult(right, false);
  final a = base.split('\n'), b = left.split('\n'), c = right.split('\n');
  if (a.length * b.length > 1000000 || a.length * c.length > 1000000) {
    return MergeResult(left, true);
  }
  final changes = _diff(a, b);
  for (final h in _diff(a, c)) {
    var same = false;
    for (final l in changes) {
      if (l.start == h.start &&
          l.end == h.end &&
          l.lines.join('\n') == h.lines.join('\n')) {
        same = true;
        break;
      }
      final bothInsert =
          l.start == l.end && h.start == h.end && l.start == h.start;
      final overlap = l.start < h.end && h.start < l.end;
      final insertInside =
          (l.start == l.end && l.start > h.start && l.start < h.end) ||
          (h.start == h.end && h.start > l.start && h.start < l.end);
      if (bothInsert || overlap || insertInside) return MergeResult(left, true);
    }
    if (!same) changes.add(h);
  }
  changes.sort((x, y) => y.start.compareTo(x.start));
  final result = [...a];
  for (final h in changes) {
    result.replaceRange(h.start, h.end, h.lines);
  }
  return MergeResult(result.join('\n'), false);
}
