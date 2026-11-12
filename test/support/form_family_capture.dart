import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const formFamilyCapture = Key('form-family-capture');
const _capture = bool.fromEnvironment('CAPTURE_FORM_FAMILY');

Future<void> loadFormFamilyFonts() async {
  if (!_capture) return;
  const directory = String.fromEnvironment('CAPTURE_FONT_DIR');
  for (final font in {
    'Roboto': 'Roboto-Regular.ttf',
    'MaterialIcons': 'MaterialIcons-Regular.otf',
  }.entries) {
    await (FontLoader(font.key)..addFont(
          File(
            '$directory/${font.value}',
          ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
        ))
        .load();
  }
}

Future<void> captureFormFamily(WidgetTester tester, String name) async {
  if (!_capture) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(formFamilyCapture),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/design-previews/form-actions/site/$name.png');
      file.parent.createSync(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}
