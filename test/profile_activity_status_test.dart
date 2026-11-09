import 'package:wing/core/widgets/profile_execution_activity.dart';
import 'package:wing/core/widgets/profile_tool_call.dart';
import 'helpers/pump_markdown_widget.dart';
import 'dart:io';
import 'dart:async';
import 'package:wing/core/models/attachment_draft.dart';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'package:wing/core/services/chat_runtime.dart';
import 'support/composer_fixture.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/models/chat_runtime.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/screens/profile_transcript.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/widgets/profile_activity_status.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/theme/wing_icons.dart';

import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'profile_workspace_controller_test.dart' show Host;

void main({Future<void> Function(WidgetTester, String)? capture}) {
  const review = bool.fromEnvironment('STUDIO_WORK_REVIEW');
  setUpAll(() async {
    if (!review) return;
    for (final entry in {
      'Roboto': 'build/studio-roboto.ttf',
      'MaterialIcons': 'build/studio-icons.otf',
      'WingIcons': 'assets/fonts/wing-icons.ttf',
      'WingProjectIcons': 'assets/fonts/codicons.ttf',
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            File(entry.value).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
    }
  });
  Future<void> renderStatus(WidgetTester tester, String name) async {
    if (!review) return;
    await tester.settleMarkdown();
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('work-status-review')),
      );
      final picture = await boundary.toImage();
      final bytes = await picture.toByteData(format: ui.ImageByteFormat.png);
      final folder = Directory(
        'build/design-previews/loading-family/site/work-renders',
      )..createSync(recursive: true);
      await File(
        '${folder.path}/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      picture.dispose();
    });
  }

  late Host host;
  late ProfileWorkspaceController controller;
  late WorkspaceRuntimeFixture runtimes;
  late AppPreferences appPreferences;
  late ProfileChat chat;
  late ChatRuntime runtime;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    runtimes = WorkspaceRuntimeFixture();
    host = Host()..running = false;
    host.ownedPatch = (endpoint, body, canDispatch, onDispatched) async {
      expect(endpoint, 'sessions/same');
      expect(body, {'unread': false, 'profile': 'a'});
      expect(canDispatch(), isTrue);
      onDispatched();
      return {'ok': true};
    };
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: identityTestConnection(),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'activity-status',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
      runtimeFactory: runtimes.create,
    );
    await controller.initialize();

    chat = await openFixtureChat(
      controller: controller,
      key: ProfileSessionKey(controller.current!.scope, 'same'),
      title: 'Activity',
    );
    runtime = runtimes.forChat(chat);
  });

  tearDown(() {
    controller.dispose();
    appPreferences.dispose();
  });

  String? label({bool executionInTranscript = false}) => ProfileActivityStatus(
    runtime: chat.runtime,
    subagents: chat.subagents,
    unconfirmedSubagentIds: chat.unconfirmedSubagentIds,
    saving: chat.composer.observation.saving,
    executionInTranscript: executionInTranscript,
  ).label;

  testWidgets('opening and offline reading omit the composer status', (
    tester,
  ) async {
    host.event('a', 'message.start');
    runtime.beginOpening();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileActivityStatus(
            runtime: chat.runtime,
            subagents: chat.subagents,
            unconfirmedSubagentIds: chat.unconfirmedSubagentIds,
            saving: chat.composer.observation.saving,
          ),
        ),
      ),
    );
    expect(label(), isNull);
    expect(tester.getSize(find.byType(ProfileActivityStatus)).height, 0);
    expect(find.byIcon(Icons.pending_outlined), findsNothing);

    runtime.installOfflineReading();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileActivityStatus(
            runtime: chat.runtime,
            subagents: chat.subagents,
            unconfirmedSubagentIds: chat.unconfirmedSubagentIds,
            saving: chat.composer.observation.saving,
          ),
        ),
      ),
    );
    expect(label(), isNull);
    expect(tester.getSize(find.byType(ProfileActivityStatus)).height, 0);

    runtime.finishOpening(error: 'Could not open conversation');
    expect(label(), 'Sending unavailable · Your draft is kept');
    runtime.recovered();
    expect(label(), 'Hermes is working…');
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'nonempty outbox stays visible across connection changes ${brightness.name} $scale',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          tester.view.viewInsets = const FakeViewPadding(bottom: 260);
          host.event('a', 'message.start');
          await tester.runAsync(() async {
            await controller.queuePrompt(chat, 'First waiting message');
            await controller.queuePrompt(chat, 'Second waiting message');
          });
          await tester.pumpWidget(
            MaterialApp(
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: RepaintBoundary(
                  key: const ValueKey('work-status-review'),
                  child: child!,
                ),
              ),
              home: ProfileWorkspaceScreen(
                controller: controller,
                createBotsSession: () => BotsSession((_) async => const []),
              ),
            ),
          );
          for (var i = 0; i < 8; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(find.byIcon(WingIcons.queue), findsNWidgets(2));
          expect(chat.composer.observation.queue, hasLength(2));
          controller.connectionStatus.liveChanged('b', false);
          await tester.pump();
          expect(find.byIcon(WingIcons.queue), findsNWidgets(2));
          controller.connectionStatus.liveChanged('a', false);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.byIcon(WingIcons.queue), findsNWidgets(2));
          expect(find.text('First waiting message'), findsOneWidget);
          await renderStatus(
            tester,
            'chat-queue-offline-${brightness.name}-$scale',
          );
          controller.connectionStatus.liveChanged('a', true);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.byIcon(WingIcons.queue), findsNWidgets(2));
          expect(chat.composer.observation.queue, hasLength(2));
          await renderStatus(
            tester,
            'chat-queue-connected-${brightness.name}-$scale',
          );
          await tester.runAsync(
            () => controller.removeQueuedPrompt(
              chat,
              chat.composer.observation.queue.first.id,
            ),
          );
          await tester.pump();
          expect(find.text('First waiting message'), findsNothing);
          expect(
            find.text('Second waiting message').hitTestable(),
            findsOneWidget,
          );
          await tester.runAsync(
            () => controller.removeQueuedPrompt(
              chat,
              chat.composer.observation.queue.single.id,
            ),
          );
          await tester.pump();
          expect(find.byIcon(WingIcons.queue), findsNothing);
          expect(find.text('Second waiting message'), findsNothing);
          await renderStatus(
            tester,
            'chat-queue-empty-${brightness.name}-$scale',
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );

      for (final fails in [false, true]) {
        testWidgets(
          'Send preparation uses header feedback ${brightness.name} $scale failure=$fails',
          (tester) async {
            tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            final cache = Directory.systemTemp.createTempSync('send-status-');
            addTearDown(() => cache.deleteSync(recursive: true));
            final file = File('${cache.path}/note.txt')
              ..writeAsStringSync('note');
            await tester.runAsync(
              () => restoreComposerFixture(
                chat: chat,
                preferences: controller.preferences,
                appendAttachments: [
                  AttachmentDraft(
                    id: 'note',
                    cachedPath: file.path,
                    name: 'note.txt',
                    byteLength: 4,
                    mediaType: 'text/plain',
                    kind: AttachmentDraftKind.genericFile,
                  ),
                ],
              ),
            );
            final gate = host.fileAttachDelay = Completer<void>();
            host.fileAttachFails = fails;
            await tester.pumpWidget(
              MaterialApp(
                theme: wingTheme(brightness),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: RepaintBoundary(
                    key: const ValueKey('work-status-review'),
                    child: child!,
                  ),
                ),
                home: ProfileWorkspaceScreen(
                  controller: controller,
                  createBotsSession: () => BotsSession((_) async => const []),
                ),
              ),
            );
            for (var i = 0; i < 8; i++) {
              await tester.pump(const Duration(milliseconds: 100));
            }
            final composer = find.byKey(
              const ValueKey('conversation-composer'),
            );
            await tester.enterText(composer, 'Send this note');
            await tester.tap(find.byTooltip('Send'));
            for (var i = 0; i < 30; i++) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 10)),
              );
              await tester.pump(const Duration(milliseconds: 100));
              if (host.calls.any((call) => call.$2 == 'file.attach')) break;
            }
            expect(
              host.calls.where((call) => call.$2 == 'file.attach'),
              hasLength(1),
            );
            expect(chat.runtime.execution, ChatExecution.submitting);
            expect(find.text('Sending message…'), findsNothing);
            expect(find.text('Saving queue…'), findsNothing);
            expect(find.byIcon(WingIcons.queue), findsOneWidget);
            expect(find.byType(StudioLoading), findsOneWidget);
            expect(
              tester.getSize(find.byType(ProfileActivityStatus)).height,
              0,
            );
            await tester.enterText(composer, 'Keep this next draft');
            await tester.pump(const Duration(milliseconds: 300));
            expect(chat.composer.observation.text, 'Keep this next draft');
            await renderStatus(
              tester,
              'chat-sending-${brightness.name}-$scale',
            );
            expect(
              tester
                  .widget<EditableText>(
                    find.descendant(
                      of: composer,
                      matching: find.byType(EditableText),
                    ),
                  )
                  .controller
                  .text,
              'Keep this next draft',
            );
            gate.complete();
            for (var i = 0; i < 30; i++) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 10)),
              );
              await tester.pump(const Duration(milliseconds: 100));
              if (!chat.composer.observation.draining) break;
            }
            expect(
              label(),
              fails ? 'Something went wrong' : 'Hermes is working…',
            );
            expect(chat.composer.observation.text, 'Keep this next draft');
            await tester.pump();
            await tester.pump();
            expect(
              find.byType(StudioLoading),
              fails ? findsNothing : findsOneWidget,
            );
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }

      testWidgets(
        'opening uses only the header pulse ${brightness.name} $scale',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          host.event('a', 'message.start');
          runtime.beginOpening();
          controller.connectionStatus.beginRecovery('opening-status-test');
          chat.reading.installSavedHistory(const []);
          await tester.pumpWidget(
            MaterialApp(
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: RepaintBoundary(
                  key: const ValueKey('work-status-review'),
                  child: child!,
                ),
              ),
              home: ProfileWorkspaceScreen(
                controller: controller,
                createBotsSession: () => BotsSession((_) async => const []),
              ),
            ),
          );
          for (var i = 0; i < 8; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(find.byType(StudioLoading), findsOneWidget);
          expect(tester.getSize(find.byType(ProfileActivityStatus)).height, 0);
          expect(
            find.text('This conversation will open automatically.'),
            findsNothing,
          );
          expect(find.text('Waiting for connection'), findsNothing);
          final composer = find.byKey(const ValueKey('conversation-composer'));
          await tester.enterText(composer, 'Draft while opening');
          expect(chat.composer.observation.text, 'Draft while opening');
          await renderStatus(tester, 'chat-opening-${brightness.name}-$scale');
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );

      testWidgets(
        'work pulse settles for input without moving the composer ${brightness.name} $scale',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          host.event('a', 'message.start');
          host.event('a', 'message.delta', {
            'text':
                'I am checking the current work and will keep the results here.',
          });
          await tester.pumpWidget(
            MaterialApp(
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: RepaintBoundary(
                  key: const ValueKey('work-status-review'),
                  child: child!,
                ),
              ),
              home: ProfileWorkspaceScreen(
                controller: controller,
                createBotsSession: () => BotsSession((_) async => const []),
              ),
            ),
          );
          for (var i = 0; i < 8; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          final row = find.byType(ProfileActivityStatus);
          final composer = find.byKey(const ValueKey('conversation-composer'));
          final bounds = tester.getRect(composer);
          expect(
            find.descendant(of: row, matching: find.byType(StudioLoading)),
            findsOneWidget,
          );
          expect(find.byType(ShaderMask), findsNothing);
          host.event('a', 'tool.start', {
            'tool_id': 'working-command',
            'name': 'terminal',
            'args': {'command': 'python report.py'},
          });
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.text('1 tool'), findsOneWidget);
          expect(find.text('Using Terminal · python report.py'), findsNothing);
          await tester.openLiveActivity();
          expect(find.text('Activity · 1 tool'), findsOneWidget);
          expect(find.text('Timeline'), findsNothing);
          expect(find.byType(StudioLoading), findsOneWidget);
          runtime.beginRecovery();
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
          await tester.pump(const Duration(milliseconds: 300));
          final activity = find.byKey(const ValueKey('live-activity'));
          expect(
            find.descendant(
              of: activity,
              matching: find.byType(StudioWorkingIndicator),
            ),
            findsNothing,
          );
          expect(
            find.descendant(
              of: activity,
              matching: find.byIcon(Icons.wifi_off_rounded),
            ),
            findsOneWidget,
          );
          runtime.recovered();
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
          await tester.pump(const Duration(milliseconds: 300));
          expect(
            find.descendant(
              of: activity,
              matching: find.byType(StudioWorkingIndicator),
            ),
            findsOneWidget,
          );
          expect(find.byIcon(Icons.terminal_rounded), findsWidgets);
          await tester.ensureVisible(find.byType(ProfileToolCall));
          await tester.pump(const Duration(milliseconds: 300));
          await renderStatus(tester, 'chat-working-${brightness.name}-$scale');
          host.event('a', 'clarify', {
            'request_id': 'choice',
            'question': 'Which result should I use?',
          });
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.text('Waiting for your reply'), findsOneWidget);
          expect(
            find.descendant(of: row, matching: find.byType(StudioLoading)),
            findsNothing,
          );
          expect(tester.getRect(composer), bounds);
          await renderStatus(tester, 'chat-input-${brightness.name}-$scale');
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets('current task keeps its status glyph through recovery', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    host.event('a', 'message.start');
    host.event('a', 'todo.updated', {
      'revision': 3,
      'todos': [
        {
          'id': 'current',
          'content': 'Inspect the active result',
          'status': 'in_progress',
        },
      ],
    });
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileWorkspaceScreen(
          controller: controller,
          createBotsSession: () => BotsSession((_) async => const []),
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.byKey(const ValueKey(('live-work-tab', 1, false))));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    final tasks = find.byType(ProfileTodoPanel);
    expect(tasks, findsOneWidget);
    expect(
      find.descendant(of: tasks, matching: find.byType(StudioLoading)),
      findsNothing,
    );
    runtime.beginRecovery();
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileWorkspaceScreen(
          controller: controller,
          createBotsSession: () => BotsSession((_) async => const []),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Inspect the active result'), findsOneWidget);
    expect(
      find.descendant(of: tasks, matching: find.byType(StudioLoading)),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
  test('stock automatic and manual compression show their own activity', () {
    host.event('a', 'message.start');
    host.event('a', 'message.delta', {'text': 'Earlier response'});
    for (final kind in ['compacting', 'compressing']) {
      host.event('a', 'status.update', {'kind': kind});
      expect(label(), 'Summarizing conversation…');
      host.event('a', 'status.update', {'kind': 'process'});
      expect(label(), 'Summarizing conversation…');
      host.event('a', 'status.update', {'kind': 'compacted'});
      expect(label(), 'Writing response…');
    }
    runtime.completeTurn(failed: false, cancelled: false, error: null);
    runtime.beginCommand();
    host.event('a', 'status.update', {'kind': 'compressing'});
    expect(label(), 'Summarizing conversation…');
    runtime.finishCommand();
    expect(label(), 'Summarizing conversation…');
    host.event('a', 'status.update', {'kind': 'ready'});
    expect(label(), isNull);
  });

  test('compression retires on main progress and terminal evidence', () async {
    final progress = <String, Map<String, dynamic>>{
      'message.delta': {'text': 'Resumed'},
      'message.interim': {},
      'reasoning.delta': {'text': 'Resumed'},
      'reasoning.available': {'text': 'Resumed'},
      'tool.generating': {'name': 'web_search'},
      'tool.start': {'name': 'web_search', 'tool_id': 'search'},
      'tool.complete': {'name': 'web_search', 'tool_id': 'search'},
      'message.start': {},
      'message.complete': {'text': 'Done'},
      'turn.end': {},
      'error': {'message': 'Failed'},
      'session.info': {'running': false},
    };
    for (final event in progress.entries) {
      host.event('a', 'message.start');
      host.event('a', 'status.update', {'kind': 'compacting'});
      expect(chat.runtime.compacting, isTrue);
      host.event('a', event.key, event.value);
      expect(chat.runtime.compacting, isFalse, reason: event.key);
      expect(label(), isNot('Summarizing conversation…'), reason: event.key);
      await Future<void>.delayed(Duration.zero);
    }
  });

  test(
    'compression belongs to its chat and survives unrelated activity',
    () async {
      host.event('a', 'message.start');
      final read = runtime.captureRead();
      host.event('a', 'status.update', {'kind': 'compacting'});
      expect(read.current, isFalse);
      await controller.switchProfile('b');
      final other = await controller.createChat(canDispatch: () => true);
      host.event('b', 'message.start');
      host.event('b', 'message.delta', {'text': 'Other chat'});
      expect(other.runtime.compacting, isFalse);
      host.event('a', 'subagent.start', {'subagent_id': 'child'});
      host.event('a', 'session.usage', {
        'usage': {'compressions': 1},
      });
      host.event('a', 'session.info', {'running': true});
      expect(label(), 'Summarizing conversation… · 1 subagent active');
      host.event('a', 'clarify', {
        'request_id': 'city',
        'question': 'Which city?',
      });
      expect(label(), 'Waiting for your reply');
      runtime.beginRecovery();
      expect(label(), isNull);
      runtime.recovered();
      runtime.reconcileOpenRequests(const []);
      runtime.installResume({'session_id': 'a-runtime', 'running': true});
      expect(chat.runtime.compacting, isTrue);
      runtime.installResume({'session_id': 'a-runtime', 'running': false});
      expect(chat.runtime.compacting, isFalse);
      host.event('a', 'status.update', {'kind': 'compacting'});
      runtime.replaceRuntime('replacement');
      expect(chat.runtime.compacting, isFalse);
    },
  );

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('compression fits Studio $brightness at $scale text', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        host.event('a', 'message.start');
        host.event('a', 'subagent.start', {'subagent_id': 'child'});
        host.event('a', 'status.update', {'kind': 'compacting'});
        await tester.pumpWidget(
          RepaintBoundary(
            key: const ValueKey('compression-review'),
            child: MaterialApp(
              theme: wingTheme(brightness),
              builder: (_, child) => MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: ProfileWorkspaceScreen(
                controller: controller,
                createBotsSession: () => BotsSession((_) async => const []),
              ),
            ),
          ),
        );
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        final text = find.text('Summarizing conversation… · 1 subagent active');
        expect(text, findsOneWidget);
        await tester.pump();
        expect(find.byType(StudioLoading), findsOneWidget);
        expect(tester.widget<Text>(text).maxLines, isNull);
        final composer = find.byKey(const ValueKey('conversation-composer'));
        expect(
          tester.getBottomLeft(text).dy,
          lessThanOrEqualTo(tester.getTopLeft(composer).dy),
        );
        expect(tester.takeException(), isNull);
        if (capture != null) await capture(tester, '${brightness.name}-$scale');
        host.event('a', 'status.update', {'kind': 'compacted'});
        await tester.pump();
        expect(text, findsNothing);
        expect(find.byIcon(Icons.compress_rounded), findsNothing);
      });
    }
  }

  testWidgets('compression remains readable with reduced motion', (
    tester,
  ) async {
    host.event('a', 'status.update', {'kind': 'compressing'});
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: ProfileActivityStatus(
              runtime: chat.runtime,
              subagents: chat.subagents,
              unconfirmedSubagentIds: chat.unconfirmedSubagentIds,
              saving: chat.composer.observation.saving,
            ),
          ),
        ),
      ),
    );
    expect(find.text('Summarizing conversation…'), findsOneWidget);
    await tester.pump();
    expect(find.byType(StudioLoading), findsOneWidget);
    expect(find.byType(ShaderMask), findsNothing);
    await tester.pump();
    expect(find.byType(StudioLoading), findsOneWidget);
    expect(tester.binding.transientCallbackCount, 0);
  });

  for (final status in [
    ChatExecution.idle,
    ChatExecution.completed,
    ChatExecution.cancelled,
  ]) {
    test('$status has no active-work label', () {
      switch (status) {
        case ChatExecution.idle:
          runtime.resetCompleted();
        case ChatExecution.completed:
          runtime.completeTurn(failed: false, cancelled: false, error: null);
        case ChatExecution.cancelled:
          runtime.completeTurn(failed: false, cancelled: true, error: null);
        default:
          throw StateError('Unexpected fixture execution');
      }
      expect(label(), isNull);
    });
  }
  test('history failure asks for attention until recovered', () {
    runtime.reportError('History failed');
    expect(label(), 'History needs attention');
    runtime.reportError(null);
    expect(label(), isNull);
  });
  test('command execution reports work until it finishes', () {
    runtime.beginCommand();
    expect(label(), 'Running command…');
    runtime.finishCommand();
    expect(label(), isNull);
  });
  test('compact execution suppresses only generic work feedback', () {
    host.event('a', 'message.start');
    expect(label(executionInTranscript: true), isNull);
    host.event('a', 'status.update', {'kind': 'compacting'});
    expect(label(executionInTranscript: true), 'Summarizing conversation…');
    host.event('a', 'reasoning.delta', {'text': 'Inspect the result'});
    expect(label(executionInTranscript: true), isNull);
    host.event('a', 'clarify', {
      'request_id': 'city',
      'question': 'Which city?',
    });
    expect(label(executionInTranscript: true), 'Waiting for your reply');
    runtime.cancelRequest({'id': 'city', 'method': 'clarify'});
    runtime.completeTurn(failed: false, cancelled: false, error: null);
    runtime.beginCommand();
    expect(label(executionInTranscript: true), 'Running command…');
    runtime.finishCommand();
    runtime.failTurn('Turn failed');
    expect(label(executionInTranscript: true), 'Something went wrong');
  });

  test('unfinished child work stays visible after the main turn is idle', () {
    host.event('a', 'subagent.start', {'subagent_id': 'child'});
    expect(label(), 'Waiting for 1 subagent…');
  });
  test('submission feedback is reserved for the shared header', () {
    runtime.beginTurn(submitting: true);
    expect(label(), isNull);
  });
  test('failed turn has its own recovery status', () {
    runtime.failTurn('Turn failed');
    expect(label(), 'Something went wrong');
  });

  testWidgets('activity expands and fades, then fully collapses on cancel', (
    tester,
  ) async {
    Future<void> render({bool reducedMotion = false}) => tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reducedMotion),
          child: Scaffold(
            body: Column(
              children: [
                ProfileActivityStatus(
                  runtime: chat.runtime,
                  subagents: chat.subagents,
                  unconfirmedSubagentIds: chat.unconfirmedSubagentIds,
                  saving: chat.composer.observation.saving,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final row = find.byType(ProfileActivityStatus);
    await render();
    expect(tester.getSize(row).height, 0);
    runtime.beginTurn(submitting: false);
    await render();
    expect(tester.getSize(row).height, 0);
    await tester.pump(const Duration(milliseconds: 60));
    final entering = tester.getSize(row).height;
    expect(entering, greaterThan(0));
    expect(
      tester
          .widget<FadeTransition>(find.byType(FadeTransition).last)
          .opacity
          .value,
      inExclusiveRange(0, 1),
    );
    await tester.pump(const Duration(milliseconds: 200));
    final expanded = tester.getSize(row).height;
    expect(expanded, greaterThan(entering));

    runtime.completeTurn(failed: false, cancelled: true, error: null);
    await render();
    await tester.pump(const Duration(milliseconds: 60));
    expect(tester.getSize(row).height, inExclusiveRange(0, expanded));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.getSize(row).height, 0);
    expect(find.text('Stopped'), findsNothing);
    expect(find.text('Hermes is working…'), findsNothing);

    // A quick new turn during collapse must restore the current status.
    runtime.beginTurn(submitting: false);
    await render();
    await tester.pump(const Duration(milliseconds: 60));
    runtime.completeTurn(failed: false, cancelled: true, error: null);
    await render();
    await tester.pump(const Duration(milliseconds: 40));
    runtime.failTurn('Turn failed');
    await render();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.text('Hermes is working…'), findsNothing);

    await render(reducedMotion: true);
    runtime.completeTurn(failed: false, cancelled: true, error: null);
    await render(reducedMotion: true);
    expect(tester.getSize(row).height, 0);
    runtime.beginTurn(submitting: false);
    await render(reducedMotion: true);
    expect(tester.getSize(row).height, expanded);
    await tester.pump();
    expect(find.byType(StudioLoading), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('latest main event replaces writing and completed tool activity', () {
    host.event('a', 'message.start');
    host.event('a', 'message.delta', {'text': 'I will check.'});
    expect(label(), 'Writing response…');
    host.event('a', 'reasoning.delta', {'text': 'Planning the next step'});
    expect(label(), 'Thinking…');
    host.event('a', 'tool.generating', {'name': 'web_search'});
    expect(label(), 'Preparing Web search');
    host.event('a', 'tool.start', {
      'tool_id': 'search',
      'name': 'web_search',
      'context': 'Checking accommodation',
    });
    expect(label(), 'Using Web search · Checking accommodation');
    host.event('a', 'tool.complete', {
      'tool_id': 'search',
      'name': 'web_search',
    });
    expect(label(), 'Hermes is working…');
    // Accumulated text and reasoning remain in the transcript, not the status.
    expect(chat.reading.streaming, isNotEmpty);
    expect(
      chat.runtime.activityEntries.whereType<ChatReasoningEntry>().last.text,
      isNotEmpty,
    );
    host.event('a', 'message.delta', {'text': 'Here are the results.'});
    host.event('a', 'reasoning.available', {'text': 'Earlier reasoning'});
    expect(label(), 'Writing response…');
    host.event('a', 'message.interim');
    expect(label(), 'Hermes is working…');
  });

  test('parallel tools retain current work when another tool completes', () {
    host.event('a', 'message.start');
    host.event('a', 'tool.start', {'name': 'web_search', 'tool_id': 'one'});
    host.event('a', 'tool.start', {'name': 'read_file', 'tool_id': 'two'});
    host.event('a', 'tool.complete', {'name': 'read_file', 'tool_id': 'two'});
    expect(label(), 'Using Web search');
    host.event('a', 'tool.start', {
      'tool_id': 'one',
      'name': 'web_search',
      'context': 'Reading results',
    });
    expect(label(), 'Using Web search · Reading results');
    host.event('a', 'message.delta', {'text': 'Result'});
    host.event('a', 'tool.complete', {'tool_id': 'one'});
    expect(label(), 'Writing response…');
  });

  test('child updates never replace main activity or an input request', () {
    host.event('a', 'message.start');
    host.event('a', 'reasoning.delta', {'text': 'Planning'});
    host.event('a', 'subagent.start', {'subagent_id': 'child'});
    host.event('a', 'subagent.tool', {
      'subagent_id': 'child',
      'tool': 'read_file',
    });
    expect(label(), 'Thinking… · 1 subagent active');
    host.event('a', 'clarify', {
      'request_id': 'city',
      'question': 'Which city?',
    });
    expect(label(), 'Waiting for your reply');
    host.event('a', 'approval', {
      'request_id': 'file',
      'server_request_id': 'file-server',
      'command': 'Check a file',
    });
    expect(label(), 'Waiting for your approval');
    runtime.beginRecovery();
    expect(label(), isNull);
    runtime.recovered();
    runtime.reconcileOpenRequests(const []);
    runtime.cancelRequest({'id': 'file-server', 'method': 'approval'});
    runtime.completeTurn(failed: false, cancelled: false, error: null);
    expect(label(), 'Waiting for 1 subagent…');
    host.event('a', 'subagent.complete', {
      'subagent_id': 'child',
      'status': 'completed',
    });
    expect(label(), isNull);
  });

  test(
    'same-name tools retain latest context after a third call completes',
    () {
      host.event('a', 'message.start');
      host.event('a', 'tool.start', {'name': 'web_search', 'tool_id': 'one'});
      host.event('a', 'tool.start', {'name': 'web_search', 'tool_id': 'two'});
      host.event('a', 'tool.start', {'name': 'read_file', 'tool_id': 'three'});
      host.event('a', 'tool.start', {
        'tool_id': 'one',
        'name': 'web_search',
        'context': 'Latest search context',
      });
      expect(label(), 'Using Web search · Latest search context');
      host.event('a', 'tool.complete', {'tool_id': 'three'});
      expect(label(), 'Using Web search · Latest search context');
    },
  );

  test('a new submission clears the previous execution phase', () async {
    host.event('a', 'message.start');
    host.event('a', 'tool.start', {'name': 'web_search', 'tool_id': 'one'});
    runtime.recovered();
    runtime.reconcileOpenRequests(const []);
    runtime.cancelRequest({'id': 'file-server', 'method': 'approval'});
    runtime.completeTurn(failed: false, cancelled: false, error: null);
    chat.composer.editText('Next question');
    await controller.send(chat);
    expect(label(), 'Hermes is working…');
    expect(chat.runtime.tool, isNull);
  });

  test('preparation before tool ID assignment does not leave phantom work', () {
    host.event('a', 'message.start');
    host.event('a', 'tool.generating', {'name': 'web_search'});
    host.event('a', 'tool.start', {'name': 'web_search', 'tool_id': 'one'});
    host.event('a', 'tool.complete', {'tool_id': 'one'});
    expect(label(), 'Hermes is working…');
    expect(
      chat.runtime.toolActivities.where((item) => !item.isTerminal),
      isEmpty,
    );
  });

  test(
    'reconnect waits for fresh activity instead of reusing old text',
    () async {
      host.event('a', 'message.start');
      host.event('a', 'tool.start', {'name': 'web_search', 'tool_id': 'one'});
      host.running = true;
      host.inflight = {'assistant': 'Previous partial text', 'streaming': true};
      await controller.reconnect(chat.key.workspace);
      expect(label(), 'Hermes is working…');
      host.event('a', 'reasoning.delta', {'text': 'Next step'});
      expect(label(), 'Thinking…');
    },
  );

  testWidgets('live events update the row and stop animation for input', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: controller,
            builder: (_, _) => ProfileActivityStatus(
              runtime: chat.runtime,
              subagents: chat.subagents,
              unconfirmedSubagentIds: chat.unconfirmedSubagentIds,
              saving: chat.composer.observation.saving,
            ),
          ),
        ),
      ),
    );
    expect(find.text('Waiting for your message'), findsNothing);
    expect(tester.getSize(find.byType(ProfileActivityStatus)).height, 0);
    expect(find.byType(StudioLoading), findsNothing);
    expect(find.byType(ShaderMask), findsNothing);
    host.event('a', 'message.start');
    host.event('a', 'reasoning.delta', {'text': 'Planning'});
    await tester.pump();
    expect(find.text('Thinking…'), findsOneWidget);
    await tester.pump();
    expect(find.byType(StudioLoading), findsOneWidget);
    expect(find.byType(ShaderMask), findsNothing);
    host.event('a', 'clarify', {
      'request_id': 'city',
      'question': 'Which city?',
    });
    await tester.pump();
    expect(find.text('Waiting for your reply'), findsOneWidget);
    expect(find.byType(StudioLoading), findsNothing);
    expect(find.byType(ShaderMask), findsNothing);
  });

  testWidgets('status stays below scrolling history and above the keyboard', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    chat.reading.installSavedHistory(
      List.generate(
        30,
        (i) => {
          'id': i,
          'role': 'user',
          'content': 'Message $i with enough text to fill the history.',
        },
      ),
    );
    host.event('a', 'message.start');
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileWorkspaceScreen(
          controller: controller,
          createBotsSession: () => BotsSession((_) async => const []),
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final status = find.byKey(const ValueKey('profile-activity-status'));
    final composer = find.byKey(const ValueKey('conversation-composer'));
    final transcript = find.byType(ProfileTranscript);
    expect(
      tester.getBottomLeft(transcript).dy,
      lessThanOrEqualTo(tester.getTopLeft(status).dy),
    );
    expect(
      tester.getBottomLeft(status).dy,
      lessThanOrEqualTo(tester.getTopLeft(composer).dy),
    );
    final position = tester.getTopLeft(status);
    await tester.drag(transcript, const Offset(0, 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.getTopLeft(status), position);
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    await tester.pump();
    expect(
      tester.getBottomLeft(composer).dy,
      lessThanOrEqualTo(
        (tester.view.physicalSize.height - tester.view.viewInsets.bottom) /
            tester.view.devicePixelRatio,
      ),
    );
    expect(
      tester.getBottomLeft(status).dy,
      lessThanOrEqualTo(tester.getTopLeft(composer).dy),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('long status fits large text and respects reduced motion', (
    tester,
  ) async {
    host.event('a', 'message.start');
    host.event('a', 'tool.start', {
      'name': 'web_search',
      'context': 'Searching many sources for a very long accommodation request',
    });
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            textScaler: TextScaler.linear(2),
            disableAnimations: true,
          ),
          child: Scaffold(
            body: SizedBox(
              width: 320,
              child: ProfileActivityStatus(
                runtime: chat.runtime,
                subagents: chat.subagents,
                unconfirmedSubagentIds: chat.unconfirmedSubagentIds,
                saving: chat.composer.observation.saving,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(StudioLoading), findsOneWidget);
    expect(find.byTooltip(label()!), findsOneWidget);
    expect(find.byType(ShaderMask), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
