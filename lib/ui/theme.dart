import 'package:flutter/material.dart';

const canvas = Color(0xff131925),
    sidebar = Color(0xff0e1420),
    panel = Color(0xff181f2f);
const line = Color(0xff2c3548),
    muted = Color(0xffa5aec8),
    accent = Color(0xff8275ff);

/// Sync indicator palette for the icon-only badge: green while the vault is
/// synced or syncing, amber (cloud-off), for every state without synchronization.
const syncOn = Color(0xff76e6b3), syncOff = Color(0xffffab40);

/// Bundled UI family (assets/fonts, OFL). Widgets rendered outside the normal
/// `Material` tree — e.g. a bare `OverlayEntry` — get `WidgetsApp`'s app-wide
/// error style (`MaterialApp._errorTextStyle`: monospace, w900, yellow double
/// underline) instead of the theme, so they must name this family explicitly.
const kUiFontFamily = 'Inter';

/// Bundled monospace family (assets/fonts, OFL). The generic `'monospace'`
/// alias is not resolved deterministically by Flutter on every Linux client,
/// which paints code text as tofu; the bundled family is.
const kMonoFontFamily = 'RobotoMono';
// Transient choices deliberately use neutral graphite, not the blue panels.
const menuGraphite = Color(0xff1c222d);
const menuHover = Color(0xff2b3042);
const menuBorder = Color(0xff343b49);

// ── Semantic text tokens ────────────────────────────────────────────────────
/// Body copy in the editor and reading surfaces.
const textBody = Color(0xffcdd3e8);

/// Secondary text: unselected note titles and list labels.
const textSecondary = Color(0xffc0c7df);

/// Muted accent for a single on-button shortcut hint (e.g. "Ctrl + N").
const badgeText = Color(0xffdbd6ff);

// ── Status / semantic colors ────────────────────────────────────────────────
/// Green reused by the "synced" cloud icon and success messages.
const success = Color(0xff75e4b0);

/// Amber for the single warning/conflict semantics: unsynced state, conflict
/// copies, invalid input hints and "no matches" notes. One token so the shade
/// cannot drift between screens (formerly spelled `Colors.orangeAccent`).
const warning = Color(0xffffab40);

/// Strongest text: dialog titles, popup-menu labels and `onSurface`.
const textStrong = Color(0xffeeefff);

/// Background of outlined text inputs.
const inputFill = Color(0xff1c2435);

/// Snackbar surface, deliberately neutral graphite.
const snackbarBg = Color(0xff353342);

/// Icon tint for the vault cloud/lock glyph in both sidebars.
const vaultIcon = Color(0xff81e7db);

/// Unified hover background for interactive rows (folder rows, settings rows,
/// sidebar tiles): rounded `Material` + `InkWell` draw this same overlay so a
/// hover reads identically everywhere. Matches the default `InkWell` hover the
/// folder rows already relied on (onSurface @ ~8%), now pinned to one token so
/// light/dark and every screen share a single shade.
const hover = Color(0x14ffffff);

/// The corner radius of the hover surface (folder rows and settings rows).
const hoverRadius = 6.0;

/// The rounded hover surface of the Settings rows. `SwitchListTile`,
/// `ListTile` with `onTap` and `CheckboxListTile` draw their InkWell hover with
/// `shape ?? tileTheme.shape`, so without an explicit `shape` the row paints a
/// square rectangle next to the folder rows' rounded hover. Shared here so
/// every settings row matches `_folderRow`/`_sectionTile`.
const hoverTileShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(hoverRadius)),
);

/// The corner radius of the hover surface for Settings-section rows.
///
/// Slightly larger than [hoverRadius] (folder rows) so a hover reads clearly
/// against the settings page background without changing the folder-row look.
const settingsItemRadius = 8.0;

/// The rounded hover surface of Settings-section rows. Used in place of
/// [hoverTileShape] for `ListTile`/`SwitchListTile`/`CheckboxListTile` inside
/// the Settings panel; folder rows keep [hoverRadius]/[hoverTileShape].
const settingsItemShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(settingsItemRadius)),
);

/// Horizontal content inset of Settings-section rows so their content is not
/// flush against the panel edge.
const settingsItemPadding = EdgeInsets.symmetric(horizontal: 10);

/// Vertical gap between Settings-section rows.
const settingsItemGap = 4.0;

/// Folder glyph tint when the folder carries no explicit accent.
const folderIcon = Color(0xff8fa6de);

// ── Surfaces (bars, cards, chips, inputs) ───────────────────────────────────
/// Deeper end of the sidebar vertical gradient and its pinned search header.
const sidebarDeep = Color(0xff101725);

/// Editor document gradient: lighter top-left to darker bottom-right.
const editorGradientStart = Color(0xff171d2b);
const editorGradientEnd = Color(0xff101622);

/// Solid background for bars: tab strip header and bottom navigation.
const barBg = Color(0xff111725);

/// Toolbar background under the editor header.
const toolbarBg = Color(0xff1a2030);

/// Toolbar/heading action foreground (icons and H1/H2/H3 buttons).
const toolbarForeground = Color(0xffc3cae3);

/// Active tab surface in the tab strip.
const tabSelected = Color(0xff282b47);

/// Selected note-card surface in the list.
const cardSelected = Color(0xff252944);

/// Selected filter-chip surface.
const filterChipSelected = Color(0xff28284c);

/// Chip (tag / drag feedback) background.
const chipBg = Color(0xff282d46);

/// Chip (tag) label text.
const chipText = Color(0xffc1c0ff);

/// Section header ("Dziś", "Wczoraj"…) text.
const sectionHeader = Color(0xffc6c2ff);

/// Inline code / fenced code block text background.
const codeBg = Color(0xff1f2739);

/// Foreground for flat text buttons (nav actions, title-bar actions).
const buttonForeground = Color(0xffdfe3f5);

/// Sidebar navigation item foreground.
const navForeground = Color(0xffc2c8df);

/// "New note" action gradient and floating action button.
const newNoteGradientStart = Color(0xff7b6bff);
const newNoteGradientEnd = Color(0xff5756f5);
const fabBg = Color(0xff6660ff);

// ── Search/find highlight (editor annotations and the raw field) ───────────
/// Background of a non-active search match (alpha baked into the token).
const findMatchHighlight = Color(0x55ffd54f);

/// Background of the active search match.
const findActiveHighlight = Color(0x99ffb300);

/// Raw-field (plain text editor) match and active-match underlays.
const findMatchColor = Color(0x66ffd54f);
const findActiveMatchColor = Color(0xccffb300);

// ── Hue spectrum for the color picker ───────────────────────────────────────
// These are presets of a physical hue wheel, not semantic states; "red" here is
// unrelated to any error/danger color and must stay a separate token.
const hueRed = Color(0xffff0000);
const hueYellow = Color(0xffffff00);
const hueGreen = Color(0xff00ff00);
const hueCyan = Color(0xff00ffff);
const hueBlue = Color(0xff0000ff);
const hueMagenta = Color(0xffff00ff);
const menuShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(18)),
  side: BorderSide(color: menuBorder),
);
const siliqueMenuStyle = MenuStyle(
  backgroundColor: WidgetStatePropertyAll(menuGraphite),
  surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
  shadowColor: WidgetStatePropertyAll(Colors.black54),
  elevation: WidgetStatePropertyAll(8),
  padding: WidgetStatePropertyAll(EdgeInsets.all(8)),
  shape: WidgetStatePropertyAll(menuShape),
);
ThemeData siliqueTheme() => ThemeData(
  brightness: Brightness.dark,
  useMaterial3: true,
  fontFamily: kUiFontFamily,
  fontFamilyFallback: const ['Apple Color Emoji', 'Noto Color Emoji'],
  scaffoldBackgroundColor: canvas,
  dividerColor: line,
  dividerTheme: const DividerThemeData(color: line, thickness: 1),
  hoverColor: hover,
  splashFactory: NoSplash.splashFactory,
  colorScheme: const ColorScheme.dark(
    primary: accent,
    onPrimary: Colors.white,
    surface: panel,
    onSurface: textStrong,
    outline: line,
    secondary: success,
  ),
  textTheme: const TextTheme(
    bodyMedium: TextStyle(fontSize: 13, height: 1.5),
    bodySmall: TextStyle(fontSize: 11, color: muted),
    titleMedium: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: inputFill,
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(9),
      borderSide: const BorderSide(color: line),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(9),
      borderSide: const BorderSide(color: line),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(9),
      borderSide: const BorderSide(color: accent),
    ),
    hintStyle: const TextStyle(color: muted, fontSize: 12),
  ),
  popupMenuTheme: PopupMenuThemeData(
    color: menuGraphite,
    elevation: 8,
    surfaceTintColor: Colors.transparent,
    shadowColor: Colors.black54,
    menuPadding: const EdgeInsets.all(8),
    shape: menuShape,
    textStyle: const TextStyle(
      fontFamily: kUiFontFamily,
      fontSize: 13,
      color: textStrong,
    ),
  ),
  dropdownMenuTheme: const DropdownMenuThemeData(menuStyle: siliqueMenuStyle),
  menuTheme: const MenuThemeData(style: siliqueMenuStyle),
  menuButtonTheme: MenuButtonThemeData(
    style: ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
      iconColor: const WidgetStatePropertyAll(accent),
      overlayColor: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.hovered) ||
                states.contains(WidgetState.focused)
            ? menuHover
            : Colors.transparent,
      ),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
  ),
  iconTheme: const IconThemeData(color: muted, size: 19),
  iconButtonTheme: IconButtonThemeData(
    style: IconButton.styleFrom(
      foregroundColor: muted,
      minimumSize: const Size(34, 34),
      padding: const EdgeInsets.all(7),
    ),
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
    ),
  ),
  snackBarTheme: const SnackBarThemeData(
    backgroundColor: snackbarBg,
    contentTextStyle: TextStyle(color: Colors.white),
  ),
  dialogTheme: DialogThemeData(
    backgroundColor: menuGraphite,
    surfaceTintColor: Colors.transparent,
    shadowColor: Colors.black54,
    elevation: 8,
    shape: menuShape,
  ),
);

class SiliqueMark extends StatelessWidget {
  const SiliqueMark({super.key, this.size = 34});
  final double size;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: accent.withValues(alpha: .13),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Icon(Icons.eco_rounded, color: accent, size: size * .82),
  );
}
