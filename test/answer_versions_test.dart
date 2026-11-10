import 'support/composer_fixture.dart' show emitChatEvent;
import 'support/canonical_gateway_fixture.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/widgets/profile_tool_activity.dart';
import 'package:wing/core/models/chat_runtime.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'helpers/pump_markdown_widget.dart';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/answer_versions.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/profiles_repository.dart';
import 'package:wing/core/services/ws_client.dart';
import 'package:wing/core/widgets/answer_actions.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/process_batch_fixture.dart';
import 'composer_references_test.dart' show ReferenceHost;
import 'package:wing/core/models/composer_reference.dart';

Future<void> _waitUntil(bool Function() condition) async {
  await Future<void>(() async {
    while (!condition()) {
      await Future<void>.delayed(Duration.zero);
    }
  }).timeout(const Duration(seconds: 5));
}

class AnswerHost {
  final revisions = <String, int>{};
  final gateways = <String, ProfileGateway>{};
  final histories = <String, List<Map<String, dynamic>>>{};
  final parents = <String, String>{};
  final calls = <(String, Map<String, dynamic>)>[];
  Completer<void>? branchDelay;
  Object? branchError;
  Completer<void>? branchReadDelay;
  String? branchReadSession;
  void Function(List<Map<String, dynamic>>)? alterBranch;
  List<Map<String, dynamic>>? branchReplyMessages;
  Completer<void>? submitDelay;
  Completer<void>? resumeDelay;
  Completer<void>? interruptRequested;
  bool running = false;
  int executionGeneration = 0;
  String? resumedRuntimeOverride;
  int historyReads = 0;
  void Function(int count)? beforeHistoryRead;
  Object? submitError;
  Object? mutationError;
  Completer<void>? mutationDelay;
  final admissionReceipts = <String, Map<String, dynamic>>{};
  bool submitErrorAfterAcceptance = false;
  int busySubmissions = 0;
  bool omitRowIds = false;
  bool omitSessionParent = false;
  bool clearSessionParent = false;
  bool omitListParent = false;
  bool clearListParent = false;
  int next = 0;
  int nextRow = 10000;
  ReferenceHost? references;

  bool shown(Map<String, dynamic> message) => !isHiddenAnswerMessage(message);

  List<Map<String, dynamic>> history(String profile, String id) =>
      histories.putIfAbsent(
        '$profile/$id',
        () => [
          {'role': 'user', 'text': 'Original prompt', 'row_id': 1},
          {'role': 'tool', 'text': 'Tool output', 'row_id': 2},
          {'role': 'assistant', 'text': 'Original answer', 'row_id': 3},
          {'role': 'user', 'text': 'Follow-up', 'row_id': 4},
          {'role': 'assistant', 'text': 'Later answer', 'row_id': 5},
        ],
      );

  // Stock ec3249919accf7bc51f780dcff663e8f19a0e176:
  // hermes_state_mutation_branch.py clones active rows by saved ID, while
  // hermes_state_messages.py exposes numeric active/compacted flags.
  void addCompressedContext() {
    for (final row in history('a', 'original')) {
      row['row_id'] = (row['row_id'] as int) + 100;
    }
    history('a', 'original').insertAll(0, [
      {
        'role': 'user',
        'text': 'Archived prompt',
        'row_id': 1,
        'active': 0,
        'compacted': 1,
      },
      {
        'role': 'assistant',
        'text': 'Archived answer',
        'row_id': 2,
        'active': 0,
        'compacted': 1,
      },
      {
        'role': 'user',
        'text': 'Compressed context summary',
        'row_id': 100,
        'active': 1,
        'display_kind': 'hidden',
        '_compressed_summary': true,
      },
    ]);
  }

  Map<String, dynamic> historyPage(
    String profile,
    String path,
    Map<String, String> query,
  ) {
    final id = Uri.decodeComponent(path.split('/')[1]);
    final rows = history(profile, id).where((row) {
      final active = row['active'] != 0;
      return active ||
          (query['include_compacted'] == 'true' && row['compacted'] == 1);
    }).toList();
    final offset = int.parse(query['offset']!);
    final limit = int.parse(query['limit']!);
    final selected = query['order'] == 'oldest'
        ? rows.skip(offset).take(limit).toList()
        : rows.reversed.skip(offset).take(limit).toList().reversed.toList();
    return {
      'session_id': id,
      'pagination': {
        'limit': limit,
        'offset': offset,
        'order': query['order'],
        'returned': selected.length,
      },
      // Model the wire producer independently of Wing's display conversion.
      'messages': [
        for (final row in selected)
          {
            ...row,
            'id': row['row_id'],
            'content': row['content'] ?? row['text'],
          },
      ],
    };
  }

  ProfileGateway gateway(WorkspaceScope scope) {
    late final ProfileGateway gateway;
    gateway = ProfileGateway(
      scope: scope,
      connect: () async {
        // Short-lived project readers have no event subscription. Keep emitted
        // turn events addressed to the controller's live transport.
        if (gateway.onEvent != null) gateways[scope.profileName] = gateway;
      },
      discover: () async => const ProfileDiscovery(
        profiles: [
          HermesProfile(name: 'a'),
          HermesProfile(name: 'b'),
        ],
        currentName: 'a',
        activeName: 'a',
      ),
      get: (path, query) async {
        if (path == 'model/info') return <String, dynamic>{};
        if (path == 'model/options') return {'providers': <dynamic>[]};
        if (path == 'logs') return {'file': 'gui', 'lines': <String>[]};
        if (path == 'sessions/$branchReadSession/messages' &&
            query['order'] == 'oldest') {
          await branchReadDelay?.future;
        }
        return references != null &&
                (path == 'profiles' || path.startsWith('files'))
            ? references!.read(path, query)
            : path == 'sessions'
            ? {
                'offset': int.parse(query['offset']!),
                'limit': int.parse(query['limit']!),
                'total': 1 + parents.length,
                'sessions': [
                  {
                    'id': 'original',
                    'title': 'Original chat',
                    'unread': false,
                    'profile': scope.profileName,
                  },
                  for (final entry in parents.entries)
                    {
                      'id': entry.key,
                      'title': 'Branched chat',
                      'profile': scope.profileName,
                      if (clearListParent)
                        'parent_session_id': null
                      else if (!omitListParent)
                        'parent_session_id': entry.value,
                    },
                ],
              }
            : path.startsWith('sessions/') && path.endsWith('/messages')
            ? historyPage(scope.profileName, path, query)
            : throw StateError('Unhandled fixture GET: $path');
      },
      rpc: (method, params) async {
        calls.add((method, params));
        if (method == 'process.list') return {'processes': <dynamic>[]};
        final profile = scope.profileName;
        final id = (params['session_id'] as String? ?? 'original').replaceFirst(
          'runtime-',
          '',
        );
        Map<String, dynamic> session(String child) => {
          ...canonicalSnapshotFields,
          'revision': revisions['$profile/runtime-$child'] ?? 0,
          'session_id': resumedRuntimeOverride ?? 'runtime-$child',
          'running': running,
          'execution_generation': executionGeneration,
          'stored_session_id': child,
          if (clearSessionParent)
            'parent_session_id': null
          else if (!omitSessionParent && parents.containsKey(child))
            'parent_session_id': parents[child],
          'messages':
              (parents.containsKey(child) && branchReplyMessages != null
                      ? branchReplyMessages!
                      : history(profile, child).where(shown))
                  .map((row) => Map<String, dynamic>.from(row))
                  .toList(),
          'info': {'profile_name': profile},
          'title': 'Branched chat',
        };
        switch (method) {
          case 'commands.catalog':
            return {
              'pairs': [
                ['/branch', 'Branch the saved conversation'],
                ['/fork', 'Fork the saved conversation'],
              ],
            };
          case 'session.context_breakdown':
            return {
              'context_used': 0,
              'context_max': 32768,
              'context_percent': 0,
            };
          case 'projects.tree':
            return {'projects': <Map<String, dynamic>>[]};
          case 'session.resume':
            await resumeDelay?.future;
            return session(id);
          case 'session.interrupt':
            if (params['execution_generation'] is! int) {
              throw const FormatException('Missing interrupt generation');
            }
            if (interruptRequested case final signal?
                when !signal.isCompleted) {
              signal.complete();
            }
            return {
              'execution_state': running ? 'running' : 'idle',
              'execution_generation': executionGeneration,
            };
          case 'session.history':
            beforeHistoryRead?.call(++historyReads);
            return {
              'messages': history(profile, id)
                  .where(shown)
                  .where((m) => m['active'] != 0)
                  .map(
                    (m) => {
                      ...m,
                      if (omitRowIds && m['role'] == 'user') 'row_id': null,
                    },
                  )
                  .toList(),
            };
          case 'session.mutate':
            await mutationDelay?.future;
            final payload = params['payload'] as Map;
            if (mutationError != null) throw mutationError!;
            if (busySubmissions > 0) {
              busySubmissions--;
              throw JsonRpcError(
                'session.mutate',
                'Session is busy',
                reason: 'session_busy',
              );
            }
            revisions['$profile/${params['session_id']}'] =
                (params['expected_revision'] as int) + 1;
            final result = <String, dynamic>{
              'session_id': params['session_id'],
              'revision': (params['expected_revision'] as int) + 1,
              'execution_generation': params['expected_generation'],
              'operation': params['operation'],
            };
            if (params['operation'] == 'rewind') {
              final rows = history(profile, id);
              final index = rows.indexWhere(
                (row) => row['row_id'] == payload['target_message_id'],
              );
              if (index < 0) {
                throw JsonRpcError(
                  'session.mutate',
                  'Target changed',
                  reason: 'revision_conflict',
                );
              }
              rows.removeRange(index, rows.length);
              return result;
            }
            if (params['operation'] != 'branch') return result;
            await branchDelay?.future;
            if (branchError != null) throw branchError!;
            final child = 'child-${++next}';
            final source = history(profile, id);
            final boundary = source.indexWhere(
              (row) =>
                  row['row_id'] == payload['through_message_id'] &&
                  row['active'] != 0,
            );
            if (boundary < 0) throw StateError('Missing branch boundary');
            histories['$profile/$child'] = source
                .take(boundary + 1)
                .where((row) => row['active'] != 0)
                .map((m) => Map<String, dynamic>.from(m))
                .toList();
            for (var i = 0; i < histories['$profile/$child']!.length; i++) {
              histories['$profile/$child']![i]['row_id'] = next * 1000 + i + 1;
            }
            parents[child] = id;
            alterBranch?.call(histories['$profile/$child']!);
            return {...result, 'branched_session_id': child};
          case 'prompt.submit':
            final input = '$profile:$id:${params['submission_id']}';
            if (admissionReceipts.containsKey(input)) {
              return admissionReceipts[input]!;
            }
            await submitDelay?.future;
            if (submitError != null && !submitErrorAfterAcceptance) {
              throw submitError!;
            }
            final rows = history(profile, id);
            rows.add({
              'role': 'user',
              'text': params['text'],
              'row_id': nextRow++,
            });
            rows.add({
              'role': 'assistant',
              'text': 'New answer $next',
              'row_id': nextRow++,
            });
            final receipt = canonicalReceipt(
              params,
              admissionId: 'admission-${admissionReceipts.length + 1}',
            );
            admissionReceipts[input] = receipt;
            if (submitError != null) throw submitError!;
            return receipt;
        }
        return {};
      },
    );
    return gateway;
  }

  Future<void> complete(ProfileChat chat) async {
    gateways[chat.key.workspace.profileName]!.onEvent!(
      StreamEvent(
        type: 'message.complete',
        sessionId: chat.runtime.runtimeId,
        data: const {},
      ),
    );
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  const captureFork = bool.fromEnvironment('CAPTURE_RUNNING_FORK');
  setUpAll(() async {
    if (!captureFork) return;
    for (final font in {
      'Roboto': 'build/studio-roboto.ttf',
      'MaterialIcons': 'build/studio-icons.otf',
      'WingIcons': 'assets/fonts/wing-icons.ttf',
    }.entries) {
      await (FontLoader(
            font.key,
          )..addFont(File(font.value).readAsBytes().then(ByteData.sublistView)))
          .load();
    }
  });
  late AnswerHost host;
  late SharedPreferences preferences;
  late ProfileWorkspaceController controller;
  late AppPreferences appPreferences;
  late ProfileChat original;

  ProfileWorkspaceController makeController() => ProfileWorkspaceController(
    connectionIdentity: 'host-settings',
    access: ConnectionAccess(
      connection: SavedConnection(
        id: 'host',
        label: 'Host',
        host: 'localhost',
        port: 1,
        apiKey: '',
      ),
      dashboardOAuth: null,
    ),
    preferences: preferences,
    appPreferences: appPreferences,
    gatewayFactory: host.gateway,
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    host = AnswerHost();
    controller = makeController();
    await controller.initialize();
    await controller.openSession(
      ProfileSessionKey(controller.current!.scope, 'original'),
    );
    original = controller.current!.chat!;
  });
  tearDown(() {
    controller.dispose();
    appPreferences.dispose();
  });

  Finder forkLoading() => find.byWidgetPredicate(
    (widget) => widget is StudioLoading && widget.label == 'Forking chat',
  );

  void event(String type, [Map<String, dynamic> data = const {}]) {
    emitChatEvent(controller, original, type, data);
  }

  test(
    'canonical fork waits for the running source without interrupting it',
    () async {
      event('message.start');
      event('tool.start', {'tool_id': 'live-tool', 'name': 'terminal'});
      final activity = original.runtime.mainToolActivity;
      await controller.updateDraft(original, 'Keep this draft');
      expect(controller.canBranchAnswer(original), isFalse);
      expect(await controller.branchAnswer(original, 2), isNull);
      expect(original.runtime.mainToolActivity, same(activity));
      expect(original.composer.observation.text, 'Keep this draft');
      expect(host.calls.where((call) => call.$1 == 'session.mutate'), isEmpty);
      event('message.complete');
      await Future<void>.delayed(Duration.zero);
      expect(controller.canBranchAnswer(original), isTrue);
      final child = await controller.branchAnswer(original, 2);
      expect(child, isNotNull);
      expect(original.composer.observation.text, 'Keep this draft');
      expect(
        host.calls.where((call) => call.$1 == 'session.interrupt'),
        isEmpty,
      );
    },
  );

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'fork saved answer shows failure and retry ${brightness.name} $scale',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          host.addCompressedContext();
          await controller.refreshHistory(original);
          final frame = GlobalKey();
          await tester.pumpWidget(
            MaterialApp(
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(scale),
                  disableAnimations: scale == 2,
                ),
                child: RepaintBoundary(key: frame, child: child!),
              ),
              home: ProfileWorkspaceScreen(
                controller: controller,
                createBotsSession: () => BotsSession((_) async => const []),
              ),
            ),
          );
          Future<void> picture(String state) async {
            if (!captureFork) return;
            await tester.settleMarkdown();
            await tester.pump();
            await tester.runAsync(() async {
              final bitmap =
                  await (frame.currentContext!.findRenderObject()!
                          as RenderRepaintBoundary)
                      .toImage();
              try {
                final bytes = await bitmap.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                final directory = Directory(
                  'build/design-previews/running-fork',
                )..createSync(recursive: true);
                await File(
                  '${directory.path}/${brightness.name}-$scale-$state.png',
                ).writeAsBytes(bytes!.buffer.asUint8List());
              } finally {
                bitmap.dispose();
              }
            });
          }

          await tester.pumpAndSettle();
          await tester.pump(const Duration(milliseconds: 300));
          await tester.settleMarkdown();
          final actions = find.byKey(const ValueKey('answer-actions-103'));
          await tester.ensureVisible(actions);
          await tester.pump(const Duration(milliseconds: 300));
          final fork = find.descendant(
            of: actions,
            matching: find.byTooltip('Branch in new session'),
          );
          expect(tester.widget<AnswerActions>(actions).onBranch, isNotNull);
          expect(tester.widget<AnswerActions>(actions).onRegenerate, isNotNull);
          await picture('available');
          host.branchDelay = Completer<void>();
          host.branchError = StateError('Fork failed; try again');
          host.branchReadDelay = Completer<void>();
          host.branchReadSession = 'original';
          await tester.tap(fork);
          await tester.pump();
          expect(find.text('New chat'), findsOneWidget);
          expect(actions, findsNothing);
          await tester.pump(const Duration(milliseconds: 100));
          expect(original.branchingAnswer, isTrue);
          expect(find.text('New chat'), findsOneWidget);
          expect(actions, findsNothing);
          expect(
            find.byKey(const Key('profile-message-composer')),
            findsNothing,
          );
          expect(original.runtime.execution, ChatExecution.idle);
          final header = find.byKey(const ValueKey('studio-loading-slot'));
          expect(
            find.descendant(of: header, matching: forkLoading()),
            findsOneWidget,
          );
          final glyph = find.descendant(
            of: forkLoading(),
            matching: find.byType(CustomPaint),
          );
          expect(glyph, findsOneWidget);
          final paintedBounds = tester.getRect(glyph);
          expect(paintedBounds.isEmpty, isFalse);
          expect(tester.getRect(header).contains(paintedBounds.center), isTrue);
          expect(
            tester
                .getRect(find.byType(ProfileWorkspaceScreen))
                .intersect(paintedBounds),
            paintedBounds,
          );
          await picture('pending');
          expect(
            host.calls.where(
              (call) =>
                  call.$1 == 'session.mutate' &&
                  call.$2['operation'] == 'branch',
            ),
            isEmpty,
          );
          await tester.runAsync(() async {
            host.branchReadDelay!.complete();
            await Future<void>.delayed(Duration.zero);
          });
          await tester.pump();
          expect(
            host.calls.where(
              (call) =>
                  call.$1 == 'session.mutate' &&
                  call.$2['operation'] == 'branch',
            ),
            hasLength(1),
          );
          expect(original.branchingAnswer, isTrue);
          expect(find.text('New chat'), findsOneWidget);
          expect(forkLoading(), findsOneWidget);
          await tester.runAsync(() async {
            host.branchDelay!.complete();
            await Future<void>.delayed(Duration.zero);
          });
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.textContaining('Fork failed; try again'), findsOneWidget);
          expect(original.branchingAnswer, isFalse);
          expect(find.byTooltip('Retry').hitTestable(), findsOneWidget);
          expect(forkLoading(), findsNothing);
          expect(original.runtime.execution, ChatExecution.idle);
          await picture('failed');
          host.branchError = null;
          host.branchReadDelay = Completer<void>();
          host.branchReadSession = 'child-1';
          await tester.tap(find.byTooltip('Retry'));
          await tester.runAsync(() async {
            await _waitUntil(() => host.parents.containsKey('child-1'));
          });
          await tester.pump();
          expect(controller.current!.chat, same(original));
          expect(original.branchingAnswer, isTrue);
          expect(find.text('New chat'), findsOneWidget);
          await tester.pump();
          expect(forkLoading(), findsOneWidget);
          expect(actions, findsNothing);
          await tester.runAsync(() async {
            host.branchReadDelay!.complete();
            await Future<void>.delayed(Duration.zero);
          });
          await tester.pump();
          expect(controller.current!.chat, isNot(same(original)));
          expect(original.runtime.execution, ChatExecution.idle);
          await tester.pump(const Duration(milliseconds: 300));
          expect(forkLoading(), findsNothing);
          expect(
            find.byKey(const Key('profile-message-composer')),
            findsOneWidget,
          );
          await picture('branched');
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  testWidgets('leaving the fork destination retires late navigation', (
    tester,
  ) async {
    await controller.updateDraft(original, 'Keep this draft');
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileWorkspaceScreen(
          controller: controller,
          createBotsSession: () => BotsSession((_) async => const []),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));
    final actions = find.byKey(const ValueKey('answer-actions-3'));
    await tester.ensureVisible(actions);
    host.branchDelay = Completer<void>();
    await tester.tap(
      find.descendant(
        of: actions,
        matching: find.byTooltip('Branch in new session'),
      ),
    );
    await tester.pump();
    expect(find.text('New chat'), findsOneWidget);
    expect(actions, findsNothing);
    await tester.tap(find.byTooltip('Back'));
    await tester.pump();
    expect(controller.current!.chat, isNull);
    event('message.delta', {'text': 'The original work continues.'});
    await tester.runAsync(() async {
      host.branchDelay!.complete();
      await _waitUntil(() => !original.branchingAnswer);
    });
    await tester.pump();
    expect(controller.current!.chat, isNull);
    expect(forkLoading(), findsNothing);
    expect(original.branchingAnswer, isFalse);
    expect(original.runtime.execution, ChatExecution.idle);
    expect(original.composer.observation.text, 'Keep this draft');
    expect(
      controller.current!.sessions.any((row) => row['id'] == 'child-1'),
      isTrue,
    );
    await tester.pumpWidget(const SizedBox());
  });

  for (final command in ['branch', 'fork']) {
    test('$command refuses while a reply is running', () async {
      event('message.start');
      await controller.updateDraft(original, '/$command');
      await controller.send(original);
      expect(controller.current!.chat, same(original));
      expect(host.calls.where((call) => call.$1 == 'session.mutate'), isEmpty);
      expect(original.runtime.execution, ChatExecution.running);
    });
  }

  for (final pendingInput in ['approval', 'clarify']) {
    test('fork remains unavailable during pending $pendingInput', () async {
      event('message.start');
      event(
        pendingInput,
        pendingInput == 'approval'
            ? {
                'request_id': 'pending',
                'command': 'echo hello',
                'choices': ['once', 'deny'],
              }
            : {
                'request_id': 'pending',
                'questions': [
                  {'qid': 'q0', 'question': 'Which room?'},
                ],
              },
      );
      expect(original.runtime.needsInput, isTrue);
      final child = await controller.branchAnswer(original, 2);
      expect(child, isNull);
      expect(original.runtime.needsInput, isTrue);
      expect(
        host.calls.where(
          (call) => {
            'approval.respond',
            'clarify.lock',
            'request.answer',
            'session.interrupt',
          }.contains(call.$1),
        ),
        isEmpty,
      );
    });
  }

  test(
    'source completion during a fork is not reset by branch settlement',
    () async {
      host.branchDelay = Completer<void>();
      final pending = controller.branchAnswer(original, 2);
      await Future<void>.delayed(Duration.zero);
      event('message.start');
      event('message.complete');
      expect(original.runtime.execution, ChatExecution.completed);
      host.branchDelay!.complete();
      expect(await pending, isNotNull);
      expect(original.runtime.execution, ChatExecution.completed);
      expect(original.branchingAnswer, isFalse);
    },
  );

  for (final delivery in [
    processBatchEnvelope,
    '[IMPORTANT: Background process 1 completed normally (exit code 0).\nCommand: private\nOutput:\n]',
    'Message from 🤖 Hermes: private delivery',
  ]) {
    test(
      'internal delivery cannot be edited or replayed: ${delivery.substring(0, 20)}',
      () async {
        host.history('a', 'original')[0]['text'] = delivery;
        await controller.refreshHistory(original);
        await expectLater(
          controller.editSavedPrompt(
            original,
            original.reading.messages.first,
            'replacement',
          ),
          throwsStateError,
        );
        await expectLater(
          controller.branchAnswer(original, 2, regenerate: true),
          throwsStateError,
        );
        expect(host.calls.where((call) => call.$1 == 'prompt.submit'), isEmpty);
        expect(host.history('a', 'original').first['text'], delivery);
      },
    );
  }

  test('stored multimodal rows use the gateway text projection', () {
    expect(
      answerMessageText({
        'content': [
          'one',
          {'type': 'text', 'text': 'two'},
        ],
      }),
      'onetwo',
    );
    expect(
      isBranchMessage({
        'role': 'user',
        'content': [
          {
            'type': 'image_url',
            'image_url': {'url': 'https://example.test/qa.png'},
          },
        ],
      }),
      isTrue,
    );
    expect(
      isBranchMessage({
        'role': 'assistant',
        'content': '',
        'tool_calls': [
          {'id': 'qa-tool'},
        ],
      }),
      isFalse,
    );
  });

  test('saved user prompts use the Desktop attached-context projection', () {
    const marker = '--- Attached Context ---';
    const block = '''📄 @file:fixture.txt (4 tokens)
```text
fixture-value-amber-729
```''';
    final expanded =
        '@file:fixture.txt\n\nSummarize this file.\n\n$marker\n\n$block';
    final duplicated = '$expanded\n\n$marker\n\n$block\n\n$block';

    expect(
      answerMessageDisplayText({'role': 'user', 'content': expanded}),
      '@file:fixture.txt\n\nSummarize this file.',
    );
    expect(
      answerMessageDisplayText({'role': 'user', 'content': duplicated}),
      '@file:fixture.txt\n\nSummarize this file.',
      reason: 'Desktop treats the first producer marker as the boundary',
    );
    expect(
      answerMessageDisplayText({
        'role': 'user',
        'content': 'Look here\n\n$marker\n\n$block',
      }),
      '@file:fixture.txt\n\nLook here',
      reason: 'References stripped by older producers are restored once',
    );
  });

  test('user display projection preserves non-context message forms', () {
    expect(
      answerMessageDisplayText({
        'role': 'user',
        'content': [
          {'type': 'text', 'text': 'serialized '},
          {'type': 'input_text', 'text': 'prompt'},
        ],
      }),
      'serialized prompt',
    );
    expect(
      answerMessageDisplayText({
        'role': 'user',
        'content': 'Email me at qa@example.test',
      }),
      'Email me at qa@example.test',
    );
    expect(
      answerMessageDisplayText({
        'role': 'user',
        'content': 'Visible\n\n--- Context Warnings ---\n- unavailable',
      }),
      'Visible',
    );
    expect(
      answerMessageDisplayText({
        'role': 'user',
        'content': 'wire text',
        'display_content': 'visible text',
      }),
      'visible text',
    );
    expect(
      answerMessageDisplayText({
        'role': 'user',
        'content': 'fallback text',
        'display_content': null,
      }),
      'fallback text',
    );
  });

  test(
    'saved multimodal user display hides image bytes but retains raw text',
    () {
      const encoded = 'data:image/png;base64,QA_IMAGE_BYTES';
      final saved = <String, dynamic>{
        'role': 'user',
        'row_id': 17,
        'content': [
          {'type': 'text', 'text': 'Read this image'},
          {
            'type': 'image_url',
            'image_url': {'url': encoded},
          },
        ],
      };
      final row = answerHistoryRows([saved]).single;
      expect(answerMessageDisplayText(row), 'Read this image\n[image]');
      expect(answerMessageText(row), answerMessageText(saved));
      expect(answerMessageText(row), contains(encoded));
      expect(answerMessageId(row), 17);
      expect(
        answerMessageDisplayText({...saved, 'display_content': 'Visible'}),
        'Visible',
      );
      expect(
        answerMessageDisplayText({...saved, 'display_content': null}),
        'Read this image\n[image]',
      );
      expect(
        answerMessageDisplayText({'role': 'user', 'content': encoded}),
        encoded,
        reason: 'Do not remove data URLs authored as plain text',
      );
      final assistant = {...saved, 'role': 'assistant'};
      expect(
        answerMessageDisplayText(answerHistoryRows([assistant]).single),
        answerMessageText(assistant),
      );
    },
  );

  test('assistant content is never treated as attached user context', () {
    const content = '''Answer code:
--- Attached Context ---
```dart
void main() {}
```''';
    expect(
      answerMessageDisplayText({'role': 'assistant', 'content': content}),
      content,
    );
  });

  test('hidden notices count toward the persisted fork boundary', () async {
    host.history('a', 'original').insert(1, {
      'role': 'user',
      'text': '[System: model changed]',
      'row_id': 8,
    });
    final child = (await controller.branchAnswer(original, 2))!;
    expect(
      child.reading.messages
          .where((m) => !isHiddenAnswerMessage(m))
          .map(answerMessageText),
      ['Original prompt', 'Tool output', 'Original answer'],
    );
    expect(
      host.calls
          .lastWhere(
            (c) => c.$1 == 'session.mutate' && c.$2['operation'] == 'branch',
          )
          .$2['payload']['through_message_id'],
      3,
    );
    expect(host.history('a', 'original').length, 6);
  });

  test(
    'stock fork receipt retains tools independently of visible prose',
    () async {
      final child = (await controller.branchAnswer(original, 2))!;
      // Stock branch_in_transaction clones active database rows, including tools.
      // Literal expectations must not reuse isBranchMessage/answerHistoryRows.
      expect(host.history('a', child.key.sessionId).map((row) => row['role']), [
        'user',
        'tool',
        'assistant',
      ]);
      expect(host.history('a', child.key.sessionId).map((row) => row['text']), [
        'Original prompt',
        'Tool output',
        'Original answer',
      ]);
    },
  );

  test('stock REST archive selection uses numeric storage flags', () {
    host.history('a', 'original').insertAll(0, [
      {
        'row_id': 10,
        'role': 'user',
        'text': 'Archived',
        'active': 0,
        'compacted': 1,
      },
      {
        'row_id': 11,
        'role': 'user',
        'text': 'Rewound',
        'active': 0,
        'compacted': 0,
      },
    ]);
    List<Object?> ids(bool archived) =>
        (host.historyPage('a', 'sessions/original/messages', {
                  'offset': '0',
                  'limit': '500',
                  'order': 'oldest',
                  'include_compacted': '$archived',
                })['messages']
                as List)
            .map((row) => row['id'])
            .toList();
    expect(ids(true), [10, 1, 2, 3, 4, 5]);
    expect(ids(false), [1, 2, 3, 4, 5]);
  });

  test('stock REST rows retain structured content without Wing projection', () {
    const content = [
      {'type': 'text', 'text': 'Saved answer'},
    ];
    host.history('a', 'original')[2]['content'] = content;
    final page = host.historyPage('a', 'sessions/original/messages', {
      'offset': '0',
      'limit': '500',
      'order': 'oldest',
      'include_compacted': 'false',
    });
    expect(page['messages'][2]['content'], content);
  });

  test(
    'fork after compression verifies active context instead of archived history',
    () async {
      host.addCompressedContext();
      await controller.refreshHistory(original);
      final selected = original.reading.messages.indexWhere(
        (row) => row['id'] == 103,
      );
      final child = (await controller.branchAnswer(original, selected))!;
      expect(controller.current!.chat, same(child));
      expect(
        child.reading.messages
            .where((row) => !isHiddenAnswerMessage(row))
            .map(answerMessageText),
        ['Original prompt', 'Tool output', 'Original answer'],
      );
      expect(host.parents.length, 1);
      expect(host.history('a', 'original').length, 8);
      expect(host.history('a', child.key.sessionId).map(answerMessageText), [
        'Compressed context summary',
        'Original prompt',
        'Tool output',
        'Original answer',
      ]);
    },
  );

  test(
    'compressed fork matches independent stock child snapshot after reopening',
    () async {
      // Synthetic stock-shaped source and child are specified independently.
      // No child prefix or expected result is computed with Wing's projections.
      host.histories['a/original'] = [
        {
          'row_id': 1,
          'role': 'user',
          'content': 'Old prompt',
          'active': 0,
          'compacted': 1,
        },
        {
          'row_id': 2,
          'role': 'assistant',
          'content': 'Old answer',
          'active': 0,
          'compacted': 1,
        },
        {
          'row_id': 3,
          'role': 'assistant',
          'content': 'Rewound answer',
          'active': 0,
          'compacted': 0,
        },
        {
          'row_id': 10,
          'role': 'user',
          'content': 'Summary',
          'active': 1,
          'display_kind': 'hidden',
          '_compressed_summary': true,
        },
        {
          'row_id': 11,
          'role': 'user',
          'content': 'Current prompt',
          'active': 1,
        },
        {'row_id': 12, 'role': 'tool', 'content': 'Tool result', 'active': 1},
        {
          'row_id': 13,
          'role': 'assistant',
          'content': 'Selected answer',
          'active': 1,
        },
        {'row_id': 14, 'role': 'user', 'content': 'Later prompt', 'active': 1},
        {
          'row_id': 15,
          'role': 'assistant',
          'content': 'Later answer',
          'active': 1,
        },
      ];
      host.alterBranch = (rows) => rows
        ..clear()
        ..addAll([
          {
            'row_id': 101,
            'role': 'user',
            'content': 'Summary',
            'active': 1,
            'display_kind': 'hidden',
            '_compressed_summary': true,
          },
          {
            'row_id': 102,
            'role': 'user',
            'content': 'Current prompt',
            'active': 1,
          },
          {
            'row_id': 103,
            'role': 'tool',
            'content': 'Tool result',
            'active': 1,
          },
          {
            'row_id': 104,
            'role': 'assistant',
            'content': 'Selected answer',
            'active': 1,
          },
        ]);
      final before = host
          .history('a', 'original')
          .map((row) => {...row})
          .toList();
      await controller.refreshHistory(original);
      final selected = original.reading.messages.indexWhere(
        (row) => row['id'] == 13,
      );
      final child = (await controller.branchAnswer(original, selected))!;
      final childKey = child.key;
      expect(controller.current!.chat, same(child));
      expect(host.history('a', 'original'), before);
      expect(
        host.history('a', childKey.sessionId).map((row) => row['content']),
        ['Summary', 'Current prompt', 'Tool result', 'Selected answer'],
      );
      controller.dispose();
      controller = makeController();
      await controller.initialize();
      await controller.openSession(childKey);
      final reopened = controller.current!.chat!;
      expect(reopened.reading.messages.map((row) => row['content']), [
        'Summary',
        'Current prompt',
        'Tool result',
        'Selected answer',
      ]);
      expect(reopened.reading.messages.map((row) => row['id']), [
        101,
        102,
        103,
        104,
      ]);
      expect(host.parents.length, 1);
    },
  );

  test('fork refuses an archived answer before creating a child', () async {
    host.history('a', 'original')[2].addAll({'active': 0, 'compacted': 1});
    await expectLater(controller.branchAnswer(original, 2), throwsStateError);
    expect(host.parents, isEmpty);
    expect(controller.current!.chat, same(original));
    expect(
      host.calls.where(
        (call) =>
            call.$1 == 'session.mutate' && call.$2['operation'] == 'branch',
      ),
      isEmpty,
    );
  });

  test(
    'fork verifies saved text instead of the RPC display projection',
    () async {
      host.branchReplyMessages = [
        {'role': 'user', 'text': 'Projected prompt'},
        {'role': 'assistant', 'text': 'Original answer'},
      ];
      final child = (await controller.branchAnswer(original, 2))!;
      expect(controller.current!.chat, same(child));
      final resumed = await controller.current!.gateway.resume(
        child.key.sessionId,
      );
      expect(
        ProfileGateway.records(resumed['messages']).map((row) => row['text']),
        ['Projected prompt', 'Original answer'],
        reason: 'The fixture must actually supply a different RPC projection',
      );
      expect(child.reading.messages.map(answerMessageText), [
        'Original prompt',
        'Tool output',
        'Original answer',
      ]);
    },
  );

  for (final fault in ['missing', 'extra', 'changed', 'summary']) {
    test(
      'fork rejects $fault saved content and keeps the child reachable',
      () async {
        host.addCompressedContext();
        await controller.refreshHistory(original);
        final selected = original.reading.messages.indexWhere(
          (row) => row['id'] == 103,
        );
        host.alterBranch = (rows) {
          switch (fault) {
            case 'missing':
              rows.removeLast();
            case 'extra':
              rows.add({
                'role': 'assistant',
                'text': 'Later answer',
                'row_id': 9999,
              });
            case 'changed':
              rows.last['text'] = 'Different answer';
            case 'summary':
              rows.first['text'] = 'Different compressed context';
          }
        };
        await expectLater(
          controller.branchAnswer(original, selected),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('The fork was created'),
            ),
          ),
        );
        expect(controller.current!.chat, same(original));
        expect(controller.current!.chats, contains('child-1'));
        expect(
          controller.current!.sessions.any((row) => row['id'] == 'child-1'),
          isTrue,
        );
        expect(host.parents.length, 1);
        expect(host.history('a', 'original').length, 8);
        expect(original.runtime.changingAnswer, isFalse);
      },
    );
  }

  for (final prefixLength in [498, 499, 505]) {
    test(
      'compressed fork reads complete pages at boundary $prefixLength',
      () async {
        host.addCompressedContext();
        final source = host.history('a', 'original');
        for (final row in source.skip(3)) {
          row['row_id'] = (row['row_id'] as int) + 1000;
        }
        source.insertAll(
          3,
          List.generate(
            prefixLength,
            (i) => {
              'role': i.isEven ? 'user' : 'tool',
              'text': i.isEven ? '[System: notice $i]' : 'Tool result $i',
              'row_id': 101 + i,
              'active': 1,
            },
          ),
        );
        await controller.refreshHistory(original);
        final selected = original.reading.messages.indexWhere(
          (row) => row['id'] == 1103,
        );
        final child = (await controller.branchAnswer(original, selected))!;
        expect(controller.current!.chat, same(child));
        final saved = host.history('a', child.key.sessionId);
        expect(saved, hasLength(prefixLength + 4));
        expect(saved.first['text'], 'Compressed context summary');
        expect(saved.last['text'], 'Original answer');
        final fresh = host.gateway(child.key.workspace);
        addTearDown(fresh.close);
        final copied = await fresh.branchHistory(child.key.sessionId);
        expect(copied, hasLength((prefixLength + 1) ~/ 2 + 3));
        expect(copied.first['content'], 'Compressed context summary');
        expect(copied.last['content'], 'Original answer');
        expect(
          host.calls
              .lastWhere(
                (call) =>
                    call.$1 == 'session.mutate' &&
                    call.$2['operation'] == 'branch',
              )
              .$2['payload']['through_message_id'],
          1103,
        );
      },
    );
  }

  test('a missing saved answer refuses before creating a child', () async {
    host.history('a', 'original')[2].remove('row_id');
    await expectLater(controller.branchAnswer(original, 2), throwsStateError);
    expect(
      host.calls.where(
        (c) => c.$1 == 'session.mutate' && c.$2['operation'] == 'branch',
      ),
      isEmpty,
    );
  });

  testWidgets(
    'raw history keeps hidden gateway notices out of the transcript',
    (tester) async {
      host.history('a', 'original').insert(1, {
        'role': 'user',
        'text': '[System: model changed]',
        'row_id': 8,
      });
      await controller.refreshHistory(original);
      await tester.pumpWidget(
        MaterialApp(
          home: ProfileWorkspaceScreen(
            controller: controller,
            createBotsSession: () => BotsSession((_) async => const []),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('[System: model changed]'), findsNothing);
      expect(
        host.calls.where((call) => call.$1 == 'session.answer_versions'),
        isEmpty,
        reason: 'Reading answers uses only existing Hermes APIs',
      );
      expect(
        original.reading.messages.any(isHiddenAnswerMessage),
        isTrue,
        reason:
            'Raw rows remain available for pagination and branch addressing',
      );
    },
  );

  test(
    'a continued fork can be forked again without exposing hidden notices',
    () async {
      host.history('a', 'original').insert(1, {
        'role': 'user',
        'text': '[System: model changed]',
        'row_id': 8,
      });
      final child = (await controller.branchAnswer(original, 2))!;
      child.composer.editText('Continue the fork');
      await controller.send(child);
      await host.complete(child);
      final grandchild = (await controller.branchAnswer(
        child,
        child.reading.messages.length - 1,
      ))!;
      expect(
        grandchild.reading.messages
            .where((m) => !isHiddenAnswerMessage(m))
            .map(answerMessageText),
        child.reading.messages
            .where((m) => !isHiddenAnswerMessage(m))
            .map(answerMessageText),
      );
    },
  );

  test(
    'branches at the selected answer, retaining tools but excluding later turns',
    () async {
      final child = (await controller.branchAnswer(original, 2))!;
      expect(
        child.reading.messages
            .where((m) => !isHiddenAnswerMessage(m))
            .map(answerMessageText),
        ['Original prompt', 'Tool output', 'Original answer'],
      );
      expect(original.reading.messages.length, 5);
      expect(controller.current!.chat, same(child));
      expect(
        host.calls
            .lastWhere(
              (c) => c.$1 == 'session.mutate' && c.$2['operation'] == 'branch',
            )
            .$2,
        containsPair('payload', {'through_message_id': 3}),
      );
      expect(host.calls.where((c) => c.$1 == 'prompt.submit'), isEmpty);
    },
  );

  test('regenerates in place without creating a branch', () async {
    original.composer.editText('Unsent draft');
    final regenerated = (await controller.branchAnswer(
      original,
      2,
      regenerate: true,
    ))!;
    await host.complete(regenerated);
    final submit = host.calls.lastWhere((c) => c.$1 == 'prompt.submit').$2;
    expect(
      host.calls.where(
        (c) => c.$1 == 'session.mutate' && c.$2['operation'] == 'branch',
      ),
      isEmpty,
    );
    expect(submit, {
      'session_id': original.runtime.runtimeId,
      'profile': 'a',
      'text': 'Original prompt',
      'submission_id': submit['submission_id'],
    });
    expect(
      regenerated.reading.messages
          .where((m) => !isHiddenAnswerMessage(m))
          .map(answerMessageText),
      ['Original prompt', 'New answer 0'],
    );
    expect(regenerated, same(original));
    expect(regenerated.parentSessionId, isNull);
    expect(original.composer.observation.text, 'Unsent draft');
    expect(
      preferences.getKeys().where((k) => k.startsWith('answer_versions')),
      isEmpty,
    );
  });

  test(
    'regeneration replays visible text from duplicated persisted context',
    () async {
      const marker = '--- Attached Context ---';
      const block = '''📄 @file:/work/fixture.txt (4 tokens)
```text
fixture-value-amber-729
```''';
      const visible = '@file:/work/fixture.txt\n\nSummarize this file.';
      const persisted =
          '$visible\n\n$marker\n\n$block\n\n$marker\n\n$block\n\n$block';
      host.references = ReferenceHost()
        ..files['/work/fixture.txt'] = 'Fresh source at replay';
      host.history('a', 'original')[0]
        ..remove('text')
        ..['content'] = persisted;
      original.reading.installSavedHistory([
        Map<String, dynamic>.from(original.reading.messages.first)
          ..remove('text')
          ..['content'] = persisted,
        ...original.reading.messages.skip(1),
      ]);
      original.composer.editText('Keep this draft');

      final regenerated = (await controller.branchAnswer(
        original,
        2,
        regenerate: true,
      ))!;

      final submit = host.calls.lastWhere((call) => call.$1 == 'prompt.submit');
      expect(regenerated, same(original));
      expect(submit.$2['session_id'], original.runtime.runtimeId);
      expect(
        host.calls
            .lastWhere((call) => call.$1 == 'session.mutate')
            .$2['payload'],
        {'target_message_id': 1},
      );
      final prepared = PreparedComposerMessage.parse(submit.$2['text'])!;
      expect(prepared.message, visible);
      expect(prepared.context, contains('Fresh source at replay'));
      expect(submit.$2['text'], isNot(contains(marker)));
      expect(submit.$2['text'], isNot(contains('fixture-value-amber-729')));
      expect(original.composer.observation.text, 'Keep this draft');
    },
  );

  test(
    'duplicate regeneration taps keep one replay while a fresh Send waits',
    () async {
      host.submitDelay = Completer<void>();
      final pending = controller.branchAnswer(original, 2, regenerate: true);
      await Future<void>.delayed(Duration.zero);
      expect(
        await controller.branchAnswer(original, 2, regenerate: true),
        isNull,
      );
      await controller.updateDraft(original, 'Queued follow-up');
      await controller.send(original);
      await controller.send(original);
      expect(original.composer.observation.text, isEmpty);
      expect(
        original.composer.observation.queue.single.text,
        'Queued follow-up',
      );
      expect(
        original.composer.observation.queue.single.submissionUncertain,
        isFalse,
      );
      expect(host.calls.where((c) => c.$1 == 'prompt.submit').length, 1);
      await controller.updateDraft(original, 'Separate fresh draft');
      host.submitDelay!.complete();
      final regenerated = (await pending)!;
      expect(host.calls.where((c) => c.$1 == 'prompt.submit').length, 1);
      expect(
        original.composer.observation.queue.single.text,
        'Queued follow-up',
      );
      await host.complete(regenerated);
      await Future<void>(() async {
        while (original.composer.observation.queue.isNotEmpty ||
            original.composer.observation.sending) {
          await Future<void>.delayed(Duration.zero);
        }
      }).timeout(const Duration(seconds: 10));
      expect(
        host.calls.where(
          (c) => c.$1 == 'session.mutate' && c.$2['operation'] == 'branch',
        ),
        isEmpty,
      );
      final submissions = host.calls
          .where((call) => call.$1 == 'prompt.submit')
          .toList();
      expect(submissions, hasLength(2));
      expect(
        host.calls
            .lastWhere((call) => call.$1 == 'session.mutate')
            .$2['payload'],
        {'target_message_id': 1},
      );
      expect(submissions.first.$2['text'], 'Original prompt');
      expect(submissions.last.$2['text'], 'Queued follow-up');
      expect(submissions.last.$2.containsKey('queued'), isFalse);
      expect(
        submissions.last.$2.containsKey('truncate_before_row_id'),
        isFalse,
      );
      expect(original.composer.observation.text, 'Separate fresh draft');
    },
  );

  test(
    'profile switch during regeneration keeps navigation and owners isolated',
    () async {
      host.submitDelay = Completer<void>();
      final pending = controller.branchAnswer(original, 2, regenerate: true);
      await Future<void>.delayed(Duration.zero);
      await controller.switchProfile('b');
      await controller.openSession(
        ProfileSessionKey(controller.current!.scope, 'original'),
      );
      host.submitDelay!.complete();
      final regenerated = (await pending)!;
      await host.complete(regenerated);
      expect(controller.current!.scope.profileName, 'b');
      expect(
        host.calls.lastWhere((c) => c.$1 == 'prompt.submit').$2['profile'],
        'a',
      );
    },
  );

  test('leaving the chat during a branch does not reopen it', () async {
    host.branchDelay = Completer<void>();
    final pending = controller.branchAnswer(original, 2);
    await Future<void>.delayed(Duration.zero);
    controller.showList();
    host.branchDelay!.complete();
    await pending;
    expect(controller.current!.chat, isNull);
  });

  test(
    'retired fork visit cannot select its child on the same source',
    () async {
      host.branchDelay = Completer<void>();
      var current = true;
      final pending = controller.branchAnswer(
        original,
        2,
        isCurrentRequest: () => current,
      );
      await Future<void>.delayed(Duration.zero);
      current = false;
      host.branchDelay!.complete();
      final child = await pending;
      expect(child, isNotNull);
      expect(controller.current!.chat, same(original));
    },
  );

  test('stale history refuses the branch before mutation', () async {
    original.reading.installSavedHistory([
      ...original.reading.messages.take(2),
      {...original.reading.messages[2], 'content': 'Stale answer'},
      ...original.reading.messages.skip(3),
    ]);
    await expectLater(controller.branchAnswer(original, 2), throwsStateError);
    expect(
      host.calls.where(
        (c) => c.$1 == 'session.mutate' && c.$2['operation'] == 'branch',
      ),
      isEmpty,
    );
    expect(original.runtime.changingAnswer, isFalse);
  });

  test(
    'a paged transcript uses the saved row rather than its local position',
    () async {
      original.reading.installSavedHistory(
        original.reading.messages.sublist(3),
      );
      final regenerated = (await controller.branchAnswer(
        original,
        1,
        regenerate: true,
      ))!;
      await host.complete(regenerated);
      expect(
        host.calls.where(
          (c) => c.$1 == 'session.mutate' && c.$2['operation'] == 'branch',
        ),
        isEmpty,
      );
      expect(
        host.calls.lastWhere((c) => c.$1 == 'prompt.submit').$2['text'],
        'Follow-up',
      );
      expect(
        host.calls
            .lastWhere((c) => c.$1 == 'session.mutate')
            .$2['payload']['target_message_id'],
        4,
      );
      expect(
        regenerated.reading.messages
            .where((m) => !isHiddenAnswerMessage(m))
            .map(answerMessageText),
        [
          'Original prompt',
          'Tool output',
          'Original answer',
          'Follow-up',
          'New answer 0',
        ],
      );
      expect(regenerated, same(original));
    },
  );

  test(
    'parent navigation uses the server lineage in the captured profile',
    () async {
      final child = (await controller.branchAnswer(original, 2))!;
      await controller.switchProfile('b');

      await controller.openParentChat(child);

      expect(controller.current!.scope.profileName, 'a');
      expect(controller.current!.chat, same(original));
    },
  );

  test(
    'explicit server parent state wins while omitted metadata falls back',
    () async {
      final child = (await controller.branchAnswer(original, 2))!;
      host.omitListParent = true;
      expect(await controller.switchProfile('a'), isTrue);
      expect(
        controller.current!.sessions
            .firstWhere((row) => row['id'] == child.key.sessionId)
            .containsKey('parent_session_id'),
        isFalse,
      );
      expect(controller.parentSessionId(child), original.key.sessionId);

      host.clearListParent = true;
      expect(await controller.switchProfile('a'), isTrue);
      final row = controller.current!.sessions.firstWhere(
        (row) => row['id'] == child.key.sessionId,
      );
      expect(row.containsKey('parent_session_id'), isTrue);
      expect(row['parent_session_id'], isNull);
      expect(controller.parentSessionId(child), isNull);
    },
  );

  test(
    'server parent lineage restores without phone relationship state',
    () async {
      final child = (await controller.branchAnswer(original, 2))!;
      final key = child.key;
      host.omitSessionParent = true;
      controller.dispose();
      controller = makeController();
      await controller.initialize();

      await controller.openSession(key);

      final restored = controller.current!.chat!;
      expect(restored.parentSessionId, original.key.sessionId);
      expect(
        preferences.getKeys().where((key) => key.startsWith('answer_versions')),
        isEmpty,
      );
    },
  );

  testWidgets('explicit null resume parent clears stale list navigation', (
    tester,
  ) async {
    final child = (await controller.branchAnswer(original, 2))!;
    final key = child.key;
    controller.dispose();
    host.clearSessionParent = true;
    controller = makeController();
    await controller.initialize();

    await controller.openSession(key);
    final restored = controller.current!.chat!;
    expect(controller.parentSessionId(restored), isNull);
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileWorkspaceScreen(
          controller: controller,
          createBotsSession: () => BotsSession((_) async => const []),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Chat actions'));
    await tester.pumpAndSettle();
    expect(find.text('Parent chat'), findsNothing);
  });

  test('rejected regeneration restores the same chat', () async {
    final regenerated = (await controller.branchAnswer(
      original,
      2,
      regenerate: true,
    ))!;
    await host.complete(regenerated);
    host.mutationError = JsonRpcError(
      'session.mutate',
      'Session busy',
      reason: 'session_busy',
    );
    await expectLater(
      controller.branchAnswer(original, 1, regenerate: true),
      throwsStateError,
    );
    expect(controller.current!.chat, same(original));
    expect(original.runtime.execution, ChatExecution.failed);
    expect(
      original.runtime.error,
      'Hermes did not accept the regeneration. The conversation is unchanged.',
    );
  });

  test(
    'stale saved prompt rejection stays actionable and hides RPC text',
    () async {
      host.mutationError = JsonRpcError(
        'session.mutate',
        'target user message is no longer in session history',
        reason: 'revision_conflict',
      );

      await expectLater(
        controller.branchAnswer(original, 2, regenerate: true),
        throwsStateError,
      );

      expect(original.runtime.execution, ChatExecution.failed);
      expect(
        original.runtime.error,
        'Hermes did not accept the regeneration. The conversation is unchanged.',
      );
      expect(original.runtime.error, isNot(contains('JsonRpcError')));
      expect(controller.current!.chat, same(original));
      expect(original.reading.messages.last['text'], 'Later answer');
    },
  );

  test(
    'missing durable row IDs refuses regeneration without changing the chat',
    () async {
      final originalStatus = original.runtime.execution;
      host.omitRowIds = true;
      await expectLater(
        controller.branchAnswer(original, 2, regenerate: true),
        throwsStateError,
      );
      expect(original.runtime.execution, originalStatus);
      expect(
        original.runtime.error,
        'Hermes did not accept the regeneration. The conversation is unchanged.',
      );
      expect(original.reading.messages.last['text'], 'Later answer');
      expect(host.calls.where((c) => c.$1 == 'prompt.submit'), isEmpty);
      expect(controller.current!.chat, same(original));
    },
  );

  test(
    'uncertain regenerate keeps the same chat and does not resubmit',
    () async {
      host.submitError = TimeoutException('connection lost');
      final regenerated = (await controller.branchAnswer(
        original,
        2,
        regenerate: true,
      ))!;
      expect(regenerated, same(original));
      expect(original.runtime.reconnecting, isTrue);
      expect(original.parentSessionId, isNull);
      await controller.reconnect(original.key.workspace);
      final attempts = host.calls
          .where((c) => c.$1 == 'prompt.submit')
          .toList();
      expect(attempts, hasLength(2));
      expect(attempts.last.$2, attempts.first.$2);
      expect(host.history('a', 'original'), isEmpty);
      expect(original.composer.hasRecoverableSubmissions, isTrue);
    },
  );

  for (final failure in [
    JsonRpcError('prompt.submit', 'Timeout', reason: 'request_timeout'),
    JsonRpcError(
      'prompt.submit',
      'Connection closed',
      reason: 'connection_closed',
    ),
    JsonRpcError('prompt.submit', 'Internal error', code: -32603),
    JsonRpcError(
      'prompt.submit',
      'Session storage could not be written',
      code: 5071,
    ),
  ]) {
    test(
      'regeneration reconciles accepted history after ${failure.reason ?? failure.code}',
      () async {
        // Hermes has already rewound the durable history before the reply fails.
        host.submitError = failure;
        host.submitErrorAfterAcceptance = true;
        final regenerated = await controller.branchAnswer(
          original,
          2,
          regenerate: true,
        );

        expect(regenerated, same(original));
        expect(original.runtime.reconnecting, isTrue);
        expect(original.runtime.error, contains('uncertain'));
        expect(original.runtime.error, isNot(contains('unchanged')));
        expect(original.reading.messages.map(answerMessageText), [
          'Original prompt',
        ]);

        host.resumeDelay = Completer<void>();
        final recovery = controller.reconnect(original.key.workspace);
        await controller.updateDraft(original, 'New draft during recovery');
        host.resumeDelay!.complete();
        await recovery;

        expect(original.reading.messages.map(answerMessageText), [
          'Original prompt',
          'New answer 0',
        ]);
        expect(original.composer.observation.text, 'New draft during recovery');
        expect(original.runtime.execution, ChatExecution.completed);
        final attempts = host.calls
            .where((call) => call.$1 == 'prompt.submit')
            .toList();
        expect(attempts, hasLength(2));
        expect(attempts.last.$2, attempts.first.$2);
        expect(host.admissionReceipts, hasLength(1));
        expect(
          host.calls.where(
            (call) =>
                call.$1 == 'session.mutate' && call.$2['operation'] == 'branch',
          ),
          isEmpty,
        );
      },
    );
  }

  testWidgets(
    'regenerate updates the same chat without parent navigation or carousel',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ProfileWorkspaceScreen(
            controller: controller,
            createBotsSession: () => BotsSession((_) async => const []),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final originalActions = find.byKey(const ValueKey('answer-actions-3'));
      await tester.ensureVisible(originalActions);
      await tester.tap(
        find.descendant(
          of: originalActions,
          matching: find.byTooltip('Regenerate response'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('1 later user turn'), findsOneWidget);
      await tester.tap(find.byTooltip('Regenerate and remove later turns'));
      await tester.runAsync(() async {
        for (var i = 0; i < 100; i++) {
          if (controller.current!.chat!.runtime.execution ==
              ChatExecution.running) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      });
      await tester.pump();
      final regenerated = controller.current!.chat!;
      expect(regenerated, same(original));
      expect(regenerated.runtime.execution, ChatExecution.running);
      await tester.runAsync(() => host.complete(regenerated));
      await tester.pumpAndSettle();
      await tester.settleMarkdown();
      expect(regenerated.runtime.execution, ChatExecution.completed);
      expect(
        regenerated.reading.messages
            .where((m) => !isHiddenAnswerMessage(m))
            .map(answerMessageText),
        ['Original prompt', 'New answer 0'],
      );
      expect(find.text('New answer 0'), findsOneWidget);
      expect(find.byTooltip('Previous answer'), findsNothing);
      expect(find.byTooltip('Next answer'), findsNothing);
      await tester.tap(find.byTooltip('Chat actions'));
      await tester.pumpAndSettle();
      expect(find.text('Parent chat'), findsNothing);
      expect(find.text('Original answer'), findsNothing);
      expect(find.text('Later answer'), findsNothing);
    },
  );

  testWidgets('notice shares actions for the preceding saved answer', (
    tester,
  ) async {
    host.history('a', 'original').insert(3, {
      'role': 'user',
      'text': 'Background result',
      'row_id': 6,
      'display_kind': 'async_delegation_complete',
      'display_metadata': {'task_count': 1},
    });
    await controller.refreshHistory(original);
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileWorkspaceScreen(
          controller: controller,
          createBotsSession: () => BotsSession((_) async => const []),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final actions = find.byKey(const ValueKey('answer-actions-3'));
    final section = find.byWidgetPredicate(
      (widget) =>
          widget is ProfileToolActivitySection &&
          widget.section.containsMessage(6),
    );
    await tester.ensureVisible(section);
    await tester.tap(
      find.descendant(
        of: section,
        matching: find.textContaining(RegExp(r'^Activity(?: · \d+ tools?)?$')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: section, matching: find.text('Agents')),
    );
    await tester.pumpAndSettle();
    final notice = find.text('1 background agent finished');
    expect(actions, findsOneWidget);
    expect(notice, findsOneWidget);
    expect(tester.getRect(actions).overlaps(tester.getRect(notice)), isFalse);
    expect(
      tester.getTopLeft(actions).dy,
      lessThan(tester.getBottomLeft(notice).dy),
    );
    await tester.tap(
      find.descendant(
        of: actions,
        matching: find.byTooltip('Branch in new session'),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      host.calls
          .lastWhere(
            (call) =>
                call.$1 == 'session.mutate' && call.$2['operation'] == 'branch',
          )
          .$2['payload']['through_message_id'],
      3,
    );
    expect(
      controller.current!.chat!.reading.messages.last['text'],
      'Original answer',
    );
  });

  testWidgets(
    'server branch controls fit a narrow phone without version arrows',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AnswerActions(onBranch: () {}, onRegenerate: () {}),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('Branch in new session'), findsOneWidget);
      expect(find.byTooltip('Regenerate response'), findsOneWidget);
      expect(find.byIcon(Icons.chevron_left), findsNothing);
      expect(find.byIcon(Icons.chevron_right), findsNothing);
    },
  );
}
