import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/ui/theme.dart';

void main() {
  test('every menu theme shares graphite, border, radius and row states', () {
    final theme = siliqueTheme();
    expect(theme.popupMenuTheme.color, const Color(0xff1c222d));
    final menu = theme.menuTheme.style!;
    expect(menu.backgroundColor!.resolve({}), theme.popupMenuTheme.color);
    expect(
      theme.dropdownMenuTheme.menuStyle!.shape!.resolve({}),
      menu.shape!.resolve({}),
    );
    expect(
      theme.menuButtonTheme.style!.minimumSize!.resolve({})!.height,
      greaterThanOrEqualTo(48),
    );
    expect(
      theme.menuButtonTheme.style!.overlayColor!.resolve({WidgetState.hovered}),
      isNot(Colors.transparent),
    );
  });
}
