/// Localized, alias-aware naming for the built-in folders (`Szablony`/
/// `Templates` and `Dziennik`/`Journal`).
///
/// Both spellings are treated as the *same* system folder, case-insensitively,
/// so a vault created in one UI language keeps working after switching to the
/// other. The UI always renders the name of the current language, but stored
/// paths and note metadata are never rewritten — existing data stays untouched.
library;

import '../l10n/strings.dart' show tr;

/// Every spelling recognized as the built-in templates folder.
const List<String> templatesFolderAliases = ['Szablony', 'Templates'];

/// Every spelling recognized as the built-in journal folder.
const List<String> journalFolderAliases = ['Dziennik', 'Journal'];

/// The templates folder name in the current UI language. New vaults, seeds and
/// display strings use this name; stored paths are left as they are.
String get templatesFolder => tr('Szablony', 'Templates');

/// The journal folder name in the current UI language.
String get journalFolder => tr('Dziennik', 'Journal');

bool _isAlias(String segment, List<String> aliases) {
  final lower = segment.toLowerCase();
  return aliases.any((alias) => alias.toLowerCase() == lower);
}

/// Whether the first segment of [path] equals one of [aliases]
/// (case-insensitive). An empty path or a path outside the system folder is
/// never a match.
bool isSystemFolderPath(String path, List<String> aliases) {
  final segment = path.split('/').first.trim();
  if (segment.isEmpty) return false;
  return _isAlias(segment, aliases);
}

/// Whether [path] is the templates folder or anything nested under it.
bool isTemplatesFolderPath(String path) =>
    isSystemFolderPath(path, templatesFolderAliases);

/// Whether [path] is the templates folder root — an alias at depth one, not a
/// nested subfolder. Used where only the root is protected (deletion).
bool isTemplatesRootPath(String path) =>
    !path.contains('/') && isSystemFolderPath(path, templatesFolderAliases);

/// Whether [path] is the journal folder or anything nested under it.
bool isJournalFolderPath(String path) =>
    isSystemFolderPath(path, journalFolderAliases);

/// Replaces the first segment of [path] with the current-language name when it
/// is a system folder alias; otherwise returns [path] unchanged. Display-only:
/// it never changes the path used for storage, filtering or operations.
String localizeSystemFolderPath(String path) {
  final segments = path.split('/');
  if (segments.isEmpty) return path;
  final first = segments.first;
  if (_isAlias(first, templatesFolderAliases)) {
    segments[0] = templatesFolder;
  } else if (_isAlias(first, journalFolderAliases)) {
    segments[0] = journalFolder;
  }
  return segments.join('/');
}

/// Localizes a bare folder name (a leaf segment) when it is a system folder
/// alias, e.g. `Templates` → `Szablony` in Polish. Display-only.
String localizeSystemFolderName(String name) {
  if (_isAlias(name, templatesFolderAliases)) return templatesFolder;
  if (_isAlias(name, journalFolderAliases)) return journalFolder;
  return name;
}

/// The path of [path] relative to the templates folder root (e.g. `A/B` for
/// `Szablony/A/B`), or `null` when [path] is not inside the templates folder
/// or is the root itself. Used to disambiguate same-named templates from
/// different subfolders.
String? templatesSubpathOf(String path) {
  if (!isTemplatesFolderPath(path)) return null;
  final index = path.indexOf('/');
  if (index < 0) return null;
  return path.substring(index + 1);
}
