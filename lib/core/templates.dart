import 'models.dart';
import '../l10n/strings.dart' show tr;

/// Folder name that turns an ordinary note into a template. A note whose
/// `folder` equals this exact path (no subfolders) is selected by
/// [templatesOf]; anything else is an ordinary note. Because templates are
/// plain notes, they synchronize through the existing E2EE protocol without
/// any server or API change and without new tables.
const String templatesFolder = 'Szablony';

/// Localized weekday name for [day] (Monday..Sunday), used for the `{{weekday}}`
/// placeholder and any other UI that renders a day of the week.
String weekdayName(DateTime day) => switch (day.weekday) {
  1 => tr('poniedziałek', 'Monday'),
  2 => tr('wtorek', 'Tuesday'),
  3 => tr('środa', 'Wednesday'),
  4 => tr('czwartek', 'Thursday'),
  5 => tr('piątek', 'Friday'),
  6 => tr('sobota', 'Saturday'),
  7 => tr('niedziela', 'Sunday'),
  _ => '',
};

/// The terms `{{date}}`, `{{time}}`, `{{title}}`, `{{weekday}}` and `{{vault}}`
/// inside a template body, all in **lowercase exactly**. Uppercase or mixed-case
/// placeholders are deliberately left untouched: the contract defines a single
/// canonical spelling, and silently rewriting case variants would surprise
/// users who wrote `{{Title}}` as literal text.
List<Note> templatesOf(Iterable<Note> notes) {
  final templates = notes
      .where(
        (note) =>
            !note.deleted && !note.hidden && note.folder == templatesFolder,
      )
      .toList();
  templates.sort(
    (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
  );
  return templates;
}

/// Renders [body] with known `{{…}}` placeholders replaced by the values the
/// caller supplies. Unknown placeholders are preserved verbatim so a note
/// keeps every remaining token for the user to fill in later.
///
/// Values:
///  * `{{date}}`    — `YYYY-MM-DD` of [now] (local time);
///  * `{{time}}`    — `HH:MM` of [now] (local time, 24-hour, zero-padded);
///  * `{{title}}`   — [title];
///  * `{{weekday}}` — [weekday];
///  * `{{vault}}`   — [vaultName].
String renderTemplate(
  String body, {
  required DateTime now,
  required String title,
  required String vaultName,
  required String weekday,
}) {
  final local = now.toLocal();
  final date =
      '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
  final time =
      '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';

  final replacements = <String, String>{
    '{{date}}': date,
    '{{time}}': time,
    '{{title}}': title,
    '{{weekday}}': weekday,
    '{{vault}}': vaultName,
  };

  var result = body;
  for (final entry in replacements.entries) {
    result = result.replaceAll(entry.key, entry.value);
  }
  return result;
}

/// Rejects a template name that cannot be used as a note title. A title is
/// valid when it has at least one non-whitespace character; anything else
/// (empty, whitespace-only) returns a localized hint string describing the
/// problem. Returns null when the name is acceptable.
String? validateTemplateName(String name) {
  if (name.trim().isEmpty) {
    return tr(
      'Nazwa szablonu nie może być pusta.',
      'A template name cannot be empty.',
    );
  }
  return null;
}
