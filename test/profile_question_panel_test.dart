import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/gateway_clarify.dart';
import 'package:wing/core/widgets/gateway_clarify_dialog.dart';
import 'package:wing/core/theme/profile_workspace_theme.dart';

Widget panel(
  Future<void> Function(String) respond, {
  bool multiple = false,
  double scale = 1,
  Brightness brightness = Brightness.light,
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: profileWorkspaceTheme(ThemeData(brightness: brightness)),
  home: MediaQuery(
    data: MediaQueryData(
      size: const Size(360, 800),
      textScaler: TextScaler.linear(scale),
    ),
    child: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: GatewayClarifyDialog(
          requests: [
            GatewayClarifyRequest(
              requestId: 'test',
              questionId: 'q1',
              question:
                  'Which review should I run?\n\nChoose the **level of detail** for the design and copy review.',
              choices: const [
                'Detailed review, including layout and copy',
                'Quick review of the main issues',
              ],
              multiSelect: multiple,
            ),
          ],
          onRespond: (answers) => respond(answers.values.single ?? ''),
          onSkip: () => respond(''),
        ),
      ),
    ),
  ),
);

void main() {
  if (const bool.fromEnvironment('QUESTION_PREVIEW')) {
    setUpAll(() async {
      const root = String.fromEnvironment('PREVIEW_FONT_ROOT');
      final font = FontLoader('Roboto')
        ..addFont(
          File(
            '$root/roboto-regular.ttf',
          ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
        );
      await font.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(
          File(
            '$root/MaterialIcons-Regular.otf',
          ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
        );
      await icons.load();
    });
    for (final brightness in Brightness.values) {
      testWidgets('authored question preview $brightness', (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(panel((_) async {}, brightness: brightness));
        await tester.tap(find.byKey(const Key('clarify-choice-0')));
        await tester.pumpAndSettle();
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
            Uri.file(
              '${Directory.current.path}/build/question-${brightness.name}.png',
            ),
          ),
        );
      });
    }
  }
  testWidgets(
    'inline multi-select keeps drafts on failure and blocks duplicate sends',
    (tester) async {
      final pending = Completer<void>();
      final answers = <String>[];
      await tester.pumpWidget(
        panel((answer) {
          answers.add(answer);
          return pending.future;
        }, multiple: true),
      );
      await tester.tap(find.byKey(const Key('clarify-choice-1')));
      await tester.tap(find.byKey(const Key('clarify-choice-0')));
      await tester.enterText(
        find.byKey(const Key('clarify-other-field')),
        'Also check accessibility',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('clarify-continue')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('clarify-continue')));
      expect(answers, [
        'Detailed review, including layout and copy, Quick review of the main issues, Also check accessibility',
      ]);
      pending.completeError(Exception('private transport detail'));
      await tester.pump();
      expect(find.text('Send failed. Try again.'), findsOneWidget);
      expect(find.text('Also check accessibility'), findsOneWidget);
      expect(find.textContaining('private transport detail'), findsNothing);
    },
  );

  testWidgets('inline skip sends an empty answer without popping the screen', (
    tester,
  ) async {
    String? answer;
    await tester.pumpWidget(
      panel((value) async {
        answer = value;
      }),
    );
    await tester.tap(find.byKey(const Key('clarify-skip')));
    await tester.pump();
    expect(answer, '');
    expect(find.text('Your input'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('clarify-skip')))
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    testWidgets('narrow $brightness question supports large text', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        panel((_) async {}, scale: 1.6, brightness: brightness),
      );
      await tester.ensureVisible(find.byKey(const Key('clarify-continue')));
      expect(tester.takeException(), isNull);
      expect(find.text('Your input'), findsOneWidget);
    });
  }
}
