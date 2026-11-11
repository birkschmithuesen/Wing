import 'package:wing/core/widgets/profile_queued_messages.dart';
import 'package:wing/core/models/transcript_message.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'support/canonical_gateway_fixture.dart';
import 'package:wing/core/widgets/profile_message.dart';
import 'package:wing/core/services/ws_client.dart';
import 'helpers/pump_markdown_widget.dart';
import 'package:wing/core/models/app_preferences.dart';
import 'package:wing/core/models/chat_runtime.dart';
import 'support/composer_fixture.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image/image.dart' as raster;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/attachment_draft.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/models/queued_prompt_draft.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'support/profile_actions_fixture.dart';
import 'package:wing/core/models/composer_action.dart';
import 'package:wing/core/widgets/composer_action_button.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/theme/wing_icons.dart';

class _ComposerActionsFixture extends ProfileActionsFixture {
  final steerRequests = <Map<String, dynamic>>[];
  Map<String, dynamic> steerResult = {'status': 'queued'};
  Completer<Map<String, dynamic>>? steerReply;
  Completer<Map<String, dynamic>>? submitReply;
  Map<String, dynamic>? heldSubmission;
  bool stalePostSubmitResume = false;
  int postSubmitResumes = 0;
  List<Map<String, dynamic>> transcript = [];

  @override
  List<Map<String, dynamic>> historyRows(String profile, String id) =>
      transcript;

  @override
  ProfileGateway gateway(WorkspaceScope scope) {
    final base = super.gateway(scope);
    return ProfileGateway(
      scope: scope,
      discover: base.discover,
      get: base.read,
      rpc: (method, params) => switch (method) {
        'session.resume' when stalePostSubmitResume && heldSubmission != null =>
          () async {
            postSubmitResumes++;
            return {
              ...await base.call(method, params),
              // Same owner, but a snapshot taken before the live start event.
              'session_id': params['session_id'],
            };
          }(),
        'prompt.submit' when submitReply != null => () {
          heldSubmission = Map.of(params);
          calls.add((scope.profileName, method, Map.of(params)));
          return submitReply!.future;
        }(),
        'session.interrupt' => () async {
          expect(params['execution_generation'], isA<int>());
          calls.add((scope.profileName, method, Map.of(params)));
          return {
            'ref': {
              'profile_id': '/fixture/${scope.profileName}',
              'session_id': params['session_id'],
            },
            'authority_epoch': 1,
            'revision': 0,
            'execution_generation': params['execution_generation'],
            'execution_state': 'idle',
          };
        }(),
        'session.steer' => () {
          steerRequests.add(Map.of(params));
          return steerReply?.future ?? Future.value(steerResult);
        }(),
        'commands.catalog' => Future.value({
          'pairs': [
            ['/steer', 'Steer the current turn'],
          ],
        }),
        _ => base.call(method, params),
      },
    );
  }
}

void main() {
  late _ComposerActionsFixture fixture;
  late ProfileWorkspaceController controller;
  late AppPreferences appPreferences;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    fixture = _ComposerActionsFixture();
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: identityTestConnection(),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'composer-actions',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: fixture.gateway,
    );
    await controller.initialize();
  });

  tearDown(() {
    controller.dispose();
    appPreferences.dispose();
  });

  Future<void> pumpFrames(WidgetTester tester, {int count = 8}) async {
    for (var i = 0; i < count; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> expandQueue(WidgetTester tester) async {
    final header = find.textContaining(RegExp(r'^\d+ queued$'));
    if (header.evaluate().isEmpty) return;
    if (!ExpansibleController.of(tester.element(header)).isExpanded) {
      await tester.ensureVisible(header);
      await pumpFrames(tester, count: 2);
      await tester.tap(header);
      await pumpFrames(tester, count: 4);
    }
  }

  Future<void> choose(WidgetTester tester, String action) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ComposerActionButton)),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(
      tester.getCenter(find.byKey(ValueKey('composer-choice-$action'))),
    );
    await tester.pump();
    await gesture.up();
    await pumpFrames(tester, count: 4);
    if (action == 'queue') await expandQueue(tester);
  }

  Future<ProfileChat> show(
    WidgetTester tester, {
    double scale = 1,
    Brightness brightness = Brightness.light,
    ChatExecution status = ChatExecution.idle,
    String draft = '',
    List<String> queued = const [],
    List<AttachmentDraft> attachments = const [],
    bool paused = false,
    bool disconnected = false,
  }) async {
    final chat = await controller.createChat(canDispatch: () => true);
    if (status == ChatExecution.running) {
      emitChatEvent(controller, chat, 'message.start');
    } else if (status != ChatExecution.idle) {
      throw StateError('Unsupported render fixture state');
    }
    await tester.runAsync(
      () => restoreComposerFixture(
        chat: chat,
        preferences: controller.preferences,
        text: draft,
        attachments: attachments,
        queuedPrompts: queued.map((text) => QueuedPromptDraft(text: text)),
        paused: paused,
      ),
    );
    tester.view.physicalSize = const Size(360, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    if (const bool.fromEnvironment('CAPTURE_COMPOSER')) {
      await tester.runAsync(() async {
        const fonts = String.fromEnvironment('CAPTURE_FONT_DIR');
        for (final font in {
          'Roboto': 'Roboto-Regular.ttf',
          'MaterialIcons': 'MaterialIcons-Regular.otf',
        }.entries) {
          final loader = FontLoader(font.key)
            ..addFont(
              File(
                '$fonts/${font.value}',
              ).readAsBytes().then((bytes) => bytes.buffer.asByteData()),
            );
          await loader.load();
        }
        await (FontLoader('WingProjectIcons')..addFont(
              File(
                'assets/fonts/codicons.ttf',
              ).readAsBytes().then(ByteData.sublistView),
            ))
            .load();
        await (FontLoader('WingIcons')..addFont(
              File(
                'assets/fonts/wing-icons.ttf',
              ).readAsBytes().then(ByteData.sublistView),
            ))
            .load();
      });
    }
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('composer-preview'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: wingTheme(brightness),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: ProfileWorkspaceScreen(
            controller: controller,
            createBotsSession: () => BotsSession((_) async => []),
          ),
        ),
      ),
    );
    await pumpFrames(tester);
    if (disconnected) {
      controller.connectionStatus.liveChanged(
        chat.key.workspace.profileName,
        false,
      );
      await pumpFrames(tester, count: 4);
    }
    if (queued.isNotEmpty) await expandQueue(tester);
    return chat;
  }

  Future<void> capture(WidgetTester tester, String name) async {
    if (!const bool.fromEnvironment('CAPTURE_COMPOSER')) return;
    final previousShadows = debugDisableShadows;
    void repaintShadows() {
      for (final renderObject in tester.allRenderObjects) {
        if (renderObject is RenderPhysicalModel ||
            renderObject is RenderPhysicalShape) {
          renderObject.markNeedsPaint();
        }
      }
    }

    debugDisableShadows = false;
    repaintShadows();
    await tester.pump();
    try {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('composer-preview')),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory('build/composer-transitions').create(recursive: true);
        await File(
          'build/composer-transitions/$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    } finally {
      debugDisableShadows = previousShadows;
      repaintShadows();
      await tester.pump();
    }
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('queue starts compact and opens exact message details '
          '${brightness.name} $scale', (tester) async {
        final text =
            '[IMPORTANT: Background process matched watch pattern READY.]\n'
            'Command: python3 worker.py\nOutput: \n  exact trailing spaces  \n'
            '${List.generate(40, (i) => 'Detail line $i\n').join()}';
        final chat = await show(
          tester,
          brightness: brightness,
          scale: scale,
          status: ChatExecution.running,
          draft: 'Separate draft',
        );
        tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 800);
        await pumpFrames(tester, count: 2);
        final gateway = controller.current!.gateway;
        gateway.onEvent!(
          StreamEvent(
            type: 'session.info',
            sessionId: chat.runtime.runtimeId,
            data: stockChatReply(gateway, 'session.info', {
              'pending': [
                {
                  ...canonicalReceipt(
                    {
                      'session_id': chat.runtime.runtimeId,
                      'submission_id': 'process-notice',
                      'text': text,
                    },
                    admissionId: 'process-notice',
                    status: 'queued',
                  ),
                  'controls': [],
                },
              ],
            }),
            envelope: {'replay_epoch': 'fixture-epoch', 'seq': 1},
          ),
        );
        await pumpFrames(tester);
        expect(find.text('1 queued'), findsOneWidget);
        expect(find.text(text), findsNothing);
        await capture(tester, 'queue-compact-${brightness.name}-$scale');
        await tester.tap(find.text('1 queued'));
        await pumpFrames(tester);
        await capture(tester, 'queue-expanded-${brightness.name}-$scale');
        await tester.tap(find.text(text));
        await pumpFrames(tester);
        expect(find.text('Queued message'), findsOneWidget);
        expect(find.byTooltip('Edit queued message'), findsNothing);
        expect(find.byTooltip('Steer queued message'), findsNothing);
        expect(find.byType(SelectableText), findsOneWidget);
        expect(
          tester.widget<SelectableText>(find.byType(SelectableText)).data,
          text,
        );
        expect(
          find.byTooltip('Delete queued message').hitTestable(),
          findsOneWidget,
        );
        await capture(tester, 'queue-details-${brightness.name}-$scale');
        String? copied;
        final copyReceipt = Completer<void>();
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
              await copyReceipt.future;
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await tester.tap(find.byTooltip('Copy queued message'));
        await pumpFrames(tester, count: 2);
        expect(find.byTooltip('Copy queued message: copying'), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        copyReceipt.complete();
        await pumpFrames(tester, count: 2);
        expect(find.byTooltip('Copy queued message: copied'), findsOneWidget);
        expect(copied, text);
        expect(chat.composer.observation.text, 'Separate draft');
        expect(tester.takeException(), isNull);
      });

      testWidgets(
        'collapsed queue keeps unknown and uncertain outcomes visible '
        '${brightness.name} $scale',
        (tester) async {
          final chat = await show(
            tester,
            brightness: brightness,
            scale: scale,
            status: ChatExecution.running,
            draft: 'Keep my draft',
          );
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 800);
          await pumpFrames(tester, count: 2);
          final gateway = controller.current!.gateway;
          var sequence = 0;
          Map<String, dynamic> receipt(String id, String text, String status) =>
              {
                ...canonicalReceipt(
                  {
                    'session_id': chat.runtime.runtimeId,
                    'submission_id': id,
                    'text': text,
                  },
                  admissionId: id,
                  status: status,
                ),
                'controls': <String>[],
              };
          void pending(List<Map<String, dynamic>> rows) {
            gateway.onEvent!(
              StreamEvent(
                type: 'session.info',
                sessionId: chat.runtime.runtimeId,
                data: stockChatReply(gateway, 'session.info', {
                  'pending': rows,
                }),
                envelope: {'replay_epoch': 'fixture-epoch', 'seq': ++sequence},
              ),
            );
          }

          pending([
            receipt('unknown', 'Check what happened', 'unknown'),
            receipt('ordinary', 'Wait until later', 'queued'),
          ]);
          await pumpFrames(tester);
          expect(find.text('2 queued'), findsOneWidget);
          expect(find.text('1 to review'), findsOneWidget);
          expect(
            find.text('Outcome unknown · Check what happened'),
            findsOneWidget,
          );
          expect(find.text('Wait until later'), findsNothing);
          await capture(tester, 'queue-review-${brightness.name}-$scale');
          await tester.tap(find.text('Outcome unknown · Check what happened'));
          await pumpFrames(tester);
          expect(find.byTooltip('Acknowledge unknown outcome'), findsOneWidget);
          expect(find.byTooltip('Edit queued message'), findsNothing);
          expect(find.byTooltip('Steer queued message'), findsNothing);
          await capture(
            tester,
            'queue-unknown-details-${brightness.name}-$scale',
          );
          await tester.tap(find.byTooltip('Close queued message actions'));
          await pumpFrames(tester);
          await expandQueue(tester);
          await tester.scrollUntilVisible(
            find.text('Wait until later'),
            48,
            scrollable: find
                .descendant(
                  of: find.byType(ProfileQueuedMessages),
                  matching: find.byType(Scrollable),
                )
                .last,
          );
          await pumpFrames(tester, count: 2);
          expect(find.text('Wait until later'), findsOneWidget);
          await tester.ensureVisible(find.text('2 queued'));
          await pumpFrames(tester, count: 2);
          await tester.tap(find.text('2 queued'));
          await pumpFrames(tester);
          pending([receipt('unknown', 'Check what happened', 'queued')]);
          await pumpFrames(tester);
          expect(find.text('1 to review'), findsNothing);
          expect(find.text('Check what happened'), findsNothing);
          pending([]);
          await pumpFrames(tester);
          expect(find.text('1 queued'), findsNothing);
          await tester.runAsync(
            () => restoreComposerFixture(
              chat: chat,
              preferences: controller.preferences,
              text: 'Keep my draft',
              paused: true,
              queuedPrompts: [
                QueuedPromptDraft(
                  text: 'Receipt was lost',
                  submissionUncertain: true,
                ),
              ],
            ),
          );
          await pumpFrames(tester);
          expect(
            find.text('Delivery unconfirmed · Receipt was lost').hitTestable(),
            findsOneWidget,
          );
          expect(find.text('Paused · 1 to review'), findsOneWidget);
          expect(chat.composer.observation.text, 'Keep my draft');
          await capture(tester, 'queue-uncertain-${brightness.name}-$scale');
          await tester.tap(
            find.text('Delivery unconfirmed · Receipt was lost'),
          );
          await pumpFrames(tester);
          expect(find.byType(SelectableText), findsOneWidget);
          expect(
            tester.widget<SelectableText>(find.byType(SelectableText)).data,
            'Receipt was lost',
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'automation start preserves its typed display notice ${brightness.name} $scale',
        (tester) async {
          final chat = await show(tester, brightness: brightness, scale: scale);
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 800);
          final gateway = controller.current!.gateway;
          const raw = 'Model context without any delegation marker';
          final receipt = canonicalReceipt(
            {
              'session_id': chat.runtime.runtimeId,
              'submission_id': 'automation-input',
              'text': raw,
            },
            admissionId: 'automation-admission',
            status: 'queued',
          );
          var sequence = 0;
          void event(String type, Map<String, dynamic> data) {
            gateway.onEvent!(
              StreamEvent(
                type: type,
                sessionId: chat.runtime.runtimeId,
                data: stockChatReply(gateway, type, data),
                envelope: {
                  'replay_epoch': 'fixture-epoch',
                  'seq': ++sequence,
                  'admission_id': 'automation-admission',
                },
              ),
            );
          }

          event('session.info', {
            'pending': [receipt],
          });
          event('message.start', {
            'display_kind': 'async_delegation_complete',
            'display_text': 'Subagent Tasks Completed: retailer checks',
            'text': raw,
          });
          event('session.info', {
            'pending': [
              {...receipt, 'status': 'started'},
            ],
          });
          await pumpFrames(tester);
          final row = chat.reading.messages.single;
          expect(row['display_kind'], 'async_delegation_complete');
          expect(row['display_metadata'], {
            'display_text': 'Subagent Tasks Completed: retailer checks',
          });
          expect(row['content'], raw);
          expect(find.text(raw), findsNothing);
          expect(find.byTooltip('Edit message'), findsNothing);
          expect(find.byTooltip('Restore checkpoint'), findsNothing);
          expect(tester.takeException(), isNull);
          await capture(tester, 'automation-flag-${brightness.name}-$scale');
        },
      );
    }
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('fresh Send after interruption shows delivery feedback '
          '${brightness.name} $scale', (tester) async {
        const text = 'A fresh request after stopping';
        final chat = await show(
          tester,
          brightness: brightness,
          scale: scale,
          status: ChatExecution.running,
          draft: text,
          paused: true,
        );
        emitChatEvent(controller, chat, 'turn.end', {'status': 'interrupted'});
        controller.connectionStatus.accessAvailable();
        controller.connectionStatus.liveChanged(
          chat.key.workspace.profileName,
          true,
        );
        await pumpFrames(tester);
        expect(chat.runtime.execution, ChatExecution.cancelled);
        final reply = fixture.submitReply = Completer<Map<String, dynamic>>();
        await tester.tap(find.byTooltip('Send'));
        await tester.pump();
        expect(find.text('1 queued'), findsOneWidget);
        expect(find.text('Paused'), findsNothing);
        await tester.runAsync(() async {
          await chat.composer.admittedWrites;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await pumpFrames(tester);
        expect(fixture.heldSubmission, isNotNull);
        expect(find.byType(ProfileMessage), findsOneWidget);
        expect(find.byType(StudioLoading), findsWidgets);
        expect(
          tester
              .getRect(find.byType(StudioLoading).first)
              .overlaps(const Rect.fromLTWH(0, 0, 360, 760)),
          isTrue,
        );
        expect(find.byTooltip('Stop'), findsOneWidget);
        await capture(tester, 'fresh-send-${brightness.name}-$scale-pending');
        reply.complete(
          canonicalReceipt(
            fixture.heldSubmission!,
            admissionId: 'fresh-send',
            status: 'started',
          ),
        );
        await pumpFrames(tester);
        expect(chat.composer.observation.queue, isEmpty);
        emitChatEvent(controller, chat, 'turn.end', {
          'status': 'completed',
          'text': 'Fresh request completed',
        });
        await pumpFrames(tester);
        expect(find.byType(StudioLoading), findsNothing);
        expect(find.text('Queue paused'), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('running Stop restores draft order at $brightness / $scale', (
        tester,
      ) async {
        final chat = await show(
          tester,
          brightness: brightness,
          scale: scale,
          status: ChatExecution.running,
        );
        tester.view.viewInsets = const FakeViewPadding(bottom: 280);
        await pumpFrames(tester);
        final name = '${brightness.name}-$scale';
        expect(chat.composer.actions().prefersStopAction, isTrue);
        expect(
          find.byKey(const ValueKey('composer-button-icon-stop')),
          findsOneWidget,
        );
        await capture(tester, '$name-stop');
        final gesture = await tester.startGesture(
          tester.getCenter(find.byTooltip('Stop')),
        );
        await tester.pump(const Duration(milliseconds: 800));
        expect(
          find.byKey(const ValueKey('composer-action-selector')),
          findsNothing,
        );
        await gesture.cancel();
        await tester.enterText(
          find.byKey(const Key('profile-message-composer')),
          ' ',
        );
        await tester.pump();
        expect(chat.composer.actions().prefersStopAction, isFalse);
        expect(
          tester
              .widget<ComposerActionButton>(find.byType(ComposerActionButton))
              .primary,
          ComposerAction.steer,
        );
        await tester.enterText(
          find.byKey(const Key('profile-message-composer')),
          'Next idea',
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 110));
        await capture(tester, '$name-typing-transition');
        await pumpFrames(tester);
        expect(
          find.byKey(const ValueKey('composer-button-icon-send')),
          findsOneWidget,
        );
        await capture(tester, '$name-typing');
        final typing = await tester.startGesture(
          tester.getCenter(find.byTooltip('Steer')),
        );
        await tester.pump(const Duration(milliseconds: 800));
        await pumpFrames(tester, count: 3);
        expect(
          tester
              .getTopLeft(find.byKey(const ValueKey('composer-choice-steer')))
              .dy,
          greaterThan(
            tester
                .getTopLeft(find.byKey(const ValueKey('composer-choice-stop')))
                .dy,
          ),
        );
        await capture(tester, '$name-typing-column');
        await typing.cancel();
        emitChatEvent(controller, chat, 'turn.end', {'status': 'completed'});
        await pumpFrames(tester);
        expect(chat.composer.actions().prefersStopAction, isFalse);
        expect(find.byTooltip('Send'), findsOneWidget);
        expect(chat.composer.observation.text, 'Next idea');
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      for (final startBeforeAck in [true, false]) {
        testWidgets('one sent bubble through processing start '
            '${brightness.name} $scale beforeAck=$startBeforeAck', (
          tester,
        ) async {
          const text = 'What is using all that space?';
          final chat = await show(
            tester,
            draft: text,
            brightness: brightness,
            scale: scale,
          );
          controller.connectionStatus.accessAvailable();
          controller.connectionStatus.liveChanged(
            chat.key.workspace.profileName,
            true,
          );
          final reply = fixture.submitReply = Completer<Map<String, dynamic>>();
          fixture.stalePostSubmitResume = true;
          await pumpFrames(tester);
          await tester.tap(find.byTooltip('Send'));
          await tester.runAsync(() async {
            await chat.composer.admittedWrites;
            await Future<void>.delayed(const Duration(milliseconds: 100));
          });
          await pumpFrames(tester);
          final submitted = fixture.heldSubmission!;
          final original = chat.reading.messages.single;
          final presentation = chat.reading.messagePresentationId(original);
          expect(find.byType(ProfileMessage), findsOneWidget);
          expect(find.byTooltip('Stop'), findsOneWidget);

          final receipt = canonicalReceipt(
            submitted,
            admissionId: 'sent-admission',
            status: 'queued',
          );
          if (!startBeforeAck) {
            reply.complete(receipt);
            await pumpFrames(tester);
          }
          final gateway = controller.current!.gateway;
          var sequence = 0;
          void event(
            String type,
            Map<String, dynamic> data, {
            String? admission,
          }) {
            gateway.onEvent!(
              StreamEvent(
                type: type,
                sessionId: chat.runtime.runtimeId,
                data: stockChatReply(gateway, type, data),
                envelope: {
                  'replay_epoch': 'fixture-epoch',
                  'seq': ++sequence,
                  'admission_id': ?admission,
                },
              ),
            );
          }

          event('session.info', {
            'pending': [receipt],
          });
          event('message.start', {}, admission: 'sent-admission');
          await pumpFrames(tester);
          expect(chat.reading.messages, hasLength(1));
          expect(chat.reading.messages.single, same(original));
          expect(
            chat.reading.messagePresentationId(original),
            same(presentation),
          );
          expect(find.byType(ProfileMessage), findsOneWidget);
          expect(find.byTooltip('Stop'), findsOneWidget);
          if (startBeforeAck) reply.complete(receipt);
          await pumpFrames(tester);
          expect(chat.runtime.error, isNull);
          expect(chat.composer.observation.error, isNull);
          expect(chat.composer.observation.paused, isFalse);
          expect(fixture.postSubmitResumes, 0);
          expect(
            find.text(
              'The message was accepted. Remaining unsent work could not be saved.',
            ),
            findsNothing,
          );
          expect(find.byTooltip('Stop'), findsOneWidget);
          fixture.transcript = [
            {
              'id': 1,
              'role': 'user',
              'content': text,
              'timestamp': original['timestamp'],
            },
          ];
          await tester.runAsync(() => controller.refreshHistory(chat));
          // A retained start observation must not resurrect the provisional row
          // after history has replaced it with the saved message.
          event('message.start', {}, admission: 'sent-admission');
          await pumpFrames(tester);
          expect(chat.reading.messages, hasLength(1));
          expect(find.byType(ProfileMessage), findsOneWidget);
          expect(
            fixture.calls.where((call) => call.$2 == 'prompt.submit'),
            hasLength(1),
          );
          // Stock publishes the claimed status after message.start. Settle
          // the outbox observation before inspecting the working screen.
          event('session.info', {
            'pending': [
              {...receipt, 'status': 'started'},
            ],
          });
          await pumpFrames(tester);
          await capture(
            tester,
            'single-prompt-${brightness.name}-$scale-$startBeforeAck',
          );

          // A different accepted input with identical prose still needs its own
          // bubble when it starts; it has no local optimistic representation.
          final next = canonicalReceipt(
            {...submitted, 'submission_id': 'different-input'},
            admissionId: 'different-admission',
            status: 'queued',
            sequence: 2,
          );
          event('session.info', {
            'pending': [next],
          });
          event('message.start', {}, admission: 'different-admission');
          await pumpFrames(tester);
          expect(
            chat.reading.messages.where((row) => row['role'] == 'user'),
            hasLength(2),
          );
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  testWidgets('Send becomes a tappable Stop before a reply arrives', (
    tester,
  ) async {
    final chat = await show(tester, draft: 'Start working');
    controller.connectionStatus.accessAvailable();
    controller.connectionStatus.liveChanged(
      chat.key.workspace.profileName,
      true,
    );
    await pumpFrames(tester);
    await tester.tap(find.byTooltip('Send'));
    await tester.runAsync(() async {
      await chat.composer.admittedWrites;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await pumpFrames(tester);
    expect(
      fixture.calls.where((call) => call.$2 == 'prompt.submit'),
      hasLength(1),
      reason:
          '${chat.composer.observation.error}; ${chat.runtime.error}; '
          '${chat.composer.observation.queue.length} queued; '
          '${controller.connectionStatus.description}',
    );
    expect(chat.composer.actions().prefersStopAction, isTrue);
    expect(
      find.byKey(const ValueKey('composer-button-icon-stop')),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Stop'));
    await pumpFrames(tester);
    expect(
      fixture.calls.where((call) => call.$2 == 'session.interrupt'),
      hasLength(1),
    );
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('Send then app return shows reply beginning '
          '${brightness.name} $scale', (tester) async {
        final chat = await show(
          tester,
          brightness: brightness,
          scale: scale,
          draft: 'Explain the next steps.',
        );
        controller.connectionStatus.accessAvailable();
        controller.connectionStatus.liveChanged(
          chat.key.workspace.profileName,
          true,
        );
        await pumpFrames(tester);
        await tester.tap(find.byTooltip('Send'));
        await tester.runAsync(() async {
          await chat.composer.admittedWrites;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await pumpFrames(tester);
        expect(
          fixture.calls.where((call) => call.$2 == 'prompt.submit'),
          hasLength(1),
        );
        expect(find.byTooltip('Stop'), findsOneWidget);
        for (final state in [
          AppLifecycleState.inactive,
          AppLifecycleState.hidden,
          AppLifecycleState.paused,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
        final steps = List.generate(
          30,
          (i) => 'Step $i: Read this reply at your own pace.',
        ).join('\n\n');
        final answer = 'Start here.\n\n$steps';
        try {
          emitChatEvent(controller, chat, 'message.start');
          emitChatEvent(controller, chat, 'message.delta', {'text': answer});
          await pumpFrames(tester);
        } finally {
          for (final state in [
            AppLifecycleState.hidden,
            AppLifecycleState.inactive,
            AppLifecycleState.resumed,
          ]) {
            tester.binding.handleAppLifecycleStateChanged(state);
          }
        }
        await pumpFrames(tester);
        await tester.settleMarkdown();
        await pumpFrames(tester);
        final reply = find.byWidgetPredicate(
          (widget) => widget is ProfileMessage && widget.message.text == answer,
        );
        expect(reply, findsOneWidget);
        final viewport = tester.getRect(
          find.byKey(const ValueKey('profile-transcript')),
        );
        final top = tester.getTopLeft(reply).dy;
        expect(top, greaterThanOrEqualTo(viewport.top - 1));
        expect(top, lessThan(viewport.bottom));
        expect(chat.reading.readingPosition.readThrough, isNull);
        await capture(tester, 'reply-return-${brightness.name}-$scale');
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final action in [ComposerAction.queue, ComposerAction.stop]) {
    testWidgets(
      'typing restores configured ${action.name} after automatic Stop',
      (tester) async {
        await appPreferences.setRunningAction(action);
        await show(tester, status: ChatExecution.running);
        expect(
          find.byKey(const ValueKey('composer-button-icon-stop')),
          findsOneWidget,
        );
        await tester.enterText(
          find.byKey(const Key('profile-message-composer')),
          'Follow up',
        );
        await pumpFrames(tester);
        final button = tester.widget<ComposerActionButton>(
          find.byType(ComposerActionButton),
        );
        expect(button.primary, action);
        expect(button.resting, ComposerAction.send);
        expect(appPreferences.current.preferredRunningAction, action);
      },
    );
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('queued edit refusal is consistent across gestures '
          '${brightness.name} $scale', (tester) async {
        const text =
            '[IMPORTANT: Background process matched watch pattern READY.]';
        final chat = await show(
          tester,
          brightness: brightness,
          scale: scale,
          status: ChatExecution.running,
          draft: 'Separate draft',
        );
        final gateway = controller.current!.gateway;
        final receipt = canonicalReceipt(
          {
            'session_id': chat.runtime.runtimeId,
            'submission_id': 'process-notice',
            'text': text,
          },
          admissionId: 'process-notice',
          status: 'queued',
        );
        var sequence = 0;
        void pending(List<String> controls) {
          gateway.onEvent!(
            StreamEvent(
              type: 'session.info',
              sessionId: chat.runtime.runtimeId,
              data: stockChatReply(gateway, 'session.info', {
                'pending': [
                  {...receipt, 'controls': controls},
                ],
              }),
              envelope: {'replay_epoch': 'fixture-epoch', 'seq': ++sequence},
            ),
          );
        }

        pending([]);
        await pumpFrames(tester);
        await expandQueue(tester);
        for (final longPress in [false, true]) {
          if (longPress) {
            await tester.longPress(find.text(text));
          } else {
            await tester.tap(find.text(text));
          }
          await pumpFrames(tester);
          expect(find.text('Queued message'), findsOneWidget);
          expect(chat.composer.observation.editing, isNull);
          expect(find.byTooltip('Edit queued message'), findsNothing);
          expect(find.byTooltip('Steer queued message'), findsNothing);
          expect(find.textContaining('Refresh the queue'), findsNothing);
          expect(chat.composer.observation.text, 'Separate draft');
          await capture(
            tester,
            'queue-refusal-${brightness.name}-$scale-$longPress',
          );
          await tester.tap(find.byTooltip('Close queued message actions'));
          await pumpFrames(tester);
        }
        pending(['replace', 'steer']);
        await pumpFrames(tester);
        await tester.tap(find.text(text));
        await pumpFrames(tester);
        final edit = find.widgetWithIcon(IconButton, Icons.edit_outlined);
        expect(tester.widget<IconButton>(edit).onPressed, isNotNull);
        pending([]);
        await pumpFrames(tester);
        expect(edit, findsNothing);
        expect(find.byTooltip('Steer queued message'), findsNothing);
        expect(chat.composer.observation.editing, isNull);
        expect(
          fixture.calls.any((call) => call.$2 == 'prompt.replace_queued'),
          isFalse,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('supported queued Steer explains its temporary restriction', (
    tester,
  ) async {
    final chat = await show(
      tester,
      queued: ['Later'],
      draft: 'Separate draft',
      paused: true,
    );
    await tester.tap(find.text('Later'));
    await pumpFrames(tester);
    final steer = find.widgetWithIcon(IconButton, WingIcons.steer);
    expect(steer, findsOneWidget);
    expect(tester.widget<IconButton>(steer).onPressed, isNull);
    await tester.tap(steer);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      find.text(
        'There is no active turn to steer. This message will wait in the queue.',
      ),
      findsOneWidget,
    );
    expect(fixture.steerRequests, isEmpty);
    expect(chat.composer.observation.text, 'Separate draft');
    await capture(tester, 'queue-temporary-restriction');
  });

  testWidgets('long press opens the same queued actions before editing', (
    tester,
  ) async {
    final chat = await show(
      tester,
      queued: ['Keep this queued'],
      draft: 'My draft',
      paused: true,
      disconnected: true,
    );
    expect(find.byTooltip('Message actions'), findsNothing);
    await tester.longPress(find.text('Keep this queued'));
    await pumpFrames(tester, count: 4);
    expect(find.text('Queued message'), findsOneWidget);
    expect(chat.composer.observation.editing, isNull);
    await tester.tap(find.byTooltip('Edit queued message'));
    await pumpFrames(tester, count: 4);
    expect(chat.composer.observation.queue.single.text, 'Keep this queued');
    expect(chat.composer.observation.text, 'My draft');
    expect(chat.composer.observation.displayedText, 'Keep this queued');
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byTooltip('Save queued message'), findsOneWidget);
    expect(find.widgetWithIcon(IconButton, WingIcons.steer), findsOneWidget);
    expect(find.byTooltip('Delete queued message'), findsOneWidget);
    expect(find.byTooltip('Message actions'), findsNothing);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('profile-message-composer')))
          .focusNode!
          .hasFocus,
      isTrue,
    );
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'tap offers actions for the selected queued message $brightness $scale',
        (tester) async {
          final chat = await show(
            tester,
            brightness: brightness,
            scale: scale,
            status: ChatExecution.running,
            queued: ['First queued', 'Second queued'],
            draft: 'Separate draft',
            paused: true,
          );
          tester.view.viewInsets = const FakeViewPadding(bottom: 260);
          await pumpFrames(tester);
          await tester.ensureVisible(find.text('Second queued'));
          await pumpFrames(tester, count: 2);
          await tester.tap(find.text('Second queued'));
          await pumpFrames(tester);
          expect(find.byTooltip('Edit queued message'), findsOneWidget);
          expect(
            find.widgetWithIcon(IconButton, WingIcons.steer),
            findsOneWidget,
          );
          expect(find.byTooltip('Delete queued message'), findsOneWidget);
          expect(find.text('Steer this turn'), findsNothing);
          await capture(tester, 'queued-actions-${brightness.name}-$scale');
          await tester.tap(find.byTooltip('Edit queued message'));
          await pumpFrames(tester);
          expect(
            chat.composer.observation.editing,
            same(chat.composer.observation.queue.last.id),
          );
          expect(chat.composer.observation.displayedText, 'Second queued');
          expect(chat.composer.observation.text, 'Separate draft');
          await tester.ensureVisible(find.byTooltip('Save queued message'));
          await pumpFrames(tester, count: 2);
          await capture(tester, 'queued-edit-${brightness.name}-$scale');
          expect(
            find.byTooltip('Save queued message').hitTestable(),
            findsOneWidget,
          );
          expect(
            find.byTooltip('Cancel queued message editing').hitTestable(),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'tap Steer delivers the selected queue entry and preserves the draft',
    (tester) async {
      final chat = await show(
        tester,
        status: ChatExecution.running,
        queued: ['First queued', 'Second queued'],
        draft: 'Separate draft',
        paused: true,
      );
      await tester.tap(find.text('Second queued'));
      await pumpFrames(tester);
      await tester.tap(find.byTooltip('Steer queued message'));
      await pumpFrames(tester);
      expect(fixture.steerRequests.single['text'], 'Second queued');
      expect(chat.composer.observation.queue.single.text, 'First queued');
      expect(chat.composer.observation.text, 'Separate draft');
      expect(chat.composer.observation.editing, isNull);
    },
  );

  testWidgets(
    'queued steer shows progress, rejection and retry on the selected row',
    (tester) async {
      fixture.steerReply = Completer<Map<String, dynamic>>();
      final chat = await show(
        tester,
        status: ChatExecution.running,
        queued: ['First queued', 'Second queued'],
        draft: 'Separate draft',
        paused: true,
      );
      await tester.tap(find.text('Second queued'));
      await pumpFrames(tester, count: 4);
      await tester.tap(find.byTooltip('Steer queued message'));
      await pumpFrames(tester, count: 4);
      expect(fixture.steerRequests.single['text'], 'Second queued');
      expect(find.text('Queued message'), findsNothing);
      expect(find.textContaining('Second queued'), findsOneWidget);
      final loading = find.descendant(
        of: find.byKey(const ValueKey('studio-loading-slot')),
        matching: find.byTooltip('Steering message'),
      );
      expect(loading.hitTestable(), findsOneWidget);
      await capture(tester, 'queued-steer-pending');
      fixture.steerReply!.complete({'status': 'rejected'});
      await pumpFrames(tester, count: 4);
      expect(loading, findsNothing);
      expect(
        find.text('Hermes rejected the steering message.'),
        findsOneWidget,
      );
      expect(chat.composer.observation.queue, hasLength(2));
      await tester.tap(find.text('2 queued'));
      await pumpFrames(tester);
      expect(find.textContaining('1 to review'), findsOneWidget);
      expect(find.text('Second queued'), findsOneWidget);
      expect(chat.composer.observation.text, 'Separate draft');
      fixture.steerReply = null;
      await tester.tap(find.text('Second queued'));
      await pumpFrames(tester, count: 4);
      await tester.tap(find.byTooltip('Steer queued message'));
      await pumpFrames(tester, count: 4);
      expect(fixture.steerRequests, hasLength(2));
      expect(chat.composer.observation.queue.single.text, 'First queued');
      expect(chat.composer.observation.text, 'Separate draft');
      expect(loading, findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('configured Stop remains a normal tap action', (tester) async {
    await appPreferences.setRunningAction(ComposerAction.stop);
    await show(tester, status: ChatExecution.running);
    await tester.tap(find.byTooltip('Stop'));
    await tester.pump();
    expect(fixture.calls.any((call) => call.$2 == 'session.interrupt'), isTrue);
    expect(find.text('Queue for the next turn'), findsNothing);
  });

  testWidgets('running draft exposes held selector with the keyboard open', (
    tester,
  ) async {
    final chat = await show(
      tester,
      status: ChatExecution.running,
      draft: 'Follow this direction',
    );
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await pumpFrames(tester, count: 4);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byTooltip('Steer')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    for (final action in ['steer', 'stop', 'queue']) {
      expect(find.byKey(ValueKey('composer-choice-$action')), findsOneWidget);
    }
    if (const bool.fromEnvironment('CAPTURE_COMPOSER')) {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('composer-preview')),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          'build/composer-held-selector.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    expect(chat.composer.observation.text, 'Follow this direction');
    expect(
      fixture.calls.any((call) => call.$2 == 'session.interrupt'),
      isFalse,
    );
    await gesture.cancel();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('configured Queue is used without changing future selections', (
    tester,
  ) async {
    await appPreferences.setRunningAction(ComposerAction.queue);
    final chat = await show(
      tester,
      status: ChatExecution.running,
      draft: 'Later',
    );
    await tester.tap(find.byTooltip('Queue'));
    await pumpFrames(tester);
    expect(chat.composer.observation.queue.single.text, 'Later');
    expect(chat.composer.observation.text, isEmpty);
    expect(find.text('1 queued'), findsOneWidget);
    await expandQueue(tester);
    expect(find.text('Later').hitTestable(), findsOneWidget);
    expect(
      controller.preferences.getString(
        AppPreferenceField.runningAction.storageKey,
      ),
      'queue',
    );
  });

  testWidgets('running chats allow choosing files for the next draft', (
    tester,
  ) async {
    await show(tester, status: ChatExecution.running);
    await tester.tap(find.byTooltip('Attach file'));
    await pumpFrames(tester, count: 4);
    expect(find.text('Files'), findsOneWidget);
    expect(find.text('Photos'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await pumpFrames(tester);
  });

  testWidgets('Held slide queues the draft and clears the composer', (
    tester,
  ) async {
    final chat = await show(
      tester,
      status: ChatExecution.running,
      draft: 'follow up after this turn',
    );
    await choose(tester, 'queue');
    expect(
      fixture.calls.any((call) => call.$2 == 'session.interrupt'),
      isFalse,
    );

    expect(
      chat.composer.observation.queue.single.text,
      'follow up after this turn',
    );
    expect(chat.composer.observation.text, isEmpty);
    final preview = find.text('follow up after this turn');
    expect(preview.hitTestable(), findsOneWidget);
    expect(
      find.byIcon(composerActionIcon(ComposerAction.queue)),
      findsOneWidget,
    );
  });

  testWidgets('accepted steer immediately shows its text in the transcript', (
    tester,
  ) async {
    final chat = await show(
      tester,
      status: ChatExecution.running,
      draft: 'Focus on the failing test',
    );
    await tester.tap(find.byTooltip('Steer'));
    await pumpFrames(tester, count: 4);
    expect(chat.composer.observation.text, isEmpty);
    expect(find.text('steered'), findsOneWidget);
    expect(find.text('Focus on the failing test'), findsOneWidget);
    expect(find.byIcon(WingIcons.steer), findsOneWidget);
  });

  testWidgets('slash steer shows only its centered confirmation', (
    tester,
  ) async {
    final chat = await show(
      tester,
      status: ChatExecution.running,
      draft: '/steer Keep the data clean',
    );
    await controller.send(chat);
    await pumpFrames(tester);
    expect(chat.runtime.error, isNull);
    expect(
      chat.reading.messages
          .where((row) => row['_command_notice'] == true)
          .map((row) => row['content']),
      isEmpty,
    );
    expect(find.text('steered'), findsOneWidget);
    expect(find.text('Keep the data clean'), findsOneWidget);
    expect(find.text('Steering message queued.'), findsNothing);
  });

  testWidgets('Held slide queues an attachment-only draft by filename', (
    tester,
  ) async {
    final file = AttachmentDraft(
      id: 'report',
      cachedPath: 'report.pdf',
      name: 'report.pdf',
      byteLength: 10,
      mediaType: 'application/pdf',
      kind: AttachmentDraftKind.genericFile,
    );
    final chat = await show(
      tester,
      status: ChatExecution.running,
      attachments: [file],
    );
    await choose(tester, 'queue');
    expect(
      chat.composer.observation.queue.single.attachments.map((file) => file.id),
      [file.id],
    );
    expect(chat.composer.observation.attachments, isEmpty);
    expect(find.text('report.pdf').hitTestable(), findsOneWidget);
    controller.connectionStatus.liveChanged(
      chat.key.workspace.profileName,
      false,
    );
    await pumpFrames(tester, count: 4);
    expect(find.text('report.pdf'), findsOneWidget);

    await tester.tap(find.text('report.pdf'));
    await pumpFrames(tester, count: 4);
    expect(find.text('Queued message'), findsOneWidget);
    expect(find.text('report.pdf'), findsNWidgets(2));
    expect(find.byTooltip('Steer queued message'), findsNothing);
    expect(
      find.widgetWithIcon(IconButton, Icons.edit_outlined).hitTestable(),
      findsOneWidget,
    );
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('image queue omits unsupported Steer $brightness $scale', (
        tester,
      ) async {
        final bytes = raster.encodePng(
          raster.Image(width: 3, height: 2)
            ..clear(raster.ColorRgb8(39, 127, 137)),
        );
        final cache = await tester.runAsync(
          () => Directory.systemTemp.createTemp('queued-steer-hint-'),
        );
        addTearDown(() => cache!.delete(recursive: true));
        final file = File('${cache!.path}/photo.png');
        await tester.runAsync(() => file.writeAsBytes(bytes));
        final image = AttachmentDraft(
          id: 'queued-image',
          cachedPath: file.path,
          name: 'photo.png',
          byteLength: bytes.length,
          mediaType: 'image/png',
          kind: AttachmentDraftKind.image,
        );
        final caption = scale == 1 ? '' : 'Queued photo';
        final chat = await show(
          tester,
          brightness: brightness,
          scale: scale,
          status: ChatExecution.running,
          draft: caption,
          attachments: [image],
          paused: true,
        );
        tester.view.viewInsets = const FakeViewPadding(bottom: 260);
        await pumpFrames(tester);
        await choose(tester, 'queue');
        await controller.updateDraft(chat, 'Separate draft');
        await pumpFrames(tester);
        final selected = chat.composer.observation.queue.single.id;
        final row = find.text(
          caption.isEmpty ? 'photo.png' : '$caption · photo.png',
        );
        await tester.ensureVisible(row);
        await pumpFrames(tester, count: 2);
        await tester.tap(row);
        await pumpFrames(tester);
        expect(find.byTooltip('Steer queued message'), findsNothing);
        expect(fixture.steerRequests, isEmpty);
        expect(chat.composer.observation.queue.single.id, same(selected));
        expect(chat.composer.observation.text, 'Separate draft');
        await capture(tester, 'queued-image-menu-${brightness.name}-$scale');
        await tester.tap(find.byTooltip('Edit queued message'));
        await pumpFrames(tester);
        expect(chat.composer.observation.editing, same(selected));
        expect(find.byTooltip('Steer queued message'), findsNothing);
        await capture(tester, 'queued-image-edit-${brightness.name}-$scale');
        expect(
          chat.composer.observation.queue.single.attachments.single.id,
          image.id,
        );
        expect(fixture.steerRequests, isEmpty);
        await tester.ensureVisible(
          find.byTooltip('Cancel queued message editing'),
        );
        await pumpFrames(tester, count: 2);
        await tester.tap(find.byTooltip('Cancel queued message editing'));
        await pumpFrames(tester);
        expect(chat.composer.observation.displayedText, 'Separate draft');
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('delete cross confirms deletion and restores the draft', (
    tester,
  ) async {
    final chat = await show(
      tester,
      queued: ['Delete this'],
      draft: 'Separate draft',
      paused: true,
      disconnected: true,
    );
    await tester.longPress(find.text('Delete this'));
    await pumpFrames(tester, count: 4);
    await tester.tap(find.byTooltip('Edit queued message'));
    await pumpFrames(tester, count: 4);
    await tester.tap(find.byTooltip('Delete queued message'));
    await pumpFrames(tester, count: 4);
    expect(find.text('Delete queued instruction?'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byTooltip('Cancel'),
      ),
    );
    await pumpFrames(tester, count: 4);
    expect(chat.composer.observation.queue, hasLength(1));
    expect(chat.composer.observation.displayedText, 'Delete this');
    controller.connectionStatus.liveChanged(
      chat.key.workspace.profileName,
      false,
    );
    await pumpFrames(tester, count: 4);
    await tester.tap(find.byTooltip('Delete queued message'));
    await pumpFrames(tester, count: 4);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byTooltip('Delete queued message'),
      ),
    );
    await pumpFrames(tester, count: 4);
    expect(chat.composer.observation.queue, isEmpty);
    expect(chat.composer.observation.displayedText, 'Separate draft');
    expect(find.text('Editing queued message'), findsNothing);
  });

  testWidgets('composer queue edit cancels or saves in place', (tester) async {
    final chat = await show(
      tester,
      queued: ['Original', 'Second'],
      draft: 'Separate draft',
      paused: true,
      disconnected: true,
    );
    final editor = find.byKey(const Key('profile-message-composer'));
    await tester.longPress(find.text('Original'));
    await pumpFrames(tester, count: 4);
    await tester.tap(find.byTooltip('Edit queued message'));
    await pumpFrames(tester, count: 4);
    await tester.enterText(editor, 'Discarded edit');
    await tester.tap(find.byTooltip('Cancel queued message editing'));
    await pumpFrames(tester, count: 4);
    expect(chat.composer.observation.queue.first.text, 'Original');
    expect(chat.composer.observation.displayedText, 'Separate draft');
    await tester.longPress(find.text('Original'));
    await pumpFrames(tester, count: 4);
    await tester.tap(find.byTooltip('Edit queued message'));
    await pumpFrames(tester, count: 4);
    await tester.enterText(editor, '');
    await tester.pump();
    expect(
      tester
          .widget<IconButton>(
            find.ancestor(
              of: find.byTooltip('Save queued message'),
              matching: find.byType(IconButton),
            ),
          )
          .onPressed,
      isNull,
    );
    await tester.enterText(editor, 'Updated');
    await tester.pump();
    await tester.tap(find.byTooltip('Save queued message'));
    await pumpFrames(tester, count: 4);
    expect(chat.composer.observation.queue.map((prompt) => prompt.text), [
      'Updated',
      'Second',
    ]);
    expect(chat.composer.observation.displayedText, 'Separate draft');
    expect(find.text('Editing queued message'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('edited steering replaces only the selected queued instruction', (
    tester,
  ) async {
    final chat = await show(
      tester,
      status: ChatExecution.running,
      queued: ['Original', 'Second'],
      draft: 'Separate draft',
      paused: true,
    );
    await tester.longPress(find.text('Original'));
    await pumpFrames(tester, count: 4);
    await tester.tap(find.byTooltip('Edit queued message'));
    await pumpFrames(tester, count: 4);
    await tester.enterText(
      find.byKey(const Key('profile-message-composer')),
      'Changed direction',
    );
    await pumpFrames(tester, count: 4);
    await tester.tap(find.byTooltip('Steer queued message'));
    await pumpFrames(tester, count: 4);
    expect(chat.composer.observation.queue.map((prompt) => prompt.text), [
      'Second',
    ]);
    expect(chat.composer.observation.displayedText, 'Separate draft');
    expect(find.text('Changed direction'), findsOneWidget);
    expect(find.text('steered'), findsOneWidget);
  });

  testWidgets('rejected queued steer keeps the edit and the buffered draft', (
    tester,
  ) async {
    fixture.steerResult = {'status': 'rejected'};
    final chat = await show(
      tester,
      status: ChatExecution.running,
      queued: ['Original'],
      draft: 'Separate draft',
      paused: true,
    );
    await tester.longPress(find.text('Original'));
    await pumpFrames(tester, count: 4);
    await tester.tap(find.byTooltip('Edit queued message'));
    await pumpFrames(tester, count: 4);
    await tester.enterText(
      find.byKey(const Key('profile-message-composer')),
      'Try this',
    );
    await pumpFrames(tester, count: 4);
    await tester.tap(find.byTooltip('Steer queued message'));
    await pumpFrames(tester, count: 4);
    expect(chat.composer.observation.queue.single.text, 'Original');
    expect(chat.composer.observation.displayedText, 'Try this');
    expect(chat.composer.observation.text, 'Separate draft');
    expect(find.text('steered'), findsNothing);
    expect(find.text('Hermes rejected the steering message.'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    fixture.steerResult = {'status': 'queued'};
    await tester.tap(find.byTooltip('Steer queued message'));
    await pumpFrames(tester, count: 4);
    expect(chat.composer.observation.queue, isEmpty);
    expect(chat.composer.observation.displayedText, 'Separate draft');
    expect(find.text('steered'), findsOneWidget);
  });

  testWidgets('queue editing fits large text with the keyboard open', (
    tester,
  ) async {
    await show(
      tester,
      scale: 2.4,
      queued: ['Original'],
      paused: true,
      disconnected: true,
    );
    await tester.longPress(find.text('Original'));
    await pumpFrames(tester, count: 4);
    await tester.tap(find.byTooltip('Edit queued message'));
    await pumpFrames(tester, count: 4);
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await pumpFrames(tester, count: 4);
    expect(find.byTooltip('Save queued message'), findsOneWidget);
    expect(find.widgetWithIcon(IconButton, WingIcons.steer), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rejected steer leaves the typed draft intact', (tester) async {
    fixture.steerResult = {'status': 'rejected'};
    final chat = await show(
      tester,
      status: ChatExecution.running,
      draft: 'keep this if Hermes rejects it',
    );
    await tester.tap(find.byTooltip('Steer'));
    await pumpFrames(tester, count: 4);
    expect(chat.composer.observation.text, 'keep this if Hermes rejects it');
    expect(find.text('steered'), findsNothing);
    expect(find.text('Hermes rejected the steering message.'), findsOneWidget);
  });

  testWidgets(
    'accepted steer preserves a draft edited away and back while held',
    (tester) async {
      fixture.steerReply = Completer<Map<String, dynamic>>();
      final chat = await show(
        tester,
        status: ChatExecution.running,
        draft: 'Check the timeout',
      );
      await tester.tap(find.byTooltip('Steer'));
      await pumpFrames(tester, count: 4);
      expect(chat.composer.observation.steering, isTrue);
      expect(find.text('steered'), findsNothing);
      final field = find.byKey(const Key('profile-message-composer'));
      await tester.enterText(field, 'A different intended message');
      await tester.pump();
      await tester.enterText(field, 'Check the timeout');
      await tester.pump();
      fixture.steerReply!.complete({'status': 'queued'});
      await pumpFrames(tester, count: 4);
      expect(
        chat.reading.messages.where((row) => row['display_kind'] == 'steer'),
        hasLength(1),
      );
      expect(chat.composer.observation.text, 'Check the timeout');
      expect(
        tester.widget<TextField>(field).controller!.text,
        'Check the timeout',
      );
    },
  );

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'steer becomes a normal bubble in saved history ${brightness.name} $scale',
        (tester) async {
          fixture.steerReply = Completer<Map<String, dynamic>>();
          final chat = await show(
            tester,
            status: ChatExecution.running,
            brightness: brightness,
            scale: scale,
            draft: 'Check the timeout',
          );
          await tester.tap(find.byTooltip('Steer'));
          await pumpFrames(tester, count: 4);
          expect(find.text('steered'), findsNothing);
          await tester.enterText(
            find.byKey(const Key('profile-message-composer')),
            'A separate follow-up',
          );
          fixture.steerReply!.complete({'status': 'queued'});
          await pumpFrames(tester, count: 4);
          expect(chat.composer.observation.text, 'A separate follow-up');
          expect(find.text('Check the timeout'), findsOneWidget);
          expect(find.text('steered'), findsOneWidget);

          await capture(tester, 'steer-${brightness.name}-$scale-accepted');
          fixture.transcript = [
            {
              'id': 42,
              'role': 'user',
              'display_kind': 'steer',
              'content':
                  '[OUT-OF-BAND USER MESSAGE — a direct message from the user, delivered once at this position; not tool output and not a new delivery when replayed from conversation history]\nCheck the timeout\n[/OUT-OF-BAND USER MESSAGE]',
            },
          ];
          await controller.refreshHistory(chat);
          await pumpFrames(tester, count: 4);
          expect(find.text('steered'), findsNothing);
          final bubble = find.byWidgetPredicate(
            (widget) => widget is ProfileMessage && widget.message.id == 42,
          );
          expect(bubble, findsOneWidget);
          final message = tester.widget<ProfileMessage>(bubble).message;
          expect(message.kind, TranscriptMessageKind.dialogue);
          expect(message.text, 'Check the timeout');
          expect(message.copyText, 'Check the timeout');
          expect(chat.composer.observation.text, 'A separate follow-up');
          expect(find.textContaining('OUT-OF-BAND'), findsNothing);
          expect(chat.reading.messages.single['display_kind'], 'steer');
          final copy = find.descendant(
            of: bubble,
            matching: find.byTooltip('Copy message'),
          );
          expect(copy, findsOneWidget);
          String? copied;
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            (call) async {
              if (call.method == 'Clipboard.setData') {
                copied = (call.arguments as Map)['text'] as String;
              }
              return null;
            },
          );
          addTearDown(
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(SystemChannels.platform, null),
          );
          await tester.tap(copy);
          await pumpFrames(tester, count: 4);
          expect(copied, 'Check the timeout');
          await capture(tester, 'steer-${brightness.name}-$scale-saved');
          await controller.refreshHistory(chat);
          await pumpFrames(tester, count: 4);
          expect(find.text('steered'), findsNothing);
          expect(bubble, findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('a failed steer does not claim success or clear the draft', (
    tester,
  ) async {
    fixture.steerReply = Completer<Map<String, dynamic>>();
    final chat = await show(
      tester,
      status: ChatExecution.running,
      draft: 'Keep this draft',
    );
    await tester.tap(find.byTooltip('Steer'));
    await pumpFrames(tester, count: 4);
    fixture.steerReply!.completeError(StateError('Connection lost'));
    await pumpFrames(tester, count: 4);
    expect(chat.composer.observation.text, 'Keep this draft');
    expect(find.text('steered'), findsNothing);
    expect(find.textContaining('Connection lost'), findsOneWidget);
  });

  testWidgets(
    'queued rows stay bounded with large text and open queue actions',
    (tester) async {
      final chat = await show(
        tester,
        scale: 2.4,
        paused: true,
        queued: ['First follow-up', 'Second follow-up', 'Third follow-up'],
      );
      controller.connectionStatus.liveChanged(
        chat.key.workspace.profileName,
        false,
      );
      await pumpFrames(tester, count: 4);
      expect(find.text('Paused'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('First follow-up'));
      await pumpFrames(tester, count: 4);
      expect(
        find.byTooltip('Resume queued messages').hitTestable(),
        findsOneWidget,
      );
      expect(
        find.byTooltip('Edit queued message').hitTestable(),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Edit queued message'));
      await pumpFrames(tester, count: 4);
      expect(chat.composer.observation.displayedText, 'First follow-up');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('large text scale keeps the held selector bounded', (
    tester,
  ) async {
    await show(
      tester,
      scale: 2.4,
      status: ChatExecution.running,
      draft: 'Steer me',
    );
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await pumpFrames(tester, count: 4);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byTooltip('Steer')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(
      find.byKey(const ValueKey('composer-action-selector')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await gesture.cancel();
    await tester.pump();
  });
}
