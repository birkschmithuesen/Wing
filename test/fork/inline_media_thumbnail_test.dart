import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/chat_output.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/widgets/chat_image_preview.dart';
import 'package:wing/core/widgets/deliverable_attachment.dart';
import 'package:wing/core/widgets/profile_message.dart';

const reportPath =
    '/home/tarkil/projects/memory-maintenance/evaluation/FULL_BANK_ANALYSIS.md';

/// Tiny 2x2 red PNG, generated with Python's zlib/struct (no network fixture).
final testPngBytes = Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGP4z8AARAwQCgAf7'
    'gP9i18U1AAAAABJRU5ErkJggg==',
  ),
);

/// Scoped to the deliverable: the assistant message header always renders
/// its own `Image` (PlayfulPortrait's avatar), unrelated to any thumbnail.
Finder thumbnailImages() => find.descendant(
  of: find.byType(DeliverableAttachment),
  matching: find.byType(Image),
);

Widget message(
  String text, {
  Future<Uint8List> Function(ChatOutput)? loadImage,
}) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: ProfileMessage(
        message: {'role': 'assistant', 'content': text},
        onLoadRemoteImage: loadImage,
      ),
    ),
  ),
);

void main() {
  setUpAll(() async {
    if (!const bool.fromEnvironment('CAPTURE_DELIVERABLES')) return;
    const directory = String.fromEnvironment('CAPTURE_FONT_DIR');
    for (final entry in {
      'Roboto': 'Roboto-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            File(
              '$directory/${entry.value}',
            ).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
    }
  });

  testWidgets(
    'image deliverable renders an inline thumbnail and tap opens the zoom preview',
    (tester) async {
      const imagePath = '/srv/screenshot.png';
      var loadCalls = 0;
      await tester.pumpWidget(
        message(
          'MEDIA:$imagePath',
          loadImage: (output) async {
            loadCalls++;
            expect(output.path, imagePath);
            return testPngBytes;
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(DeliverableAttachment), findsOneWidget);
      expect(thumbnailImages(), findsOneWidget);
      expect(loadCalls, 1);
      await tester.tap(thumbnailImages());
      await tester.pumpAndSettle();
      expect(find.byType(ChatImagePreview), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'non-image deliverable keeps rendering the existing file card only',
    (tester) async {
      await tester.pumpWidget(
        message('MEDIA:$reportPath', loadImage: (_) async => testPngBytes),
      );
      await tester.pumpAndSettle();
      expect(find.byType(DeliverableAttachment), findsOneWidget);
      expect(thumbnailImages(), findsNothing);
      expect(find.text('FULL_BANK_ANALYSIS.md'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'image deliverable shows the file card while loading and on error',
    (tester) async {
      final pending = Completer<Uint8List>();
      await tester.pumpWidget(
        message('MEDIA:/srv/photo.png', loadImage: (_) => pending.future),
      );
      expect(thumbnailImages(), findsNothing);
      expect(find.text('photo.png'), findsOneWidget);
      pending.completeError(const DashboardHttpException(403, 'fs/download'));
      await tester.pumpAndSettle();
      expect(thumbnailImages(), findsNothing);
      expect(find.text('photo.png'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('loaded image bytes are cached across remounts', (
    tester,
  ) async {
    var loadCalls = 0;
    Future<Uint8List> load(ChatOutput output) async {
      loadCalls++;
      return testPngBytes;
    }

    await tester.pumpWidget(
      message('MEDIA:/srv/cache-test.png', loadImage: load),
    );
    await tester.pumpAndSettle();
    expect(loadCalls, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      message('MEDIA:/srv/cache-test.png', loadImage: load),
    );
    await tester.pumpAndSettle();
    expect(loadCalls, 1);
    expect(thumbnailImages(), findsOneWidget);
  });

  testWidgets('three MEDIA images in one message stack as separate thumbnails', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: boundary,
          child: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: ProfileMessage(
                message: const {
                  'role': 'assistant',
                  'content':
                      'Here are the three captures:\n\n'
                      'MEDIA:/srv/one.png\n\n'
                      'MEDIA:/srv/two.png\n\n'
                      'MEDIA:/srv/three.png',
                },
                onLoadRemoteImage: (output) async => testPngBytes,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(DeliverableAttachment), findsNWidgets(3));
    expect(thumbnailImages(), findsNWidgets(3));
    expect(tester.takeException(), isNull);
    if (const bool.fromEnvironment('CAPTURE_DELIVERABLES')) {
      await tester.runAsync(() async {
        final image =
            await (boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('build/deliverables-review/three-images.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
    }
  });
}
