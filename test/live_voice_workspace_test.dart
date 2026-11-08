import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/app_preferences.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/live_voice_session.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/live_voice_scope.dart';

import 'support/profile_browser_fixture.dart';
import 'helpers/pump_markdown_widget.dart';
import 'package:wing/core/widgets/profile_message.dart';
import 'package:wing/core/models/transcript_message.dart';
import 'support/live_voice_fixture.dart';
import 'support/voice_fixture.dart';

// Only the vendor handshake is supplied; Start and chat ownership are production.
class _UiVoiceSession extends LiveVoiceSession {
  _UiVoiceSession(this.transport, this.service)
    : super(createTransport: () => transport, background: service);
  final VoiceTransportFixture transport;
  final VoiceBackgroundFixture service;
  final handshake = Completer<Map<String, dynamic>>();
  @override
  Future<void> start(
    LiveVoiceConversation conversation, {
    Future<void> Function()? prepare,
  }) => super.start(
    _UiConversation(conversation, handshake.future),
    prepare: prepare,
  );
}

class _UiConversation implements LiveVoiceConversation {
  _UiConversation(this.owner, this.handshake);
  final LiveVoiceConversation owner;
  final Future<Map<String, dynamic>> handshake;
  @override
  ProfileSessionKey get key => owner.key;
  @override
  LiveVoiceMode get mode => owner.mode;
  @override
  String get title => owner.title;
  @override
  String get context => owner.context;
  @override
  String get workStatus => owner.workStatus;
  @override
  bool get available => owner.available;
  @override
  Map<String, String> get completedReplies => owner.completedReplies;
  @override
  Future<Map<String, dynamic>> negotiate(String offer) => handshake;
  @override
  Future<String> delegate(
    String action,
    String text, {
    String voiceContext = '',
    required String delegationId,
  }) => owner.delegate(
    action,
    text,
    voiceContext: voiceContext,
    delegationId: delegationId,
  );
  @override
  void addListener(VoidCallback listener) => owner.addListener(listener);
  @override
  void removeListener(VoidCallback listener) => owner.removeListener(listener);
  @override
  void release() => owner.release();
}

class _VoiceHistoryFixture extends ProfileBrowserFixture {
  final rows = <Map<String, dynamic>>[];
  @override
  List<Map<String, dynamic>> historyRows(String profile, String id) =>
      id == 'newest' ? rows : [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const capture = bool.fromEnvironment('LIVE_VOICE_REVIEW');
  const frame = Key('live-voice-frame');
  setUpAll(() async {
    if (!capture) return;
    for (final entry in {
      'Roboto': 'build/studio-roboto.ttf',
      'MaterialIcons': 'build/studio-icons.otf',
      'WingIcons': 'assets/fonts/wing-icons.ttf',
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            Future.value(
              ByteData.sublistView(File(entry.value).readAsBytesSync()),
            ),
          ))
          .load();
    }
  });
  Future<void> screenshot(WidgetTester tester, String name) async {
    if (!capture) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(frame),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/feature-verification/live-voice/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      for (final fail in [false, true]) {
        testWidgets(
          'live voice ${fail ? "failure" : "controls"} remains usable in $brightness at $scale text',
          (tester) async {
            SharedPreferences.setMockInitialValues({});
            final preferences = AppPreferences(
              await SharedPreferences.getInstance(),
            );
            final gateway = _VoiceHistoryFixture();
            final controller = ProfileWorkspaceController(
              access: ConnectionAccess(
                connection: SavedConnection(
                  id: 'voice',
                  label: 'Hermes',
                  host: 'localhost',
                  port: 1,
                  apiKey: '',
                ),
                dashboardOAuth: null,
              ),
              connectionIdentity: 'voice',
              preferences: await SharedPreferences.getInstance(),
              appPreferences: preferences,
              gatewayFactory: gateway.gateway,
            );
            final device = VoiceDeviceFixture(),
                transport = VoiceTransportFixture(),
                background = VoiceBackgroundFixture();
            final session = _UiVoiceSession(transport, background);
            await controller.initialize();
            await controller.openSession(
              ProfileSessionKey(controller.current!.scope, 'newest'),
            );
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = const Size(390, 844);
            addTearDown(tester.view.reset);
            try {
              await tester.pumpWidget(
                MaterialApp(
                  theme: wingTheme(brightness),
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(textScaler: TextScaler.linear(scale)),
                    child: LiveVoiceScope(
                      session: session,
                      openChat: (_) async {},
                      child: RepaintBoundary(
                        key: frame,
                        child: LiveVoiceLayout(child: child!),
                      ),
                    ),
                  ),
                  home: ProfileWorkspaceScreen(
                    controller: controller,
                    voiceDevice: device,
                    createBotsSession: () => BotsSession((_) async => []),
                  ),
                ),
              );
              await tester.pumpAndSettle();
              await tester.tap(find.byTooltip('Start voice conversation'));
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 100));
              expect(find.text('Connecting voice…'), findsOneWidget);
              expect(session.phase, LiveVoicePhase.connecting);
              await screenshot(tester, '${brightness.name}-$scale-connecting');
              if (fail) {
                const message =
                    'The Wing plugin is not installed or enabled on this Hermes profile. Install and enable it for subscription voice.';
                session.handshake.completeError(
                  const LiveVoiceStartException(message),
                );
                await tester.pump();
                await tester.pump(const Duration(milliseconds: 100));
                expect(find.text(message), findsOneWidget);
                expect(session.active, isFalse);
                expect(transport.closed, isTrue);
                expect(background.running, isFalse);
                await screenshot(
                  tester,
                  '${brightness.name}-$scale-missing-plugin',
                );
                expect(tester.takeException(), isNull);
                final errorScroll = find.ancestor(
                  of: find.text(message),
                  matching: find.byType(SingleChildScrollView),
                );
                await tester.drag(errorScroll, const Offset(0, -1000));
                await tester.pump();
                final errorViewport = tester.state<ScrollableState>(
                  find.descendant(
                    of: errorScroll,
                    matching: find.byType(Scrollable),
                  ),
                );
                expect(errorViewport.position.extentAfter, 0);
                expect(
                  find.byTooltip('Dismiss voice error').hitTestable(),
                  findsOneWidget,
                );
                await screenshot(
                  tester,
                  '${brightness.name}-$scale-error-scrolled',
                );
                await tester.tap(find.byTooltip('Dismiss voice error'));
                await tester.pump();
                expect(find.text(message), findsNothing);
                expect(
                  find.byTooltip('Start voice conversation'),
                  findsOneWidget,
                );
                await tester.pumpWidget(const SizedBox());
                return;
              }
              session.handshake.complete({
                'contractVersion': 2,
                'mode': 'subscription',
                'protocol': 'codex-live-v3',
                'handoff': 'client',
                'answer': 'SDP',
              });
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 100));
              expect(session.phase, LiveVoicePhase.listening);
              await tester.tap(find.byTooltip('Mute voice'));
              await tester.pump();
              expect(session.muted, isTrue);
              expect(transport.isMuted, isTrue);
              transport.event({
                'type': 'turn.done',
                'turn': {
                  'id': 'spoken-user',
                  'role': 'user',
                  'transcript': 'What is my name?',
                },
              });
              await tester.pump();
              await tester.settleTranscript();
              expect(
                find.text('You · voice · Not saved to Hermes'),
                findsOneWidget,
              );
              expect(find.text('What is my name?'), findsOneWidget);
              expect(
                gateway.calls.where((call) => call.$2 == 'session.submit'),
                isEmpty,
              );
              await screenshot(tester, '${brightness.name}-$scale-spoken-user');
              await tester.tap(find.byTooltip('Show voice captions'));
              transport.event({
                'type': 'output_transcript.added',
                'item': {'text': 'Your name is Robert.'},
              });
              transport.event({
                'type': 'turn.done',
                'turn': {
                  'id': 'spoken-answer',
                  'role': 'assistant',
                  'transcript': 'Your name is Robert.',
                },
              });
              await tester.pump();
              await tester.settleTranscript();
              await screenshot(tester, '${brightness.name}-$scale-muted');
              expect(tester.takeException(), isNull);
              tester.view.viewInsets = const FakeViewPadding(bottom: 300);
              await tester.pump();
              expect(
                tester.getBottomRight(find.byTooltip('End voice')).dy,
                lessThanOrEqualTo(544),
                reason: 'Call controls stay above the typing keyboard',
              );
              expect(
                find
                    .byWidgetPredicate(
                      (widget) => widget is EditableText && !widget.readOnly,
                    )
                    .hitTestable(),
                findsOneWidget,
              );
              await screenshot(tester, '${brightness.name}-$scale-keyboard');
              expect(tester.takeException(), isNull);
              transport.event({
                'type': 'error',
                'error': {'code': 'invalid_value'},
              });
              await tester.pump();
              expect(session.active, isTrue);
              expect(
                find.text(
                  'Voice rejected an update. The call is still connected; check the chat for task results.',
                ),
                findsOneWidget,
              );
              tester.view.viewInsets = FakeViewPadding.zero;
              await tester.pump();
              await screenshot(
                tester,
                '${brightness.name}-$scale-command-rejected',
              );
              await tester.tap(find.byTooltip('Dismiss voice error'));
              await tester.pump();
              transport.event({
                'type': 'session.closed',
                'reason': 'connection_lost',
              });
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 100));
              expect(session.active, isFalse);
              expect(transport.closed, isTrue);
              expect(background.running, isFalse);
              expect(
                find.text(
                  'Voice lost its connection. Start a new call to reconnect.',
                ),
                findsOneWidget,
              );
              await tester.settleTranscript();
              final spoken = find.byWidgetPredicate(
                (widget) =>
                    widget is ProfileMessage &&
                    widget.message.kind == TranscriptMessageKind.voice &&
                    widget.message.role == 'assistant',
              );
              expect(spoken, findsOneWidget);
              expect(
                tester.widget<ProfileMessage>(spoken).message.text,
                'Your name is Robert.',
              );
              expect(
                tester.widget<ProfileMessage>(spoken).message.streaming,
                isFalse,
              );
              await tester.ensureVisible(spoken);
              await tester.pump(const Duration(milliseconds: 300));
              await tester.settleTranscript();
              expect(
                find.text('GPT-Live · Not saved to Hermes'),
                findsOneWidget,
              );
              final copy = find.descendant(
                of: spoken,
                matching: find.byTooltip('Copy message'),
              );
              expect(copy, findsOneWidget);
              await tester.tap(copy);
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 100));
              expect(
                find.descendant(
                  of: spoken,
                  matching: find.byTooltip('Edit message'),
                ),
                findsNothing,
              );
              expect(
                find.descendant(
                  of: spoken,
                  matching: find.byTooltip('Restore checkpoint'),
                ),
                findsNothing,
              );
              await screenshot(
                tester,
                '${brightness.name}-$scale-disconnected',
              );
              final original = controller.current!.chat!.key;
              await tester.runAsync(
                () => controller.openSession(
                  ProfileSessionKey(original.workspace, 'old'),
                ),
              );
              await tester.pump();
              await tester.settleTranscript();
              expect(
                find.byWidgetPredicate(
                  (widget) =>
                      widget is ProfileMessage &&
                      widget.message.kind == TranscriptMessageKind.voice,
                ),
                findsNothing,
              );
              await tester.runAsync(() => controller.openSession(original));
              await tester.pump();
              await tester.settleTranscript();
              expect(
                find.byWidgetPredicate(
                  (widget) =>
                      widget is ProfileMessage &&
                      widget.message.kind == TranscriptMessageKind.voice &&
                      widget.message.text == 'Your name is Robert.',
                ),
                findsOneWidget,
              );

              // A voice task can finish after hangup. Its native reply remains
              // inspectable, while the actual spoken answer stays the dialogue.
              await tester.tap(find.byTooltip('Dismiss voice error'));
              await tester.pump();
              final chat = controller.current!.chat!;
              tester.view.physicalSize = Size(scale == 2 ? 320 : 390, 844);
              const submission = 'spoken-task-submission';
              chat.reading.registerVoiceSubmission(submission);
              final timestamp = DateTime.now().millisecondsSinceEpoch / 1000;
              gateway.rows.addAll([
                {
                  'id': 101,
                  'role': 'user',
                  'content': 'Look it up',
                  'timestamp': timestamp,
                  'display_metadata': {'submission_id': submission},
                },
                {
                  'id': 102,
                  'role': 'assistant',
                  'content': 'Internal lookup result for the voice agent.',
                  'timestamp': timestamp + 0.01,
                },
              ]);
              chat.reading.observeVoiceCompletion({
                'text': null,
                'persisted_turn': {
                  'complete': true,
                  'row_ids': [101, 102],
                  'final_assistant_row_id': 102,
                  'submission_id': submission,
                },
              });
              await tester.pump();
              await tester.runAsync(() => controller.refreshHistory(chat));
              await tester.pump();
              await tester.settleTranscript();
              expect(
                find.text('Internal lookup result for the voice agent.'),
                findsNothing,
              );
              expect(chat.reading.messages.map((r) => r['id']), contains(102));
              expect(
                chat.reading.isVoiceTaskReply(chat.reading.messages.last),
                isTrue,
              );
              await tester.tap(find.byKey(const ValueKey('jump-to-latest')));
              await tester.pump(const Duration(milliseconds: 300));
              await tester.settleTranscript();
              final details = find.text('Hermes task details');
              expect(details, findsOneWidget);
              await tester.ensureVisible(details);
              await tester.pump(const Duration(milliseconds: 300));
              await screenshot(
                tester,
                '${brightness.name}-$scale-task-collapsed',
              );
              await tester.tap(details);
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 300));
              await tester.settleTranscript();
              final latest = find.byKey(const ValueKey('jump-to-latest'));
              if (latest.evaluate().isNotEmpty) {
                await tester.tap(latest);
                await tester.pump();
                await tester.pump(const Duration(milliseconds: 300));
                await tester.settleTranscript();
              }
              expect(
                find.text('Internal lookup result for the voice agent.'),
                findsOneWidget,
              );
              await screenshot(
                tester,
                '${brightness.name}-$scale-task-expanded',
              );
              expect(tester.takeException(), isNull);
              final nativeReply = find.byWidgetPredicate(
                (widget) =>
                    widget is ProfileMessage &&
                    widget.message.text ==
                        'Internal lookup result for the voice agent.',
              );
              expect(
                find.descendant(
                  of: nativeReply,
                  matching: find.byTooltip('Copy message'),
                ),
                findsOneWidget,
              );
              final disclosure = find.ancestor(
                of: details,
                matching: find.byType(ExpansionTile),
              );
              final chevron = find.descendant(
                of: disclosure,
                matching: find.byIcon(Icons.expand_more),
              );
              await tester.ensureVisible(chevron);
              await tester.pump();
              await tester.tap(chevron);
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 300));
              expect(
                find.text('Internal lookup result for the voice agent.'),
                findsNothing,
              );
              expect(
                gateway.calls.where((call) => call.$2 == 'session.interrupt'),
                isEmpty,
              );
              await tester.pumpWidget(const SizedBox());
            } finally {
              await tester.pumpWidget(const SizedBox.shrink());
              final ending = session.end();
              if (!session.handshake.isCompleted) {
                session.handshake.complete(const {});
              }
              await ending;
              session.dispose();
              controller.dispose();
              preferences.dispose();
              await device.stream.close();
            }
          },
        );
      }
    }
  }
}
