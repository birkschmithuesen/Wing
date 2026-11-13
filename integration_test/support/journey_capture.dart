import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const journeyTheme = String.fromEnvironment(
  'JOURNEY_THEME',
  defaultValue: 'light',
);

Widget journeyCaptureBoundary(Widget child) =>
    RepaintBoundary(key: const ValueKey('journey-capture'), child: child);

/// Export requested Android Flutter frames, including automatic failure evidence.
Future<void> captureJourney(
  WidgetTester tester,
  String name, {
  bool failure = false,
}) async {
  if (!failure && !const bool.fromEnvironment('CAPTURE_JOURNEYS')) return;
  final context = tester.element(find.byKey(const ValueKey('journey-capture')));
  final images = tester.widgetList<Image>(find.byType(Image)).toList();
  if (!failure) {
    await tester.runAsync(() async {
      await Future.wait(
        images.map((widget) => precacheImage(widget.image, context)),
      );
    });
  }
  await tester.pump();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('journey-capture')),
  );
  final image = await boundary.toImage(pixelRatio: 1.5);
  try {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File(
      '${Directory.systemTemp.path}/wing-journey-$journeyTheme-$name.png',
    );
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    debugPrint('Journey frame: ${file.path}');
  } finally {
    image.dispose();
  }
}

/// Preserve the failing Flutter frame before widget teardown replaces the route.
/// Capture errors never replace the original test failure.
void testJourney(String description, WidgetTesterCallback callback) {
  testWidgets(description, (tester) async {
    try {
      await callback(tester);
      final exception = tester.takeException();
      if (exception != null) throw exception;
    } catch (error, stack) {
      debugPrint(
        'Journey failure: $description; '
        'viewport=${tester.view.physicalSize / tester.view.devicePixelRatio}; '
        'keyboardInset=${tester.view.viewInsets.bottom / tester.view.devicePixelRatio}; '
        'focus=${tester.binding.focusManager.primaryFocus?.debugLabel}',
      );
      try {
        await captureJourney(
          tester,
          'failure-${description.replaceAll(RegExp(r"[^a-zA-Z0-9]+"), "-")}',
          failure: true,
        );
      } catch (captureError) {
        debugPrint('Journey failure capture failed: $captureError');
      }
      Error.throwWithStackTrace(error, stack);
    }
  });
}
