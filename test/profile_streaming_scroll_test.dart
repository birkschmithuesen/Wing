import 'package:wing/core/models/transcript_presentation.dart';
import 'package:wing/core/models/transcript_timeline.dart';
import 'package:wing/core/models/transcript_reading.dart';
import 'support/composer_fixture.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/screens/profile_transcript.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/profile_message.dart';

import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'helpers/pump_markdown_widget.dart';
import 'support/profile_history_fixture.dart';

void main({Future<void> Function(WidgetTester, String)? captureFrame}) {
  const capture = bool.fromEnvironment('CAPTURE_STREAMING_SCROLL');
  setUpAll(() async {
    if (!capture) return;
    const root = String.fromEnvironment('CAPTURE_FONT_DIR');
    for (final font in {
      'Roboto': 'Roboto-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(font.key)..addFont(
            File(
              '$root/${font.value}',
            ).readAsBytes().then((bytes) => bytes.buffer.asByteData()),
          ))
          .load();
    }
  });

  Future<void> snapshot(WidgetTester tester, String name) async {
    if (captureFrame != null) await captureFrame(tester, name);
    if (!capture) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('capture')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/streaming-scroll/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      for (final unseenFinalText in [false, true]) {
        testWidgets('streaming Markdown reading ${brightness.name} $scale '
            'unseen final text=$unseenFinalText', (tester) async {
          if (tester.binding is AutomatedTestWidgetsFlutterBinding) {
            tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
          }
          SharedPreferences.setMockInitialValues({});
          final fixture = ProfileHistoryFixture();
          final preferences = await SharedPreferences.getInstance();
          final appPreferences = AppPreferences(preferences);
          addTearDown(appPreferences.dispose);
          final controller = ProfileWorkspaceController(
            access: ConnectionAccess(
              connection: identityTestConnection(),
              dashboardOAuth: null,
            ),
            connectionIdentity: 'streaming-scroll',
            preferences: preferences,
            appPreferences: appPreferences,
            gatewayFactory: fixture.gateway,
          );
          addTearDown(controller.dispose);
          await controller.initialize();
          final chat = await openFixtureChat(
            controller: controller,
            key: ProfileSessionKey(controller.current!.scope, 'chat-0'),
            title: 'Streaming answer',
          );

          // This render fixture owns a complete synthetic transcript. Adopt it
          // as a passive snapshot instead of retaining the gateway page cursor.
          chat.reading.installSnapshot(
            TranscriptReadingSnapshot(
              historySessionId: chat.reading.historySessionId,
              messages: [
                {'id': 1, 'role': 'user', 'content': 'Explain how this works.'},
              ],
            ),
          );
          chat.reading.updateStreaming(
            List.generate(
              40,
              (i) => 'Paragraph $i: You can read this answer at your own pace.',
            ).join('\n\n'),
          );
          await tester.pumpWidget(
            MaterialApp(
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: RepaintBoundary(
                key: const ValueKey('capture'),
                child: Scaffold(
                  body: ListenableBuilder(
                    listenable: controller,
                    builder: (_, _) => ProfileTranscript(
                      presentation: TranscriptPresentation.capture(
                        identity: chat.key,
                        reader: chat.reading,
                        timeline: TranscriptTimeline.project(
                          [
                            ...chat.reading.messages,
                            ?chat.reading.streamingMessage,
                          ],
                          presentationId: chat.reading.messagePresentationId,
                          liveMessageIndex:
                              chat.reading.streamingMessage == null
                              ? null
                              : chat.reading.messages.length,
                        ),
                        needsInput: chat.runtime.needsInput,
                        turnAdmissionBlocked: chat.runtime.blocksTurnAdmission,
                      ),
                      openingContent: chat.runtime.opening
                          ? ProfileTranscriptOpening(
                              status: controller.connectionStatus,
                              error: chat.runtime.openingError,
                              onRetry: controller.resumeConnection,
                            )
                          : null,
                      notificationReading: chat.reading,
                      onAnswerRead: (target) =>
                          controller.notificationAnswerRead(chat, target),
                      onRefreshHistory: () => controller.refreshHistory(chat),
                      onLoadOlder: () => controller.loadOlderMessages(chat),
                      messageBuilder: (message) =>
                          ProfileMessage(message: message.message),

                      tail: const [],
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.settleMarkdown();
          final list = find.byKey(const ValueKey('profile-transcript'));
          final scroll = tester.widget<ListView>(list).controller!;
          // With no user scrolling, every update stays at the bottom and its
          // newest text is visible, including when the answer exceeds the screen.
          for (var update = 0; update < 5; update++) {
            chat.reading.appendStreaming('\n\nLive update $update');
            tester
                .element(
                  find
                      .ancestor(
                        of: find.byType(ProfileTranscript),
                        matching: find.byType(ListenableBuilder),
                      )
                      .first,
                )
                .markNeedsBuild();
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 16));
            await tester.settleMarkdown();
            expect(scroll.offset, closeTo(0, 1));
            expect(
              find
                  .text('Live update $update', findRichText: true)
                  .hitTestable(),
              findsOneWidget,
            );
            expect(find.byKey(const ValueKey('jump-to-latest')), findsNothing);
          }
          await snapshot(tester, '${brightness.name}-$scale-following');
          // Read near the beginning; at enlarged text the saved row is offscreen
          // and the streaming message itself must provide the anchor.
          final marker = find.textContaining(
            'Paragraph 4:',
            findRichText: true,
          );
          await Scrollable.ensureVisible(
            tester.element(marker),
            alignment: 0.3,
          );
          await tester.pumpAndSettle();
          final before = tester.getTopLeft(marker).dy;
          await snapshot(tester, '${brightness.name}-$scale-before');
          for (var update = 0; update < 4; update++) {
            chat.reading.appendStreaming(
              '\n\nMore text is arriving at the bottom. ' * 3,
            );
            tester
                .element(
                  find
                      .ancestor(
                        of: find.byType(ProfileTranscript),
                        matching: find.byType(ListenableBuilder),
                      )
                      .first,
                )
                .markNeedsBuild();
            await tester.pump();
            expect(tester.getTopLeft(marker).dy, closeTo(before, 1));
            await tester.pump(const Duration(milliseconds: 16));
            expect(tester.getTopLeft(marker).dy, closeTo(before, 1));
            await tester.settleMarkdown();
            expect(tester.getTopLeft(marker).dy, closeTo(before, 1));
            expect(tester.takeException(), isNull);
          }
          await snapshot(tester, '${brightness.name}-$scale-after');
          final finalParagraphs = unseenFinalText
              ? List.generate(
                  6,
                  (index) =>
                      'Final unseen paragraph $index: '
                      'Completion can include text that was never published live.',
                )
              : <String>[];
          // No intermediate pump: the saved source is newer than the last
          // completed live snapshot, so its first frame must use the ready prefix.
          if (finalParagraphs.isNotEmpty) {
            chat.reading.appendStreaming('\n\n${finalParagraphs.join('\n\n')}');
          }
          final finalSource = chat.reading.streaming;
          chat.reading.installSavedHistory([
            ...chat.reading.messages,
            {'id': 2, 'role': 'assistant', 'content': chat.reading.streaming},
          ]);
          chat.reading.updateStreaming('');
          tester
              .element(
                find
                    .ancestor(
                      of: find.byType(ProfileTranscript),
                      matching: find.byType(ListenableBuilder),
                    )
                    .first,
              )
              .markNeedsBuild();
          await tester.pump();
          expect(tester.getTopLeft(marker).dy, closeTo(before, 1));
          await tester.settleMarkdown();
          expect(tester.getTopLeft(marker).dy, closeTo(before, 1));
          expect(
            tester
                .widgetList<MarkdownBody>(find.bySubtype<MarkdownBody>())
                .any((body) => body.data == finalSource),
            isTrue,
          );
          for (final paragraph in finalParagraphs) {
            expect(find.text(paragraph, findRichText: true), findsOneWidget);
          }
          await tester.pumpAndSettle();
          await tester.settleMarkdown();
          expect(tester.getTopLeft(marker).dy, closeTo(before, 1));
          await tester.tap(find.byKey(const ValueKey('jump-to-latest')));
          await tester.pumpAndSettle();
          expect(scroll.offset, closeTo(0, 1));
          chat.reading.updateStreaming(
            'Following resumes after returning to Latest.',
          );
          tester
              .element(
                find
                    .ancestor(
                      of: find.byType(ProfileTranscript),
                      matching: find.byType(ListenableBuilder),
                    )
                    .first,
              )
              .markNeedsBuild();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 16));
          await tester.settleMarkdown();
          expect(scroll.offset, closeTo(0, 1));
          expect(
            find.text(chat.reading.streaming, findRichText: true).hitTestable(),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
