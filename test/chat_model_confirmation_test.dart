import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/chat_model_confirmation.dart';

import 'support/profile_intelligence_fixture.dart';

const _capture = bool.fromEnvironment('CAPTURE_MODEL_CONFIRMATION');
const _frame = Key('confirmation-frame');

void main() {
  setUpAll(() async {
    if (!_capture) return;
    final font = File('build/studio-roboto.ttf');
    final loader = FontLoader('Roboto')
      ..addFont(Future.value(ByteData.sublistView(font.readAsBytesSync())));
    await loader.load();
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('reachable actions in ${brightness.name} at $scale text', (
        tester,
      ) async {
        final size = scale == 1 ? const Size(390, 844) : const Size(320, 640);
        const keyboard = 240.0;
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.view.viewInsets = const FakeViewPadding(bottom: keyboard);
        addTearDown(tester.view.reset);
        bool? result;
        await tester.pumpWidget(
          RepaintBoundary(
            key: _frame,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: Scaffold(
                body: Builder(
                  builder: (context) => Center(
                    child: TextButton(
                      onPressed: () async {
                        result = await showChatModelConfirmation(
                          context,
                          message: ProfileIntelligenceFixture.modelWarning,
                        );
                      },
                      child: const Text('Change model'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        Future<void> open() async {
          result = null;
          await tester.tap(find.text('Change model'));
          await tester.pumpAndSettle();
        }

        await open();
        for (final label in ['Cancel', 'Switch model']) {
          final button = find.byWidgetPredicate(
            (widget) => widget is IconButton && widget.tooltip == label,
          );
          expect(button.hitTestable(), findsOneWidget);
          final rect = tester.getRect(button);
          expect(rect.bottom, lessThanOrEqualTo(size.height - keyboard));
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(size.width));
          expect(rect.height, greaterThanOrEqualTo(48));
        }
        expect(tester.takeException(), isNull);
        if (_capture) {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(_frame),
          );
          await tester.runAsync(() async {
            final image = await boundary.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final directory = Directory('build/model-confirmation-review')
              ..createSync(recursive: true);
            await File(
              '${directory.path}/${brightness.name}-$scale.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.tap(find.byTooltip('Cancel'));
        await tester.pumpAndSettle();
        expect(result, isFalse);

        await open();
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(result, isFalse);

        await open();
        await tester.tapAt(const Offset(4, 4));
        await tester.pumpAndSettle();
        expect(result, isFalse);

        await open();
        await tester.tap(find.byTooltip('Switch model'));
        await tester.pumpAndSettle();
        expect(result, isTrue);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
