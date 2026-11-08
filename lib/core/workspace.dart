/// Folder tree rules shared by the editor UI, the notebook service and tests.
///
/// A folder path is a `/`-separated, relative, human-readable path such as
/// `Projekty/Mercaro`. Paths never start or end with `/`, never contain empty
/// segments, `.`/`..`, control characters or backslashes. IDs are not used for
/// folders: the existing note format already stores `note.folder` as such a
/// path, and syncing keeps that format unchanged.
library;

import '../l10n/strings.dart';

/// Maximum number of `/`-separated segments in one folder path.
const maxFolderDepth = 12;

/// Maximum length of a single segment, in UTF-16 code units.
const maxFolderSegmentLength = 64;

/// Maximum length of a complete folder path, in UTF-16 code units.
const maxFolderPathLength = 400;

/// Characters that would break a path or a Markdown mirror file name.
final _forbiddenSegment = RegExp(r'[\\\x00-\x1f\x7f]');

/// Returns a Polish error message, or `null` when [segment] is a valid name.
String? folderSegmentError(String segment) {
  final value = segment.trim();
  if (value.isEmpty) {
    return tr(
      'Nazwa folderu nie może być pusta.',
      'The folder name cannot be empty.',
    );
  }
  if (value != segment) {
    return tr(
      'Nazwa folderu nie może zaczynać się ani kończyć spacją.',
      'The folder name cannot start or end with a space.',
    );
  }
  if (value == '.' || value == '..') {
    return tr(
      'Nazwa folderu nie może być „.” ani „..”.',
      'The folder name cannot be “.” or “..”.',
    );
  }
  if (value.length > maxFolderSegmentLength) {
    return tr(
      'Nazwa folderu może mieć najwyżej $maxFolderSegmentLength znaków.',
      'The folder name can contain at most $maxFolderSegmentLength characters.',
    );
  }
  if (_forbiddenSegment.hasMatch(value)) {
    return tr(
      'Nazwa folderu zawiera niedozwolone znaki.',
      'The folder name contains invalid characters.',
    );
  }
  if (value.contains('/')) {
    return tr(
      'Użyj znaku / tylko do rozdzielenia poziomów folderów.',
      'Use / only to separate folder levels.',
    );
  }
  return null;
}

/// Canonicalizes and validates [raw].
///
/// Surrounding whitespace around the whole path and around each segment is
/// removed. Traversal (`..`), empty segments, absolute paths and names that are
/// not valid segments are rejected. Returns `null` when the path is invalid.
String? normalizeFolderPath(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed.startsWith('/')) return null;
  final segments = trimmed.split('/');
  if (segments.length > maxFolderDepth) return null;
  final cleaned = <String>[];
  for (final segment in segments) {
    if (segment.trim().isEmpty) return null;
    if (folderSegmentError(segment.trim()) != null) return null;
    cleaned.add(segment.trim());
  }
  final path = cleaned.join('/');
  return path.length > maxFolderPathLength ? null : path;
}

/// Validates [raw] and explains the first problem in Polish.
String? folderPathError(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    return tr('Podaj nazwę folderu.', 'Enter a folder name.');
  }
  if (trimmed.startsWith('/')) {
    return tr(
      'Ścieżka folderu jest względna — usuń początkowy znak /.',
      'Folder paths are relative — remove the leading /.',
    );
  }
  final segments = trimmed.split('/');
  if (segments.length > maxFolderDepth) {
    return tr(
      'Folder może mieć najwyżej $maxFolderDepth poziomów.',
      'Folders can have at most $maxFolderDepth levels.',
    );
  }
  for (final segment in segments) {
    final error = folderSegmentError(segment);
    if (error != null) return error;
  }
  if (trimmed.length > maxFolderPathLength) {
    return tr(
      'Ścieżka folderu jest zbyt długa (limit $maxFolderPathLength znaków).',
      'The folder path is too long (limit: $maxFolderPathLength characters).',
    );
  }
  return null;
}

/// Joins [parent] (empty for the root) with a relative [name] or path.
String joinFolderPath(String parent, String name) {
  final prefix = parent.trim();
  final child = name.trim();
  if (prefix.isEmpty) return child;
  if (child.isEmpty) return prefix;
  return '$prefix/$child';
}

/// Every ancestor of [path], shortest first. `A/B/C` → `A`, `A/B`.
List<String> folderAncestors(String path) {
  final segments = path.split('/').where((s) => s.isNotEmpty).toList();
  final result = <String>[];
  for (var i = 1; i < segments.length; i++) {
    result.add(segments.take(i).join('/'));
  }
  return result;
}

/// Whether [path] equals [ancestor] or lives inside it.
bool isSameOrDescendantPath(String path, String ancestor) =>
    path == ancestor || path.startsWith('$ancestor/');

/// Whether [path] lives strictly inside [ancestor].
bool isDescendantPath(String path, String ancestor) =>
    ancestor.isNotEmpty && path.startsWith('$ancestor/');

/// The final segment of [path].
String folderName(String path) => path.split('/').last;

/// Replaces the [from] prefix of [path] with [to]; used when renaming folders.
String replacePathPrefix(String path, String from, String to) =>
    '$to${path.substring(from.length)}';

/// Returns `true` when [candidate] collides with another path in [existing].
///
/// Comparison ignores letter case so that `Projekty` and `projekty` cannot
/// silently become two folders on case-insensitive file systems and cannot be
/// confused in the tree. [ignore] skips the folder being renamed or moved.
bool folderPathCollides(
  String candidate,
  Iterable<String> existing, {
  String? ignore,
}) {
  final target = candidate.toLowerCase();
  for (final path in existing) {
    if (ignore != null && (path == ignore || isDescendantPath(path, ignore))) {
      continue;
    }
    if (path.toLowerCase() == target) return true;
  }
  return false;
}

/// Three-way merge of folder paths.
///
/// [base] is the set the server confirmed during the last successful sync,
/// [local] the current local set and [server] the current server set. Only
/// differences from the base count as changes, so a stale client cannot
/// resurrect a folder that another device renamed or removed, while two
/// independent additions both survive. Removals win over stale copies, which is
/// the safe default: notes keep their folder and the tree re-creates an implied
/// parent, so no note is ever lost by a merge.
List<String> mergeFolderSets({
  required Iterable<String> base,
  required Iterable<String> local,
  required Iterable<String> server,
}) {
  final b = base.toSet(), l = local.toSet(), s = server.toSet();
  final result = <String>{...b, ...l.difference(b), ...s.difference(b)}
    ..removeAll(b.difference(l))
    ..removeAll(b.difference(s));
  final ordered = result.toList()..sort();
  return ordered;
}

/// Returns the first path that would collide after moving [from] to [to].
///
/// Every descendant keeps its relative part, so each resulting path is checked,
/// not only the folder being renamed. Comparison is case-insensitive and treats
/// an implied parent as existing.
String? folderMoveCollision({
  required String from,
  required String to,
  required Iterable<String> existing,
}) {
  final paths = <String>{};
  for (final raw in existing) {
    final path = normalizeFolderPath(raw);
    if (path == null) continue;
    paths.add(path);
    paths.addAll(folderAncestors(path));
  }
  final remaining = paths
      .where((path) => path != from && !isDescendantPath(path, from))
      .toList();
  for (final path in paths) {
    if (path != from && !isDescendantPath(path, from)) continue;
    final moved = replacePathPrefix(path, from, to);
    final lower = moved.toLowerCase();
    if (remaining.any((other) => other.toLowerCase() == lower)) return moved;
    // Two descendants of the same subtree can collide after the move when the
    // case-insensitive comparison matter, so keep checking the siblings too.
    if (folderPathCollides(moved, remaining)) return moved;
  }
  return null;
}

/// One rendered row of the folder tree.
class FolderEntry {
  FolderEntry({
    required this.path,
    required this.name,
    required this.depth,
    required this.hasChildren,
  });

  final String path;
  final String name;

  /// Nesting level; `0` for a top-level folder.
  final int depth;
  final bool hasChildren;

  @override
  String toString() => 'FolderEntry($path, depth: $depth)';
}

/// Builds a sorted, deduplicated tree from note folders and stored folders.
///
/// Missing parents implied by a deeper path are created as entries, so the tree
/// always contains every ancestor. Returns rows in display order, skipping the
/// subtrees of collapsed folders in [collapsed].
List<FolderEntry> buildFolderTree(
  Iterable<String> paths, {
  Set<String> collapsed = const {},
  Map<String, List<String>> order = const {},
}) {
  final all = <String>{};
  for (final raw in paths) {
    final path = normalizeFolderPath(raw);
    if (path == null) continue;
    all.add(path);
    all.addAll(folderAncestors(path));
  }
  final children = <String, List<String>>{};
  for (final path in all) {
    final parent = folderAncestors(path).isEmpty
        ? ''
        : folderAncestors(path).last;
    children.putIfAbsent(parent, () => []).add(path);
  }
  for (final list in children.values) {
    final preferred = order[folderParent(list.first)] ?? const <String>[];
    list.sort((a, b) {
      final ai = preferred.indexOf(a), bi = preferred.indexOf(b);
      if (ai >= 0 || bi >= 0) {
        if (ai < 0) return 1;
        if (bi < 0) return -1;
        return ai.compareTo(bi);
      }
      final name = folderName(a)
          .toLowerCase()
          .compareTo(folderName(b).toLowerCase());
      return name != 0 ? name : a.compareTo(b);
    });
  }
  final rows = <FolderEntry>[];
  void visit(String parent, int depth) {
    for (final path in children[parent] ?? const <String>[]) {
      final kids = children[path] ?? const <String>[];
      rows.add(
        FolderEntry(
          path: path,
          name: folderName(path),
          depth: depth,
          hasChildren: kids.isNotEmpty,
        ),
      );
      if (!collapsed.contains(path)) visit(path, depth + 1);
    }
  }

  visit('', 0);
  return rows;
}

/// The immediate parent, with the empty string denoting the vault root.
String folderParent(String path) =>
    path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '';

/// Read only valid sibling preferences. Preferences never create folders.
Map<String, List<String>> decodeFolderOrder(Object? raw) {
  if (raw is! Map) return {};
  final result = <String, List<String>>{};
  final parents = raw.keys.whereType<String>().toList()..sort();
  for (final parent in parents) {
    if (parent.isNotEmpty && normalizeFolderPath(parent) != parent) continue;
    final values = raw[parent];
    if (values is! List) continue;
    result[parent] = values
        .whereType<String>()
        .where(
          (path) =>
              normalizeFolderPath(path) == path && folderParent(path) == parent,
        )
        .toSet()
        .toList();
  }
  return result;
}

bool sameFolderOrder(Map<String, List<String>> a, Map<String, List<String>> b) {
  if (a.length != b.length) return false;
  for (final parent in a.keys) {
    final left = a[parent]!, right = b[parent];
    if (right == null || left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) {
      if (left[i] != right[i]) return false;
    }
  }
  return true;
}

/// Independent parent edits combine; concurrent edits of the same sibling list
/// use the server's confirmed order. Missing order on a legacy server is not an
/// instruction to erase the local preference.
Map<String, List<String>> mergeFolderOrder({
  required Map<String, List<String>> base,
  required Map<String, List<String>> local,
  required Map<String, List<String>> server,
}) {
  final result = <String, List<String>>{};
  final parents = {...base.keys, ...local.keys, ...server.keys}.toList()
    ..sort();
  for (final parent in parents) {
    final localChanged = !sameFolderOrder(
      {parent: local[parent] ?? []},
      {parent: base[parent] ?? []},
    );
    final remoteChanged = !sameFolderOrder(
      {parent: server[parent] ?? []},
      {parent: base[parent] ?? []},
    );
    final chosen = localChanged && !remoteChanged
        ? local[parent]
        : server[parent] ?? local[parent];
    if (chosen != null) result[parent] = List.of(chosen);
  }
  return result;
}

/// Remap ordering preferences with a subtree, or forget that subtree on trash.
Map<String, List<String>> remapFolderOrder(
  Map<String, List<String>> order,
  String source,
  String? target,
) {
  String? remap(String path) => isSameOrDescendantPath(path, source)
      ? target == null
            ? null
            : replacePathPrefix(path, source, target)
      : path;
  final result = <String, List<String>>{};
  for (final entry in order.entries) {
    final parent = remap(entry.key);
    if (parent == null) continue;
    result[parent] = [
      for (final path in entry.value)
        if (remap(path) case final String moved)
          if (folderParent(moved) == parent) moved,
    ];
  }
  return result;
}

/// Read only valid folder color preferences. Colors never create folders.
Map<String, int> decodeFolderColors(Object? raw) {
  if (raw is! Map) return {};
  final result = <String, int>{};
  for (final entry in raw.entries) {
    final path = entry.key;
    final color = entry.value;
    if (path is! String || color is! int) continue;
    if (normalizeFolderPath(path) != path) continue;
    if (color < 0 || color > 0xFFFFFFFF) continue;
    result[path] = color;
  }
  return result;
}

bool sameFolderColors(Map<String, int> a, Map<String, int> b) {
  if (a.length != b.length) return false;
  for (final path in a.keys) {
    if (a[path] != b[path]) return false;
  }
  return true;
}

/// Per-path three-way merge of folder color preferences.
///
/// [base] is the map the server confirmed last, [local] and [server] are the
/// current copies. Only differences from the base count as changes, so a
/// removal wins over a stale copy and two independent color additions both
/// survive. Concurrent edits of the same path use the server's confirmed
/// color, mirroring [mergeFolderOrder]. Colors are pure presentation: a merge
/// never touches folder membership.
Map<String, int> mergeFolderColors({
  required Map<String, int> base,
  required Map<String, int> local,
  required Map<String, int> server,
}) {
  final result = <String, int>{};
  for (final path in {...base.keys, ...local.keys, ...server.keys}) {
    final localChanged = local[path] != base[path];
    final remoteChanged = server[path] != base[path];
    final chosen = !localChanged
        ? server[path]
        : !remoteChanged
        ? local[path]
        : server[path] ?? local[path];
    if (chosen != null) result[path] = chosen;
  }
  return result;
}

/// Remap color preferences with a subtree, or forget that subtree on trash.
///
/// Folder order remaps its preferences on rename, so colors follow the same
/// rule to stay consistent with the existing pattern.
Map<String, int> remapFolderColors(
  Map<String, int> colors,
  String source,
  String? target,
) {
  final result = <String, int>{};
  for (final entry in colors.entries) {
    if (!isSameOrDescendantPath(entry.key, source)) {
      result[entry.key] = entry.value;
      continue;
    }
    if (target != null) {
      result[replacePathPrefix(entry.key, source, target)] = entry.value;
    }
  }
  return result;
}

/// Default note icon color (32-bit ARGB) applied when a note has no explicit
/// color and its vault has no `defaultNoteColor` preference. Shared by the
/// metadata reader and the note row renderer.
const int kDefaultNoteColor = 0xffa9c8ff;

/// Read only valid note color preferences (`{noteId: ARGB int}`). Note ids are
/// opaque strings, so unlike folder colors there is no path normalization;
/// only 32-bit ARGB values are kept. Orphaned entries for purged notes are
/// tolerated here — the UI never renders a color for a note it cannot find.
Map<String, int> decodeNoteColors(Object? raw) {
  if (raw is! Map) return {};
  final result = <String, int>{};
  for (final entry in raw.entries) {
    final id = entry.key;
    final color = entry.value;
    if (id is! String || color is! int) continue;
    if (color < 0 || color > 0xFFFFFFFF) continue;
    result[id] = color;
  }
  return result;
}

bool sameNoteColors(Map<String, int> a, Map<String, int> b) {
  if (a.length != b.length) return false;
  for (final id in a.keys) {
    if (a[id] != b[id]) return false;
  }
  return true;
}

/// Per-id three-way merge of note color preferences, mirroring
/// [mergeFolderColors]. Note colors are pure presentation, so a merge never
/// touches note documents or revisions.
Map<String, int> mergeNoteColors({
  required Map<String, int> base,
  required Map<String, int> local,
  required Map<String, int> server,
}) {
  final result = <String, int>{};
  for (final id in {...base.keys, ...local.keys, ...server.keys}) {
    final localChanged = local[id] != base[id];
    final remoteChanged = server[id] != base[id];
    final chosen = !localChanged
        ? server[id]
        : !remoteChanged
        ? local[id]
        : server[id] ?? local[id];
    if (chosen != null) result[id] = chosen;
  }
  return result;
}

/// All folder paths that exist in a vault, including stored empty folders and
/// the parents implied by a deeper path.
Set<String> collectFolderPaths(
  Iterable<String> storedFolders,
  Iterable<String> noteFolders,
) {
  final result = <String>{};
  for (final raw in [...storedFolders, ...noteFolders]) {
    final path = normalizeFolderPath(raw);
    if (path == null) continue;
    result.add(path);
    result.addAll(folderAncestors(path));
  }
  return result;
}
