import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/gateway_approval.dart';
import 'package:wing/core/widgets/notification_approval_review.dart';
import 'package:wing/core/widgets/gateway_approval_panel.dart';

const capture = bool.fromEnvironment('CAPTURE_REVIEW');
void main() {
  setUpAll(() async {
    if (!capture) return;
    for (final font in {
      WingTypography.sans: 'Roboto-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(font.key)..addFont(
            File(
              '${const String.fromEnvironment('CAPTURE_FONT_DIR')}/${font.value}',
            ).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
    }
  });
  testWidgets('failed decision keeps review open and retries only explicitly', (
    tester,
  ) async {
    final changes = ChangeNotifier();
    addTearDown(changes.dispose);
    var attempts = 0;
    final gate = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => NotificationApprovalReview(
                request: GatewayApprovalRequest.fromEventData({
                  'command': 'print(1)',
                  'choices': ['once', 'deny'],
                }),
                choice: 'once',
                changes: changes,
                offline: () => false,
                pending: () => true,
                submit: () async {
                  attempts++;
                  if (attempts == 1) {
                    await gate.future;
                    throw StateError('offline');
                  }
                },
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Allow once'));
    await tester.pump();
    expect(find.bySemanticsLabel('Sending approval decision'), findsOneWidget);
    expect(
      find
          .descendant(
            of: find.byType(NotificationApprovalReview),
            matching: find.byType(CircularProgressIndicator),
          )
          .hitTestable(),
      findsOneWidget,
    );
    expect(find.text('Sending decision…'), findsNothing);
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('Review command'), findsOneWidget);
    expect(find.byType(ApprovalCommandDetails), findsOneWidget);
    expect(
      find.text('Decision not confirmed. Check the connection, then retry.'),
      findsOneWidget,
    );
    changes.notifyListeners();
    await tester.pumpAndSettle();
    expect(attempts, 1);
    await tester.tap(find.byTooltip('Allow once'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text('Review command'), findsNothing);
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('scope and controls visible $brightness $scale', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(412, 915);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final changes = ChangeNotifier();
        addTearDown(changes.dispose);
        final frame = GlobalKey();
        var submitted = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: wingTheme(brightness),
            builder: (context, child) => RepaintBoundary(
              key: frame,
              child: MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
            ),
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => NotificationApprovalReview(
                    request: GatewayApprovalRequest.fromEventData({
                      'command': List.filled(
                        30,
                        'print("long test command")',
                      ).join('\n'),
                      'description': 'Backend says this is one-shot.',
                      'choices': ['always', 'deny'],
                    }),
                    choice: 'always',
                    changes: changes,
                    offline: () => false,
                    pending: () => true,
                    submit: () async {
                      submitted++;
                    },
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(
          find.text(
            'Permanently allow matching commands, including in future chats.',
          ),
          findsOneWidget,
        );
        expect(find.text('Backend says this is one-shot.'), findsNothing);
        expect(
          find
              .text(
                'Permanently allow matching commands, including in future chats.',
              )
              .hitTestable(),
          findsOneWidget,
        );
        expect(find.byTooltip('Always allow').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (capture) {
          await tester.runAsync(() async {
            final boundary =
                frame.currentContext!.findRenderObject()
                    as RenderRepaintBoundary;
            final image = await boundary.toImage(pixelRatio: 1);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              'build/design-previews/approval-review/notification-${brightness.name}-$scale.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.tap(find.byTooltip('Always allow'));
        await tester.pumpAndSettle();
        expect(submitted, 1);
        expect(find.byType(NotificationApprovalReview), findsNothing);
      });
    }
  }
}
