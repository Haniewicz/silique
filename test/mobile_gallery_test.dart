import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:livemd_flutter/livemd_flutter.dart';

import 'mobile_editor_layout_test.dart' show openPhone;
import 'fixtures/image_fixtures.dart';

class PhoneGallery extends ImagePickerPlatform {
  XFile? result;
  final sources = <ImageSource>[];
  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async {
    sources.add(source);
    return result;
  }
}

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets(
      'phone uses native gallery and cancellation leaves note unchanged',
      (tester) async {
        final gallery = PhoneGallery();
        final previous = ImagePickerPlatform.instance;
        ImagePickerPlatform.instance = gallery;
        addTearDown(() => ImagePickerPlatform.instance = previous);
        final repo = await openPhone(tester);
        final before = repo.notes[repo.vaults.single.id]!.values.single.body;
        await tester.ensureVisible(find.byTooltip('Wstaw zdjęcie'));
        await tester.tap(find.byTooltip('Wstaw zdjęcie'));
        await tester.pumpAndSettle();
        expect(gallery.sources, [ImageSource.gallery]);
        expect(repo.notes[repo.vaults.single.id]!.values.single.body, before);
        expect(find.byType(LiveMarkdownEditor), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(platform),
    );
  }
  testWidgets('gallery bytes enter existing encrypted attachment pipeline', (
    tester,
  ) async {
    final gallery = PhoneGallery()
      ..result = XFile.fromData(
        sampleBmp(width: 40, height: 20),
        name: 'photo.bmp',
        mimeType: 'image/bmp',
      );
    final previous = ImagePickerPlatform.instance;
    ImagePickerPlatform.instance = gallery;
    addTearDown(() => ImagePickerPlatform.instance = previous);
    final repo = await openPhone(tester);
    await tester.ensureVisible(find.byTooltip('Wstaw zdjęcie'));
    await tester.tap(find.byTooltip('Wstaw zdjęcie'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();
    expect(gallery.sources, [ImageSource.gallery]);
    final body = repo.notes[repo.vaults.single.id]!.values.single.body;
    final id = RegExp(r'silique-image:([^\)]+)').firstMatch(body)!.group(1)!;
    final bytes = await tester.runAsync(
      () => repo.imageBytes(repo.vaults.single.id, id),
    );
    expect(bytes, sampleBmp(width: 40, height: 20));
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
