// Search rendering must stay linear in the number of matches: a big note with a
// frequent short query used to scan every annotation for every painted fragment.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/core/search.dart';
import 'package:silique/ui/highlight_controller.dart';

void main() {
  testWidgets('many matches paint in linear time with one span per match', (
    tester,
  ) async {
    // ~400 000 characters with 4 000 matches of a two-letter query.
    final buffer = StringBuffer();
    const word = 'kot ';
    const repeats = 4000;
    for (var i = 0; i < repeats; i++) {
      buffer.write('$word${'a' * 96} ');
    }
    final text = buffer.toString();
    final ranges = findMatchRanges(text, 'kot');
    expect(ranges.length, repeats);

    late TextSpan span;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            final controller = HighlightingTextController(text: text)
              ..matches = (ranges: ranges, active: ranges.length ~/ 2);
            final watch = Stopwatch()..start();
            span = controller.buildTextSpan(
              context: context,
              style: const TextStyle(fontSize: 14),
              withComposing: false,
            );
            watch.stop();
            // Linear work is milliseconds; the previous quadratic scan needed
            // seconds for this input. The bound only catches complexity
            // regressions, so it is deliberately generous.
            expect(watch.elapsedMilliseconds, lessThan(1500));
            return const SizedBox();
          },
        ),
      ),
    );

    final children = span.children!.cast<TextSpan>();
    // Each match is cut into its own fragment plus the gap after it, so painting
    // scales with the number of matches and never re-scans unrelated ranges.
    expect(children.length, ranges.length * 2);
    expect(
      children.where((child) => child.style?.backgroundColor != null).length,
      ranges.length,
    );
    expect(
      children.map((child) => child.text).join(),
      text,
      reason: 'painting must not change the document text',
    );
  });
}
