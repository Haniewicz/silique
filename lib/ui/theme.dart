import 'package:flutter/material.dart';

const canvas = Color(0xff131925),
    sidebar = Color(0xff0e1420),
    panel = Color(0xff181f2f);
const line = Color(0xff2c3548),
    muted = Color(0xffa5aec8),
    accent = Color(0xff8275ff);

/// Sync indicator palette for the icon-only badge: green while the vault is
/// synced or syncing, orange (cloud-off, same hue as Colors.orangeAccent)
/// for every state without synchronization.
const syncOn = Color(0xff76e6b3), syncOff = Color(0xffffab40);

/// Bundled monospace family (assets/fonts, OFL). The generic `'monospace'`
/// alias is not resolved deterministically by Flutter on every Linux client,
/// which paints code text as tofu; the bundled family is.
const kMonoFontFamily = 'RobotoMono';
// Transient choices deliberately use neutral graphite, not the blue panels.
const menuGraphite = Color(0xff1c222d);
const menuHover = Color(0xff2b3042);
const menuBorder = Color(0xff343b49);
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
  fontFamily: 'Inter',
  fontFamilyFallback: const ['Apple Color Emoji', 'Noto Color Emoji'],
  scaffoldBackgroundColor: canvas,
  dividerColor: line,
  dividerTheme: const DividerThemeData(color: line, thickness: 1),
  colorScheme: const ColorScheme.dark(
    primary: accent,
    onPrimary: Colors.white,
    surface: panel,
    onSurface: Color(0xffeeefff),
    outline: line,
    secondary: Color(0xff75e4b0),
  ),
  textTheme: const TextTheme(
    bodyMedium: TextStyle(fontSize: 13, height: 1.5),
    bodySmall: TextStyle(fontSize: 11, color: muted),
    titleMedium: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: const Color(0xff1c2435),
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
      fontFamily: 'Inter',
      fontSize: 13,
      color: Color(0xffeeefff),
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
    backgroundColor: Color(0xff353342),
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
