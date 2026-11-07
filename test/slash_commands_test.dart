import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/models/composer_reference.dart';
import 'package:wing/core/models/attachment_draft.dart';
import 'package:wing/core/models/queued_prompt_draft.dart';
import 'package:wing/core/models/chat_runtime.dart';
import 'support/composer_fixture.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:wing/core/models/slash_command.dart';
import 'package:wing/core/models/answer_versions.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/models/side_question_delivery.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/composer_draft_store.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/ws_client.dart';
import 'package:wing/core/widgets/slash_command_suggestions.dart';
import 'package:wing/core/widgets/activity/skill_document_viewer.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'profile_workspace_controller_test.dart' show Host;

class CommandHost extends Host {
  final skillReads = <Map<String, String>>[];
  Future<Map<String, dynamic>> Function()? readSkill;
  final commandCalls = <(String, Map<String, dynamic>)>[];
  final extraSkillNames = <String>[];
  Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)? respond;
  String yolo = '0';
  bool reportYolo = true;
  String warning = '';
  String? yoloSetResult;
  Future<Map<String, dynamic>> Function(String profile)? readCatalog;
  final List<String> sideQuestionTaskIds = ['side-task-1'];
  final List<String> backgroundTaskIds = ['background-task-1'];
  FutureOr<Map<String, dynamic>> Function(Map<String, dynamic>)?
  backgroundRespond;
  Completer<void>? sensitiveResponseDelay;
  Object? sensitiveResponseError;
  Map<String, dynamic> catalog(String profile) => {
    'pairs': [
      ['/$profile-skill', 'Profile $profile skill'],
      for (final name in extraSkillNames) [name, 'Another skill'],
      ['/model', 'Choose model'],
      ['/approvals', 'Manage approval mode'],
      ['/undo', 'Edit last prompt'],
      ['/clear', 'Clear the terminal'],
    ],
    'categories': [
      {
        'name': 'Skills',
        'pairs': [
          ['/$profile-skill', 'Profile $profile skill'],
        ],
      },
    ],
    'canon': {'/short': '/$profile-skill'},
    'skills': {for (final name in extraSkillNames) name: <String, dynamic>{}},
    'commands': {
      '/clear': {'desktop': 'terminal'},
    },
    'warning': warning,
  };

  @override
  ProfileGateway gateway(WorkspaceScope scope) {
    final base = super.gateway(scope);
    late final ProfileGateway gateway;
    gateway = ProfileGateway(
      scope: scope,
      discover: discover,
      connect: () async {
        if (gateway.onEvent != null) gateways[scope.profileName] = gateway;
        await base.connect();
      },
      get: (endpoint, query) async {
        if (endpoint == 'skills/content') {
          skillReads.add(Map.of(query));
          return readSkill == null
              ? {
                  'name': query['name'],
                  'content':
                      '# Skill instructions\n\nInspect the original sources.',
                  'path':
                      '/profiles/${scope.profileName}/skills/${query['name']}/SKILL.md',
                }
              : await readSkill!();
        }
        final result = await base.read(endpoint, query);
        if (!endpoint.endsWith('/messages') || historyMessages != null) {
          return result;
        }
        // Command tests start with the same empty history over REST and RPC.
        return {
          ...result,
          'messages': <Map<String, dynamic>>[],
          'pagination': {...result['pagination'] as Map, 'returned': 0},
        };
      },
      rpc: (method, params) async {
        commandCalls.add((method, params));
        if (method == 'request.answer') {
          await sensitiveResponseDelay?.future;
          final error = sensitiveResponseError;
          if (error != null) throw error;
        }
        if (method == 'commands.catalog') {
          return await readCatalog?.call(scope.profileName) ??
              catalog(scope.profileName);
        }
        if (method == 'session.mutate' && params['operation'] == 'compress') {
          if (respond == null) throw StateError('Unexpected compression');
          return respond!(method, params);
        }
        if (method == 'skills.reload') {
          return await respond?.call(method, params) ??
              {
                'output': 'Skills reloaded',
                'result': {'total': 1, 'commands': 1},
              };
        }
        if (method == 'config.set' && params['key'] == 'yolo') {
          yolo = params['value']!.toString();
          return {'value': yoloSetResult ?? yolo};
        }
        if (method == 'prompt.btw') {
          return {'task_id': sideQuestionTaskIds.removeAt(0)};
        }
        if (method == 'prompt.background') {
          return await backgroundRespond?.call(params) ??
              {'task_id': backgroundTaskIds.removeAt(0)};
        }
        // Stock accepts text plus session_id/profile; an owned runtime supplies
        // the profile/workspace, so no additional profile is needed here.
        // Verified at upstream f42f579cf8bac4918ac9599bece71618afadd846:
        // tui_gateway/contracts/profiles_vault_complete_foreign_subagents.py.
        if (method == 'complete.slash') {
          if (params.keys.any(
            (key) => !{'text', 'session_id', 'profile'}.contains(key),
          )) {
            throw JsonRpcError(
              method,
              'Extra inputs are not permitted',
              code: 4000,
            );
          }
          return await respond?.call(method, params) ??
              {
                'items': [
                  if (params['text'] == '/approvals ')
                    for (final mode in ['manual', 'smart', 'off'])
                      {'text': mode, 'meta': ''},
                ],
                'replace_from': (params['text'] as String).runes.length,
              };
        }
        if (method == 'session.status') {
          throw StateError('session.status is not a canonical owner method');
        }
        if (method == 'command.dispatch' || method == 'slash.exec') {
          return await respond?.call(method, params) ??
              {'type': 'exec', 'output': 'Done'};
        }
        if (method == 'session.history') {
          return {'messages': <Map<String, dynamic>>[]};
        }
        final result = await base.call(method, params);
        if (method == 'session.create' || method == 'session.resume') {
          return {
            ...result,
            'info': {
              ...result['info'] as Map,
              if (reportYolo) 'yolo': yolo == '1',
            },
          };
        }
        return result;
      },
    );
    return gateway;
  }
}

class _HeldPromptDraftStore extends ComposerDraftStore {
  _HeldPromptDraftStore(super.preferences, {required super.connectionIdentity});
  String? holdPrompt;
  final preparing = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> write({
    required String profileName,
    required String sessionId,
    required String text,
    Iterable<ComposerReference> references = const [],
    required Iterable<AttachmentDraft> attachments,
    bool submissionUncertain = false,
    Iterable<QueuedPromptDraft> queuedPrompts = const [],
    bool queuePaused = false,
  }) async {
    final files = attachments.toList();
    final queue = queuedPrompts.toList();
    if (holdPrompt != null && queue.any((entry) => entry.text == holdPrompt)) {
      holdPrompt = null;
      preparing.complete();
      await release.future;
    }
    await super.write(
      profileName: profileName,
      sessionId: sessionId,
      text: text,
      references: references,
      attachments: files,
      submissionUncertain: submissionUncertain,
      queuedPrompts: queue,
      queuePaused: queuePaused,
    );
  }
}

void main() {
  late CommandHost host;
  late ProfileWorkspaceController controller;
  late AppPreferences appPreferences;
  late ProfileChat chat;
  late _HeldPromptDraftStore draftStore;
  var controllerDisposed = false;
  setUpAll(() async {
    final fonts = Platform.environment['CAPTURE_SKILL_COMPOSER_FONTS'];
    if (fonts == null) return;
    for (final entry in {
      'Roboto': ['Roboto-Regular.ttf', 'Roboto-Bold.ttf'],
      'MaterialIcons': ['MaterialIcons-Regular.otf'],
    }.entries) {
      final loader = FontLoader(entry.key);
      for (final font in entry.value) {
        loader.addFont(
          File('$fonts/$font').readAsBytes().then((b) => b.buffer.asByteData()),
        );
      }
      await loader.load();
    }
    final mono = Platform.environment['CAPTURE_SKILL_COMPOSER_MONO_FONT'];
    if (mono != null) {
      final loader = FontLoader('monospace');
      loader.addFont(
        File(mono).readAsBytes().then((b) => b.buffer.asByteData()),
      );
      await loader.load();
    }
  });
  setUp(() async {
    controllerDisposed = false;
    SharedPreferences.setMockInitialValues({});
    host = CommandHost();
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    draftStore = _HeldPromptDraftStore(
      preferences,
      connectionIdentity: 'slash-test-host',
    );
    controller = ProfileWorkspaceController(
      connectionIdentity: 'slash-test-host',
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
      draftStore: draftStore,
    );
    await controller.initialize();
    chat = await controller.createChat(canDispatch: () => true);
  });
  tearDown(() {
    if (!controllerDisposed) controller.dispose();
    appPreferences.dispose();
  });

  for (final command in ['compress', 'compact']) {
    test(
      '$command uses canonical raw-argument preview without generic dispatch',
      () async {
        host.respond = (method, params) async {
          expect(method, 'session.mutate');
          expect(params['operation'], 'compress');
          expect(params['session_id'], 'a-runtime');
          expect(params['profile'], 'a');
          expect(params['request_id'], isNotEmpty);
          expect(params['expected_revision'], isA<int>());
          expect(params['expected_generation'], isA<int>());
          expect(params['payload'], {'focus': 'here 2 --preview'});
          return {
            'session_id': params['session_id'],
            'operation': 'compress',
            'status': 'preview',
            'lines': ['Keep the newest 2 messages'],
            'head_count': 4,
            'tail_count': 2,
            'message_count': 6,
          };
        };
        chat.composer.editText('/$command here 2 --preview');
        await controller.send(chat);
        expect(chat.runtime.error, isNull);
        expect(chat.composer.observation.text, isEmpty);
        expect(
          chat.reading.messages.any(
            (m) => m['content'] == 'Keep the newest 2 messages',
          ),
          isTrue,
        );
        expect(
          host.commandCalls.where(
            (c) => {
              'command.dispatch',
              'slash.exec',
              'prompt.submit',
            }.contains(c.$1),
          ),
          isEmpty,
        );
      },
    );
  }

  for (final noop in [true, false]) {
    test(
      'compression ${noop ? 'noop' : 'receipt'} retains newer draft and exact pending ownership',
      () async {
        final entered = Completer<void>();
        final held = Completer<Map<String, dynamic>>();
        host.respond = (method, params) {
          expect(method, 'session.mutate');
          entered.complete();
          return held.future;
        };
        chat.composer.editText('/compress focus project constraints');
        final running = controller.send(chat);
        await entered.future;
        expect(chat.runtime.commandRunning, isTrue);
        chat.composer.editText('Keep a newer unrelated draft');
        await controller.send(chat);
        expect(
          host.commandCalls.where((c) => c.$1 == 'session.mutate').length,
          1,
        );
        held.complete({
          'session_id': 'a-runtime',
          'operation': 'compress',
          if (noop) 'status': 'noop',
          if (!noop) ...{
            'revision': 1,
            'execution_generation': 1,
            'target_session_id': chat.key.sessionId,
            'previous_target_session_id': chat.key.sessionId,
          },
          'summary': {
            'headline': noop
                ? 'No changes from compression: 2 messages'
                : 'Compressed: 8 → 3 messages',
            'token_line': 'Estimated tokens: 90 → 40',
            'note': '',
          },
        });
        await running;
        expect(chat.runtime.error, isNull);
        expect(chat.runtime.commandRunning, isFalse);
        expect(chat.composer.observation.text, 'Keep a newer unrelated draft');
        expect(
          chat.reading.messages.any(
            (m) => m['content'].toString().contains(
              noop ? 'No changes from compression' : 'Compressed: 8',
            ),
          ),
          isTrue,
        );
        if (!noop) {
          expect(host.commandCalls.any((c) => c.$1 == 'session.stats'), isTrue);
        }
      },
    );
  }

  test('applied compression receipt follows rewritten saved history', () async {
    host.historyMessages = [
      {'id': 1, 'role': 'user', 'content': 'Earlier question'},
      {'id': 2, 'role': 'assistant', 'content': 'Newest answer'},
    ];
    await controller.refreshHistory(chat);
    chat.reading.appendCommandNotice(
      'Compression preview',
      command: '/compress',
    );
    host.respond = (method, params) async {
      expect(method, 'session.mutate');
      // Canonical compression rewrites saved rows, including preserved content.
      host.historyMessages = [
        {'id': 101, 'role': 'user', 'content': 'Earlier question'},
        {'id': 102, 'role': 'assistant', 'content': 'Newest answer'},
      ];
      return {
        'session_id': params['session_id'],
        'operation': 'compress',
        'revision': 1,
        'execution_generation': 1,
        'summary': {'headline': 'Compressed: 28 → 12 messages'},
      };
    };
    chat.composer.editText('/compress');
    await controller.send(chat);

    expect(chat.runtime.error, isNull);
    expect(
      chat.reading.messages
          .where((row) => row['_command_notice'] != true)
          .map((row) => row['id']),
      [101, 102],
    );
    expect(
      chat.reading.messages.last['content'],
      'Compressed: 28 → 12 messages',
    );
    expect(chat.reading.messages.last['_command_notice'], isTrue);
  });

  test(
    'applied compression keeps its receipt when history readback fails',
    () async {
      host.respond = (method, params) async {
        expect(method, 'session.mutate');
        host.heldHistoryStarted = Completer<void>();
        host.heldHistoryDelay = Completer<void>()..complete();
        host.heldHistoryFailure = StateError('History unavailable');
        return {
          'session_id': params['session_id'],
          'operation': 'compress',
          'revision': 1,
          'execution_generation': 1,
          'summary': {'headline': 'Compressed: 28 → 12 messages'},
        };
      };
      chat.composer.editText('/compress');
      await controller.send(chat);

      expect(chat.runtime.error, isNull);
      expect(chat.composer.observation.text, isEmpty);
      expect(chat.reading.messages.map((row) => row['content']), [
        'Compressed: 28 → 12 messages',
        'Compression finished. Refresh to reload history and context.',
      ]);
      expect(
        host.commandCalls.where((call) => call.$1 == 'session.mutate'),
        hasLength(1),
      );
    },
  );

  for (final reason in [
    'unsupported_compress_options',
    'compression_checkpoint_required',
    'runtime_coordination_required',
    'request_timeout',
  ]) {
    test(
      'compression $reason preserves draft without retry or handler fallback',
      () async {
        host.respond = (_, _) async => throw JsonRpcError(
          'session.mutate',
          reason,
          code: 4001,
          reason: reason,
        );
        chat.composer.editText('/compress --aggressive');
        await controller.send(chat);
        expect(chat.composer.observation.text, '/compress --aggressive');
        expect(
          chat.runtime.error,
          contains(reason == 'request_timeout' ? 'uncertain' : reason),
        );
        expect(
          host.commandCalls.where((c) => c.$1 == 'session.mutate').length,
          1,
        );
        expect(
          host.commandCalls.where(
            (c) => {'command.dispatch', 'slash.exec'}.contains(c.$1),
          ),
          isEmpty,
        );
      },
    );
  }

  test(
    'compression cannot dispatch after profile departure during catalog read',
    () async {
      final entered = Completer<void>();
      final held = Completer<Map<String, dynamic>>();
      host.readCatalog = (profile) {
        entered.complete();
        return held.future;
      };
      chat.composer.editText('/compress');
      final running = controller.send(chat);
      await entered.future;
      await controller.switchProfile('b');
      held.complete(host.catalog('a'));
      await running;
      expect(host.commandCalls.where((c) => c.$1 == 'session.mutate'), isEmpty);
      expect(chat.composer.observation.text, '/compress');
    },
  );

  for (final blocked in ['working', 'read-only']) {
    test('compression refuses $blocked conversation before mutation', () async {
      if (blocked == 'working') {
        emitChatEvent(controller, chat, 'message.start');
      } else {
        host.gateways['a']!.canonical.refused(
          'a-runtime',
          JsonRpcError(
            'session.mutate',
            'session_read_only',
            reason: 'session_read_only',
          ),
        );
      }
      chat.composer.editText('/compress');
      await controller.send(chat);
      expect(host.commandCalls.where((c) => c.$1 == 'session.mutate'), isEmpty);
      expect(chat.runtime.error, isNotNull);
      expect(chat.composer.observation.text, '/compress');
    });
  }

  test(
    'status uses the exact canonical command and preserves captured profile',
    () async {
      final entered = Completer<void>();
      final response = Completer<Map<String, dynamic>>();
      host.respond = (method, params) async {
        expect(method, 'slash.exec');
        expect(params, {
          'session_id': 'a-runtime',
          'profile': 'a',
          'command': '/status',
        });
        entered.complete();
        return response.future;
      };
      chat.composer.editText('/status');
      final sending = controller.send(chat);
      await entered.future;
      expect(chat.runtime.commandRunning, true);
      await controller.send(chat);
      expect(
        host.commandCalls.where((call) => call.$1 == 'slash.exec'),
        hasLength(1),
      );
      await controller.switchProfile('b');
      response.complete({
        'type': 'exec',
        'output': 'Model: precise-model · session a',
      });
      await sending;
      expect(chat.runtime.commandRunning, false);
      expect(chat.composer.observation.text, isEmpty);
      expect(
        chat.reading.messages
            .where((row) => row['_command_notice'] == true)
            .single['content'],
        'Model: precise-model · session a',
      );
      expect(controller.current!.scope.profileName, 'b');
      expect(
        host.commandCalls.where((call) => call.$1 == 'prompt.submit'),
        isEmpty,
      );
    },
  );

  for (final malformed in [false, true]) {
    test(
      'status ${malformed ? 'malformed receipt' : 'failure'} preserves draft without model admission',
      () async {
        host.respond = (_, _) async {
          if (malformed) return {'type': 'exec'};
          throw StateError('Status unavailable on Hermes');
        };
        chat.composer.editText('/status');
        await controller.send(chat);
        expect(chat.composer.observation.text, '/status');
        expect(chat.runtime.commandRunning, false);
        expect(
          chat.runtime.error,
          contains(malformed ? 'did not return' : 'Status unavailable'),
        );
        expect(
          host.commandCalls.where((call) => call.$1 == 'slash.exec'),
          hasLength(1),
        );
        expect(
          host.commandCalls.where((call) => call.$1 == 'prompt.submit'),
          isEmpty,
        );
      },
    );
  }

  for (final retained in [false, true]) {
    testWidgets(
      'opening a ${retained ? 'retained' : 'cold'} saved slash draft loads commands after connection',
      (tester) async {
        const skill = '/mattpocock-skills:writing-for-agents';
        host.running = false;
        host.extraSkillNames.add(skill);
        final profile = retained ? 'a' : 'b';
        if (retained) await controller.updateDraft(chat, skill);
        await draftStore.write(
          profileName: profile,
          sessionId: 'same',
          text: skill,
          attachments: const [],
          submissionUncertain: false,
          queuedPrompts: const [],
          queuePaused: false,
        );
        final connection = Completer<void>();
        if (retained) {
          host.resumeDelay = connection;
          host.runtimeForResume[profile] = '$profile-resumed-runtime';
        } else {
          host.connectDelay = connection;
        }
        host.readCatalog = (profile) async {
          if (retained) await connection.future;
          if (!connection.isCompleted) {
            throw JsonRpcError(
              'commands.catalog',
              'Connection unavailable',
              reason: 'connection_closed',
            );
          }
          return host.catalog(profile);
        };
        final opening = controller.openBrowserSession(
          ProfileSessionKey(controller.browserResource(profile).scope, 'same'),
          isCurrentRequest: () => true,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: ProfileWorkspaceScreen(
              controller: controller,
              createBotsSession: () => BotsSession((_) async => const []),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 250));
        expect(controller.notificationChat!.runtime.opening, isTrue);
        expect(
          host.commandCalls.where(
            (c) => c.$1 == 'commands.catalog' && c.$2['profile'] == profile,
          ),
          isEmpty,
        );
        connection.complete();
        var opened = false;
        unawaited(opening.then((_) => opened = true));
        for (var i = 0; i < 100 && !opened; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(opened, isTrue);
        await opening;
        await tester.pumpAndSettle();
        expect(find.text('Could not load commands.'), findsNothing);
        expect(
          find.descendant(
            of: find.byType(SlashCommandSuggestions),
            matching: find.text(skill),
          ),
          findsOneWidget,
        );
        expect(controller.current!.chat!.composer.observation.text, skill);
        expect(
          host.commandCalls.where((c) => c.$1 == 'skills.reload'),
          isEmpty,
        );
        expect(
          host.commandCalls.where((c) => c.$1 == 'prompt.submit'),
          isEmpty,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  test(
    'skill refresh reloads Hermes before replacing the cached catalog',
    () async {
      expect(
        (await controller.completeCommand(chat, '/writing-for')).items,
        isEmpty,
      );
      final reload = Completer<Map<String, dynamic>>();
      host.respond = (_, _) => reload.future;
      host.commandCalls.clear();
      final refreshing = controller.refreshCommandCatalog(chat);
      await Future<void>.delayed(Duration.zero);
      expect(host.commandCalls.single.$1, 'skills.reload');
      expect(host.commandCalls.single.$2, {
        'session_id': chat.runtime.runtimeId,
        'profile': 'a',
      });
      host.extraSkillNames.add('/writing-for-agents');
      expect(
        (await controller.completeCommand(chat, '/writing-for')).items,
        isEmpty,
      );
      reload.complete({
        'output': 'Skills reloaded',
        'result': {'total': 2, 'commands': 2},
      });
      await refreshing;
      expect(host.commandCalls.map((c) => c.$1), [
        'skills.reload',
        'commands.catalog',
      ]);
      expect(
        (await controller.completeCommand(
          chat,
          '/writing-for',
        )).items.single.text,
        '/writing-for-agents',
      );
    },
  );

  test(
    'failed backend reload preserves Wing catalog and permits retry',
    () async {
      await controller.commandCatalog(chat);
      host.extraSkillNames.add('/writing-for-agents');
      host.commandCalls.clear();
      host.respond = (_, _) async => throw StateError('Reload failed');
      await expectLater(
        controller.refreshCommandCatalog(chat),
        throwsStateError,
      );
      expect(
        (await controller.completeCommand(chat, '/writing-for')).items,
        isEmpty,
      );
      expect(host.commandCalls.map((c) => c.$1), ['skills.reload']);
      host.respond = null;
      await controller.refreshCommandCatalog(chat);
      expect(
        (await controller.completeCommand(
          chat,
          '/writing-for',
        )).items.single.text,
        '/writing-for-agents',
      );
    },
  );

  test('malformed backend reload does not invalidate Wing catalog', () async {
    await controller.commandCatalog(chat);
    host.extraSkillNames.add('/writing-for-agents');
    host.commandCalls.clear();
    host.respond = (_, _) async => {'output': 'not a reload result'};
    await expectLater(
      controller.refreshCommandCatalog(chat),
      throwsFormatException,
    );
    expect(
      (await controller.completeCommand(chat, '/writing-for')).items,
      isEmpty,
    );
    expect(host.commandCalls.map((c) => c.$1), ['skills.reload']);
  });

  test('late backend reload cannot fetch after workspace disposal', () async {
    final reload = Completer<Map<String, dynamic>>();
    host.respond = (_, _) => reload.future;
    host.commandCalls.clear();
    final refreshing = controller.refreshCommandCatalog(chat);
    final rejected = expectLater(refreshing, throwsStateError);
    controller.dispose();
    controllerDisposed = true;
    reload.complete({
      'output': 'Skills reloaded',
      'result': {'total': 1, 'commands': 1},
    });
    await rejected;
    expect(host.commandCalls.map((c) => c.$1), ['skills.reload']);
  });

  testWidgets('refresh completes the latest query without changing its draft', (
    tester,
  ) async {
    final input = SkillComposerController(text: '/writing-for');
    addTearDown(input.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SlashCommandSuggestions(
            inspectSkill: (_) async {},
            refreshCommands: () => controller.refreshCommandCatalog(chat),
            loadCompletion: (query) => controller.completeCommand(chat, query),
            saveDraft: (text) => controller.updateDraft(chat, text),
            composer: input,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    final reload = Completer<Map<String, dynamic>>();
    host.respond = (_, _) => reload.future;
    await tester.tap(find.byTooltip('Refresh skills'));
    await tester.pump();
    input.text = '/pstack';
    await tester.pump(const Duration(milliseconds: 200));
    host.extraSkillNames.addAll(['/writing-for-agents', '/pstack-unslop']);
    reload.complete({
      'output': 'Skills reloaded',
      'result': {'total': 3, 'commands': 3},
    });
    await tester.pumpAndSettle();
    expect(find.text('/pstack-unslop'), findsOneWidget);
    expect(find.text('/writing-for-agents'), findsNothing);
    expect(input.text, '/pstack');
    expect(host.commandCalls.where((c) => c.$1 == 'prompt.submit'), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('refresh cannot paint a picker after its profile changes', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileWorkspaceScreen(
          controller: controller,
          createBotsSession: () => BotsSession((_) async => const []),
        ),
      ),
    );
    final composer = find.byKey(const Key('profile-message-composer'));
    await tester.enterText(composer, '/writing-for');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    final reload = Completer<Map<String, dynamic>>();
    host.respond = (_, _) => reload.future;
    await tester.tap(find.byTooltip('Refresh skills'));
    await tester.pump();
    await controller.switchProfile('b');
    await controller.createChat(canDispatch: () => true);
    await tester.pump();
    host.extraSkillNames.add('/writing-for-agents');
    reload.complete({
      'output': 'Skills reloaded',
      'result': {'total': 2, 'commands': 2},
    });
    await tester.pumpAndSettle();
    expect(controller.current!.scope.profileName, 'b');
    expect(tester.widget<TextField>(composer).controller!.text, isEmpty);
    expect(find.text('/writing-for-agents'), findsNothing);
    expect(
      host.commandCalls
          .singleWhere((c) => c.$1 == 'skills.reload')
          .$2['profile'],
      'a',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('catalog search includes all 300 custom skills', () {
    final value = host.catalog('a');
    value['pairs'] = [
      ...value['pairs'] as List,
      ...List<List<String>>.generate(
        300,
        (i) => ['/skill-$i', 'Custom skill $i'],
      ),
    ];
    final catalog = SlashCatalog.fromJson(value);
    expect(catalog.search('/').length, 305);
  });

  test(
    'catalog resolves aliases and explains unavailable terminal commands',
    () {
      final catalog = SlashCatalog.fromJson(host.catalog('a'));
      expect(catalog.search('/short').single.text, '/a-skill');
      expect(catalog.unavailable('clear'), contains('terminal'));
    },
  );

  test('invocation parses multiline arguments and refuses a bare slash', () {
    expect(
      SlashInvocation.parse('/skill first\nsecond')!.argument,
      'first\nsecond',
    );
    expect(SlashInvocation.parse('/'), isNull);
  });

  test(
    'skill dispatch expands once and retains visible invocation and arguments',
    () async {
      host.respond = (_, params) async => {
        'type': 'skill',
        'message': 'Expanded skill body',
        'display': '/a-skill first\nsecond',
      };
      chat.composer.editText('/short first\nsecond');
      await controller.send(chat);
      final dispatch = host.commandCalls
          .singleWhere((c) => c.$1 == 'command.dispatch')
          .$2;
      expect(dispatch, containsPair('name', 'a-skill'));
      expect(dispatch['arg'], 'first\nsecond');
      final prompt = host.commandCalls
          .singleWhere((c) => c.$1 == 'prompt.submit')
          .$2;
      expect(prompt['text'], 'Expanded skill body');
      expect(prompt['profile'], 'a');
      expect(prompt['session_id'], 'a-runtime');
      expect(
        chat.reading.messages.single['display_content'],
        '/a-skill first\nsecond',
      );
      expect(chat.composer.observation.text, isEmpty);
      expect(chat.runtime.execution, ChatExecution.running);
    },
  );

  test(
    'late skill reply submits to original owner after a profile switch',
    () async {
      final reply = Completer<Map<String, dynamic>>();
      host.respond = (_, _) => reply.future;
      chat.composer.editText('/a-skill task');
      final send = controller.send(chat);
      await Future<void>.delayed(Duration.zero);
      await controller.switchProfile('b');
      final other = await controller.createChat(canDispatch: () => true);
      other.composer.editText('Keep this draft');
      reply.complete({
        'type': 'send',
        'message': 'Expanded bundle',
        'display': '/a-skill task',
        'notice': 'Loading bundle',
      });
      await send;
      expect(controller.current!.chat, same(other));
      expect(other.composer.observation.text, 'Keep this draft');
      expect(other.reading.messages, isEmpty);
      expect(
        chat.reading.messages
            .where((row) => row['_command_notice'] == true)
            .map((row) => row['content']),
        ['Loading bundle'],
      );
      expect(
        host.commandCalls
            .singleWhere((c) => c.$1 == 'prompt.submit')
            .$2['profile'],
        'a',
      );
      expect(
        (await controller.commandCatalog(other)).commands.first.text,
        '/b-skill',
      );
    },
  );

  test(
    'skill dispatch resumes after its secret preflight is cancelled',
    () async {
      final reply = Completer<Map<String, dynamic>>();
      host.respond = (_, _) => reply.future;
      chat.composer.editText('/a-skill needs setup');

      final sending = controller.send(chat);
      await Future<void>.delayed(Duration.zero);
      host.event('a', 'secret', {
        'request_id': 'skill-secret',
        'env_var': 'FIXTURE_TOKEN',
        'prompt': 'Optional fixture token',
      });
      final request = chat.runtime.secureInput!;
      expect(chat.runtime.needsInput, isTrue);

      await controller.respondSensitivePrompt(
        chat,
        '',
        expectedRequest: request,
      );
      reply.complete({
        'type': 'skill',
        'message': 'Expanded skill prompt after skipped setup',
        'display': '/a-skill needs setup',
      });
      await sending;

      final submissions = host.commandCalls
          .where((call) => call.$1 == 'prompt.submit')
          .toList();
      expect(submissions, hasLength(1));
      expect(
        submissions.single.$2['text'],
        'Expanded skill prompt after skipped setup',
      );
      expect(
        chat.reading.messages.single['display_content'],
        '/a-skill needs setup',
      );
      expect(chat.composer.observation.text, isEmpty);
      expect(chat.runtime.execution, ChatExecution.running);
    },
  );

  test(
    'late secret response acknowledgement does not block the expanded skill prompt',
    () async {
      final dispatch = Completer<Map<String, dynamic>>();
      host.respond = (_, _) => dispatch.future;
      host.sensitiveResponseDelay = Completer<void>();
      chat.composer.editText('/a-skill delayed cancel');

      final sending = controller.send(chat);
      await Future<void>.delayed(Duration.zero);
      host.event('a', 'secret', {
        'request_id': 'delayed-secret',
        'env_var': 'FIXTURE_TOKEN',
      });
      final request = chat.runtime.secureInput!;
      final cancelling = controller.respondSensitivePrompt(
        chat,
        '',
        expectedRequest: request,
      );
      dispatch.complete({
        'type': 'skill',
        'message': 'Expanded while cancel acknowledgement is pending',
      });
      await Future<void>.delayed(Duration.zero);

      expect(
        host.commandCalls.where((call) => call.$1 == 'prompt.submit'),
        hasLength(1),
      );
      expect(chat.runtime.execution, ChatExecution.running);
      host.sensitiveResponseDelay!.complete();
      await cancelling;
      await sending;
      expect(chat.runtime.execution, ChatExecution.running);
      expect(chat.runtime.secureInput, isNull);
    },
  );

  for (final crossing in ['failed answer', 'new request']) {
    test(
      'returned command prompt is refused after $crossing during preparation',
      () async {
        final dispatch = Completer<Map<String, dynamic>>();
        host.respond = (_, _) => dispatch.future;
        host.sensitiveResponseDelay = Completer<void>();
        draftStore.holdPrompt = 'Captured expanded prompt';
        addTearDown(() {
          if (!draftStore.release.isCompleted) draftStore.release.complete();
          if (!host.sensitiveResponseDelay!.isCompleted) {
            host.sensitiveResponseDelay!.complete();
          }
        });
        await controller.updateDraft(chat, '/a-skill captured continuation');
        final sending = controller.send(chat);
        await Future<void>.delayed(Duration.zero);
        host.event('a', 'secret', {'request_id': 'preflight-a'});
        final answering = controller.respondSensitivePrompt(
          chat,
          'synthetic-secret',
          expectedRequest: chat.runtime.secureInput!,
        );
        Object? answerError;
        final settledAnswer = answering.catchError((Object error) {
          answerError = error;
        });
        dispatch.complete({
          'type': 'skill',
          'message': 'Captured expanded prompt',
        });
        await draftStore.preparing.future;
        expect(
          host.commandCalls.where((call) => call.$1 == 'prompt.submit'),
          isEmpty,
        );
        expect(chat.runtime.secureResponding, isTrue);
        if (crossing == 'failed answer') {
          host.sensitiveResponseError = StateError('Definite answer refusal');
        } else {
          host.event('a', 'secret', {'request_id': 'preflight-b'});
        }
        host.sensitiveResponseDelay!.complete();
        await settledAnswer;
        draftStore.release.complete();
        await sending;
        expect(
          host.commandCalls.where((call) => call.$1 == 'prompt.submit'),
          isEmpty,
        );
        expect(
          host.commandCalls.where((call) => call.$1 == 'command.dispatch'),
          hasLength(1),
        );
        expect(
          chat.runtime.secureInput?.requestId,
          crossing == 'failed answer' ? 'preflight-a' : 'preflight-b',
        );
        expect(chat.runtime.secureResponding, isFalse);
        expect(chat.composer.observation.submissionUncertain, isFalse);
        if (crossing == 'failed answer') {
          expect(answerError, isStateError);
        } else {
          expect(answerError, isNull);
        }
      },
    );
  }

  test(
    'secret request during prompt acknowledgement remains a live turn',
    () async {
      host.respond = (_, _) async => {
        'type': 'skill',
        'message': 'Expanded prompt',
      };
      host.promptSubmitStarted = Completer<void>();
      host.promptSubmitDelay = Completer<void>();
      chat.composer.editText('/a-skill live prompt secret');

      final sending = controller.send(chat);
      await host.promptSubmitStarted!.future;
      host.event('a', 'secret', {
        'request_id': 'live-turn-secret',
        'env_var': 'FIXTURE_TOKEN',
      });
      final request = chat.runtime.secureInput!;
      expect(chat.runtime.needsInput, isTrue);
      await controller.respondSensitivePrompt(
        chat,
        '',
        expectedRequest: request,
      );
      expect(chat.runtime.execution, ChatExecution.running);

      host.promptSubmitDelay!.complete();
      await sending;
      expect(
        host.commandCalls.where((call) => call.$1 == 'prompt.submit'),
        hasLength(1),
      );
      expect(chat.runtime.execution, ChatExecution.running);
    },
  );

  test(
    'failed preflight secret response can be retried before skill submit',
    () async {
      final dispatch = Completer<Map<String, dynamic>>();
      host.respond = (_, _) => dispatch.future;
      host.sensitiveResponseError = TimeoutException('retry response');
      chat.composer.editText('/a-skill retry secret');

      final sending = controller.send(chat);
      await Future<void>.delayed(Duration.zero);
      host.event('a', 'secret', {
        'request_id': 'retry-secret',
        'env_var': 'FIXTURE_TOKEN',
      });
      final request = chat.runtime.secureInput!;
      await expectLater(
        controller.respondSensitivePrompt(chat, '', expectedRequest: request),
        throwsA(isA<TimeoutException>()),
      );
      expect(chat.runtime.needsInput, isTrue);
      expect(chat.runtime.secureInput, same(request));

      host.sensitiveResponseError = null;
      await controller.respondSensitivePrompt(
        chat,
        '',
        expectedRequest: request,
      );
      dispatch.complete({
        'type': 'skill',
        'message': 'Expanded after secret retry',
      });
      await sending;

      expect(
        host.commandCalls.where((call) => call.$1 == 'prompt.submit'),
        hasLength(1),
        reason: chat.runtime.error,
      );
      final methods = host.commandCalls.map((call) => call.$1).toList();
      expect(methods, contains('session.resume'));
      expect(
        methods.indexOf('session.resume'),
        lessThan(methods.indexOf('prompt.submit')),
      );
      expect(chat.runtime.execution, ChatExecution.running);
    },
  );

  test(
    'replacement preflight request keeps the original return state',
    () async {
      final dispatch = Completer<Map<String, dynamic>>();
      host.respond = (_, _) => dispatch.future;
      emitChatEvent(controller, chat, 'message.start');
      emitChatEvent(controller, chat, 'session.info', {
        'open_requests': [],
        'running': false,
      });
      await restoreComposerFixture(
        chat: chat,
        preferences: controller.preferences,
        text: '/a-skill replacement secret',
      );

      final sending = controller.send(chat);
      await Future<void>.delayed(Duration.zero);
      host.event('a', 'secret', {
        'request_id': 'first-secret',
        'env_var': 'FIRST_TOKEN',
      });
      host.event('a', 'secret', {
        'request_id': 'replacement-secret',
        'env_var': 'SECOND_TOKEN',
      });
      final replacement = chat.runtime.secureInput!;
      await controller.respondSensitivePrompt(
        chat,
        '',
        expectedRequest: replacement,
      );
      expect(chat.runtime.execution, ChatExecution.completed);

      dispatch.complete({
        'type': 'skill',
        'message': 'Expanded after replacement secret',
      });
      await sending;
      expect(
        host.commandCalls.where((call) => call.$1 == 'prompt.submit'),
        hasLength(1),
      );
      expect(chat.runtime.execution, ChatExecution.running);
    },
  );

  test(
    'sensitive preflight expiry releases every stock request kind',
    () async {
      const cases = [
        'sudo',
        'secret',
        'vault.unlock_prompt',
        'vault.save_login',
        'vault.code',
      ];

      for (var index = 0; index < cases.length; index++) {
        final dispatch = Completer<Map<String, dynamic>>();
        host.respond = (_, _) => dispatch.future;
        emitChatEvent(controller, chat, 'message.start');
        emitChatEvent(controller, chat, 'session.info', {
          'open_requests': [],
          'running': false,
        });
        await restoreComposerFixture(
          chat: chat,
          preferences: controller.preferences,
          text: '/a-skill expiring request $index',
        );
        final sending = controller.send(chat);
        await Future<void>.delayed(Duration.zero);
        final requestId = 'expiring-$index';
        host.event('a', cases[index], {'request_id': requestId});
        expect(chat.runtime.needsInput, isTrue);

        host.event('a', 'request.cancel', {
          'id': requestId,
          'method': cases[index],
          'reason': 'timeout',
        });
        expect(chat.runtime.secureInput, isNull);
        expect(chat.runtime.execution, ChatExecution.completed);
        dispatch.complete({
          'type': 'skill',
          'message': 'Expanded after expiry $index',
        });
        await sending;
        expect(chat.runtime.execution, ChatExecution.running);
      }

      expect(
        host.commandCalls.where((call) => call.$1 == 'prompt.submit'),
        hasLength(cases.length),
      );
    },
  );

  test('sensitive expiry during an active turn stays running', () async {
    emitChatEvent(controller, chat, 'message.start');
    host.event('a', 'secret', {'request_id': 'active-secret-expiry'});
    expect(chat.runtime.needsInput, isTrue);

    host.event('a', 'request.cancel', {
      'id': 'active-secret-expiry',
      'method': 'secret',
      'reason': 'timeout',
    });

    expect(chat.runtime.secureInput, isNull);
    expect(chat.runtime.execution, ChatExecution.running);
  });

  test('concurrent send requests do not execute a command twice', () async {
    final reply = Completer<Map<String, dynamic>>();
    host.respond = (_, _) => reply.future;
    chat.composer.editText('/custom');
    final first = controller.send(chat);
    await controller.send(chat);
    reply.complete({'type': 'exec', 'output': 'Done'});
    await first;
    expect(
      host.commandCalls.where((c) => c.$1 == 'command.dispatch'),
      hasLength(1),
    );
  });

  test('text output settles without expecting stream events', () async {
    chat.composer.editText('/custom');
    await controller.send(chat);
    expect(chat.runtime.blocksTurnAdmission, isFalse);
    expect(chat.runtime.commandRunning, isFalse);
    expect(
      chat.reading.messages
          .where((row) => row['_command_notice'] == true)
          .map((row) => row['content']),
      ['Done'],
    );
    expect(host.commandCalls.where((c) => c.$1 == 'prompt.submit'), isEmpty);
  });

  test(
    'undo prefill edits composer without automatically submitting',
    () async {
      host.respond = (_, _) async => {
        'type': 'prefill',
        'message': 'Edit this question',
        'notice': 'Rewound',
      };
      chat.composer.editText('/undo');
      await controller.send(chat);
      expect(chat.composer.observation.text, 'Edit this question');
      expect(
        chat.reading.messages
            .where((row) => row['_command_notice'] == true)
            .map((row) => row['content']),
        ['Rewound'],
      );
      expect(host.commandCalls.where((c) => c.$1 == 'prompt.submit'), isEmpty);
    },
  );

  test('explicit dispatch refusal routes built-in to slash.exec', () async {
    host.respond = (method, _) async {
      if (method == 'command.dispatch') {
        throw JsonRpcError(
          method,
          'not a quick/plugin/bundle/skill command: model',
          code: 4018,
        );
      }
      return {'output': 'Model changed', 'warning': 'Session only'};
    };
    chat.composer.editText('/model provider/model');
    await controller.send(chat);
    expect(
      host.commandCalls.singleWhere((c) => c.$1 == 'slash.exec').$2['command'],
      '/model provider/model',
    );
    expect(
      chat.reading.messages
          .where((row) => row['_command_notice'] == true)
          .map((row) => row['content']),
      ['Session only', 'Model changed'],
    );
  });

  for (final command in ['/model', '/tools', '/reload-mcp']) {
    for (final stalledMethod in ['command.dispatch', 'slash.exec']) {
      testWidgets(
        'all slash commands stop waiting when $stalledMethod is silent: $command',
        (tester) async {
          final response = Completer<Map<String, dynamic>>();
          var dispatched = false;
          addTearDown(() {
            if (!response.isCompleted) response.complete({'output': 'Late'});
          });
          host.respond = (method, _) async {
            if (method != stalledMethod) {
              throw JsonRpcError(
                method,
                'not a quick/plugin/bundle/skill command: ${command.substring(1)}',
                code: 4018,
              );
            }
            dispatched = true;
            return response.future;
          };
          chat.composer.editText(command);
          final sending = controller.send(chat);
          await tester.pump();
          expect(dispatched, isTrue);
          expect(chat.runtime.commandRunning, isTrue);
          await tester.pump(const Duration(seconds: 61));
          expect(chat.runtime.commandRunning, isFalse);
          expect(chat.runtime.error, contains('uncertain'));
          expect(chat.composer.observation.text, command);
          response.complete({'type': 'send', 'message': 'Late command prompt'});
          await tester.pump();
          await sending;
          expect(chat.composer.observation.text, command);
          expect(chat.reading.messages, isEmpty);
          expect(
            host.commandCalls.where((c) => c.$1 == 'prompt.submit'),
            isEmpty,
          );
          expect(
            host.commandCalls.where((c) => c.$1 == stalledMethod),
            hasLength(1),
          );
        },
      );
    }

    test(
      'all slash commands report worker timeout uncertainty: $command',
      () async {
        host.respond = (method, _) async {
          if (method == 'command.dispatch') {
            throw JsonRpcError(
              method,
              'not a quick/plugin/bundle/skill command: ${command.substring(1)}',
              code: 4018,
            );
          }
          throw JsonRpcError(method, 'slash worker timed out', code: 5030);
        };
        chat.composer.editText(command);
        await controller.send(chat);
        expect(chat.runtime.commandRunning, isFalse);
        expect(chat.runtime.error, contains('uncertain'));
        expect(chat.composer.observation.text, command);
        expect(
          host.commandCalls.where((c) => c.$1 == 'slash.exec'),
          hasLength(1),
        );
        expect(
          host.commandCalls.where((c) => c.$1 == 'prompt.submit'),
          isEmpty,
        );
      },
    );
  }

  testWidgets('a late routing refusal cannot execute after command timeout', (
    tester,
  ) async {
    final response = Completer<Map<String, dynamic>>();
    host.respond = (_, _) => response.future;
    chat.composer.editText('/model');
    final sending = controller.send(chat);
    await tester.pump();
    await tester.pump(const Duration(seconds: 61));
    await sending;
    expect(chat.runtime.commandRunning, isFalse);
    response.completeError(
      JsonRpcError(
        'command.dispatch',
        'not a quick/plugin/bundle/skill command: model',
        code: 4018,
      ),
    );
    await tester.pump();
    expect(host.commandCalls.where((c) => c.$1 == 'slash.exec'), isEmpty);
    expect(chat.composer.observation.text, '/model');
    expect(chat.runtime.error, contains('uncertain'));
  });

  testWidgets('built-in execution has a bound after delayed resolution', (
    tester,
  ) async {
    final resolving = Completer<Map<String, dynamic>>();
    final executing = Completer<Map<String, dynamic>>();
    host.respond = (method, _) =>
        method == 'command.dispatch' ? resolving.future : executing.future;
    chat.composer.editText('/tools');
    final sending = controller.send(chat);
    await tester.pump();
    await tester.pump(const Duration(seconds: 40));
    resolving.completeError(
      JsonRpcError(
        'command.dispatch',
        'not a quick/plugin/bundle/skill command: tools',
        code: 4018,
      ),
    );
    await tester.pump();
    expect(host.commandCalls.where((c) => c.$1 == 'slash.exec'), hasLength(1));
    expect(chat.runtime.commandRunning, isTrue);
    await tester.pump(const Duration(seconds: 21));
    expect(chat.runtime.commandRunning, isTrue);
    await tester.pump(const Duration(seconds: 40));
    await sending;
    expect(chat.runtime.commandRunning, isFalse);
    expect(chat.runtime.error, contains('uncertain'));
    executing.complete({'output': 'Late tools'});
    await tester.pump();
    expect(chat.reading.messages, isEmpty);
    expect(chat.composer.observation.text, '/tools');
  });

  testWidgets('a late command result cannot finish a newer command', (
    tester,
  ) async {
    final previous = Completer<Map<String, dynamic>>();
    host.respond = (_, _) => previous.future;
    chat.composer.editText('/custom');
    final first = controller.send(chat);
    await tester.pump();
    await tester.pump(const Duration(seconds: 61));
    await first;
    final next = Completer<Map<String, dynamic>>();
    host.respond = (_, _) => next.future;
    chat.composer.editText('/another');
    final second = controller.send(chat);
    await tester.pump();
    previous.complete({'type': 'prefill', 'message': 'Stale draft'});
    await tester.pump();
    expect(chat.runtime.commandRunning, isTrue);
    expect(chat.runtime.error, isNull);
    expect(chat.composer.observation.text, '/another');
    next.complete({'type': 'exec', 'output': 'New command finished'});
    await tester.pump();
    await second;
    expect(chat.runtime.commandRunning, isFalse);
    expect(chat.composer.observation.text, isEmpty);
    expect(chat.reading.messages.last['content'], 'New command finished');
  });

  testWidgets('connection recovery retains the uncertain command outcome', (
    tester,
  ) async {
    host.running = false;
    host.respond = (_, _) async => throw JsonRpcError(
      'command.dispatch',
      'Connection closed',
      reason: 'connection_closed',
    );
    chat.composer.editText('/custom');
    final sending = controller.send(chat);
    await tester.pump();
    await sending;
    await tester.pump(const Duration(seconds: 2));
    expect(chat.runtime.offline, isFalse);
    expect(chat.runtime.commandRunning, isFalse);
    expect(chat.runtime.error, contains('uncertain'));
    expect(chat.composer.observation.text, '/custom');
    expect(
      host.commandCalls.where((c) => c.$1 == 'command.dispatch'),
      hasLength(1),
    );
    expect(host.commandCalls.where((c) => c.$1 == 'slash.exec'), isEmpty);
  });

  test('timeout never retries via slash.exec or prompt.submit', () async {
    host.respond = (_, _) async => throw TimeoutException('lost reply');
    chat.composer.editText('/custom');
    await controller.send(chat);
    expect(chat.composer.observation.text, '/custom');
    expect(chat.runtime.error, contains('uncertain'));
    expect(
      host.commandCalls.where(
        (c) => {'slash.exec', 'prompt.submit'}.contains(c.$1),
      ),
      isEmpty,
    );
  });

  test(
    'command error is preserved and is not treated as routing refusal',
    () async {
      host.respond = (method, _) async =>
          throw JsonRpcError(method, 'quick command failed', code: 4018);
      chat.composer.editText('/custom');
      await controller.send(chat);
      expect(chat.runtime.error, contains('quick command failed'));
      expect(chat.composer.observation.text, '/custom');
      expect(host.commandCalls.where((c) => c.$1 == 'slash.exec'), isEmpty);
    },
  );

  test('alias cycles terminate without a model request', () async {
    host.respond = (_, _) async => {'type': 'alias', 'target': 'cycle'};
    chat.composer.editText('/cycle');
    await controller.send(chat);
    expect(chat.runtime.error, contains('alias cycle'));
    expect(
      host.commandCalls.where((c) => c.$1 == 'command.dispatch'),
      hasLength(1),
    );
  });

  test('catalog normalizes quick commands without a leading slash', () {
    final catalog = SlashCatalog.fromJson({
      'pairs': [
        ['deploy', 'User command'],
      ],
      'canon': {'deploy': 'deploy'},
    });
    expect(catalog.commands.single.text, '/deploy');
    expect(catalog.resolve('deploy'), 'deploy');
  });

  test('catalog identifies skills supplied outside the categories array', () {
    final catalog = SlashCatalog.fromJson({
      'pairs': [
        ['/custom-skill', 'Installed skill'],
      ],
      'categories': <Map<String, dynamic>>[],
      'skills': {
        '/custom-skill': {'usage': 0, 'origin': 'local'},
      },
    });
    expect(catalog.commands.single.category, 'Skills');
  });

  test(
    'side-question acknowledgement and completion stay with their owner',
    () async {
      chat.composer.editText('/btw What changed?');
      await controller.send(chat);
      expect(
        chat.sideQuestionDeliveries.single.state,
        SideQuestionDeliveryState.pending,
      );
      expect(chat.sideQuestionDeliveries.single.taskId, 'side-task-1');
      expect(chat.sideQuestionDeliveries.single.question, 'What changed?');
      await controller.switchProfile('b');
      final other = await controller.createChat(canDispatch: () => true);
      host.event('a', 'btw.complete', {
        'task_id': 'side-task-1',
        'question': 'What changed?',
        'text': ' Side answer ',
      });
      final delivery = chat.sideQuestionDeliveries.single;
      expect(delivery.state, SideQuestionDeliveryState.completed);
      expect(delivery.result, 'Side answer');
      expect(
        chat.reading.messages
            .where((row) => row['_command_notice'] == true)
            .map((row) => row['content']),
        ['Started /btw on the Hermes host.'],
      );
      expect(
        other.reading.messages
            .where((row) => row['_command_notice'] == true)
            .map((row) => row['content']),
        isEmpty,
      );
      expect(other.sideQuestionDeliveries, isEmpty);
      expect(host.commandCalls.singleWhere((c) => c.$1 == 'prompt.btw').$2, {
        'session_id': 'a-runtime',
        'text': 'What changed?',
        'profile': 'a',
      });
      expect(host.commandCalls.where((c) => c.$1 == 'slash.exec'), isEmpty);
    },
  );

  test(
    'side-question completions correlate out of order and skip blanks',
    () async {
      host.sideQuestionTaskIds.add('side-task-2');
      chat.composer.editText('/btw First question');
      await controller.send(chat);
      chat.composer.editText('/btw Second question');
      await controller.send(chat);

      host.event('a', 'btw.complete', {
        'task_id': 'side-task-2',
        'question': 'Second question',
        'text': 'Second answer',
      });
      host.event('a', 'btw.complete', {
        'task_id': 'side-task-1',
        'question': 'First question',
        'text': 'First answer',
      });
      host.event('a', 'btw.complete', {
        'task_id': 'ignored',
        'question': 'Blank',
        'text': '   ',
      });

      expect(chat.sideQuestionDeliveries, hasLength(2));
      expect(chat.sideQuestionDeliveries[0].result, 'First answer');
      expect(chat.sideQuestionDeliveries[1].result, 'Second answer');
      expect(
        chat.sideQuestionDeliveries.map((delivery) => delivery.state),
        everyElement(SideQuestionDeliveryState.completed),
      );
    },
  );

  test('event-only side-question completion is still delivered', () async {
    host.event('a', 'btw.complete', {
      'task_id': 'desktop-task',
      'question': 'Asked elsewhere',
      'text': 'Remote answer',
    });

    final delivery = chat.sideQuestionDeliveries.single;
    expect(delivery.taskId, 'desktop-task');
    expect(delivery.question, 'Asked elsewhere');
    expect(delivery.state, SideQuestionDeliveryState.completed);
    expect(delivery.result, 'Remote answer');
  });

  test(
    'background acknowledgement and completion stay with their owner while busy',
    () async {
      emitChatEvent(controller, chat, 'message.start');
      chat.composer.editText('/bg Check the deployment');
      await controller.send(chat);

      final pending = chat.sideQuestionDeliveries.single;
      expect(pending.kind, SideQuestionDeliveryKind.backgroundTask);
      expect(pending.taskId, 'background-task-1');
      expect(pending.question, 'Check the deployment');
      expect(pending.state, SideQuestionDeliveryState.pending);
      expect(chat.runtime.execution, ChatExecution.running);
      await controller.switchProfile('b');
      final other = await controller.createChat(canDispatch: () => true);

      host.event('a', 'background.complete', {
        'task_id': 'background-task-1',
        'text': ' Deployment failed: inspect logs. ',
      });

      final completed = chat.sideQuestionDeliveries.single;
      expect(completed.state, SideQuestionDeliveryState.completed);
      expect(completed.result, 'Deployment failed: inspect logs.');
      expect(other.sideQuestionDeliveries, isEmpty);
      expect(
        host.commandCalls
            .singleWhere((call) => call.$1 == 'prompt.background')
            .$2,
        {
          'session_id': 'a-runtime',
          'text': 'Check the deployment',
          'profile': 'a',
        },
      );
    },
  );

  test(
    'background completion before acknowledgement keeps its result and prompt',
    () async {
      host.sideQuestionTaskIds[0] = 'shared-task';
      chat.composer.editText('/btw Side work');
      await controller.send(chat);
      host.backgroundRespond = (params) {
        host.event('a', 'background.complete', {
          'task_id': 'shared-task',
          'text': 'Background result',
        });
        return {'task_id': 'shared-task'};
      };

      chat.composer.editText('/background Background work');
      await controller.send(chat);

      expect(chat.sideQuestionDeliveries, hasLength(2));
      final side = chat.sideQuestionDeliveries.singleWhere(
        (delivery) => delivery.kind == SideQuestionDeliveryKind.sideQuestion,
      );
      final background = chat.sideQuestionDeliveries.singleWhere(
        (delivery) => delivery.kind == SideQuestionDeliveryKind.backgroundTask,
      );
      expect(side.state, SideQuestionDeliveryState.pending);
      expect(background.taskId, 'shared-task');
      expect(background.question, 'Background work');
      expect(background.state, SideQuestionDeliveryState.completed);
      expect(background.result, 'Background result');
    },
  );

  test('blank background completion reports a neutral completed result', () {
    host.event('a', 'background.complete', {
      'task_id': 'external-background',
      'text': '   ',
    });

    final delivery = chat.sideQuestionDeliveries.single;
    expect(delivery.kind, SideQuestionDeliveryKind.backgroundTask);
    expect(delivery.state, SideQuestionDeliveryState.completed);
    expect(delivery.result, 'No response text was returned.');
  });

  test(
    'background acknowledgement without a task ID preserves the draft',
    () async {
      host.backgroundRespond = (_) => <String, dynamic>{};
      chat.composer.editText('/bg Keep this command');

      await controller.send(chat);

      expect(chat.composer.observation.text, '/bg Keep this command');
      expect(chat.sideQuestionDeliveries, isEmpty);
      expect(
        chat.runtime.error,
        'Hermes did not confirm the background task. '
        'Check whether it started before sending this draft again.',
      );
      expect(chat.runtime.error, isNot(contains('FormatException')));
    },
  );

  test('yolo toggles the hydrated live session while busy', () async {
    emitChatEvent(controller, chat, 'message.start');
    host.event('a', 'session.info', {'yolo': true});
    chat.composer.editText('/yolo');

    await controller.send(chat);

    expect(
      host.commandCalls.where((call) => call.$1 == 'config.set').single.$2,
      {'session_id': 'a-runtime', 'key': 'yolo', 'value': '0', 'profile': 'a'},
    );
    expect(
      chat.reading.messages
          .where((row) => row['_command_notice'] == true)
          .map((row) => row['content']),
      ['YOLO disabled for this session.'],
    );
    expect(chat.yolo, isFalse);
    expect(chat.composer.observation.text, isEmpty);
    expect(chat.runtime.execution, ChatExecution.running);
    expect(
      host.commandCalls.where(
        (call) => {'command.dispatch', 'slash.exec'}.contains(call.$1),
      ),
      isEmpty,
    );
  });

  test(
    'yolo resumes unknown state and displays the acknowledged state',
    () async {
      // A fresh create response already reports YOLO. Open an existing chat
      // whose initial info omits it, then let the deliberate command resume
      // observe the server's current value through the real owner path.
      controller.dispose();
      host = CommandHost()..reportYolo = false;
      controller = ProfileWorkspaceController(
        connectionIdentity: 'slash-test-host',
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
        preferences: await SharedPreferences.getInstance(),
        appPreferences: appPreferences,
        gatewayFactory: host.gateway,
        draftStore: draftStore,
      );
      await controller.initialize();
      chat = (await controller.openSession(
        ProfileSessionKey(controller.current!.scope, 'same'),
      ))!;
      expect(chat.yolo, isNull);
      host.commandCalls.clear();
      host.reportYolo = true;
      host.yolo = '1';
      host.yoloSetResult = '1';
      chat.composer.editText('/yolo');

      final notification = await controller.send(chat);

      expect(
        host.commandCalls.where((call) => call.$1 == 'config.set').single.$2,
        containsPair('value', '0'),
      );
      expect(
        host.commandCalls
            .where((call) => call.$1 == 'session.resume')
            .single
            .$2,
        {'session_id': 'same', 'display_projection': true, 'profile': 'a'},
      );
      expect(notification, isNull);
      expect(
        chat.reading.messages.last['content'],
        'YOLO enabled for this session.',
      );
      expect(chat.yolo, isTrue);
    },
  );

  for (final restriction in {
    'advanced': ['reload-mcp', 'curator', 'kanban'],
    'settings': ['login'],
  }.entries) {
    for (final name in restriction.value) {
      for (final route in ['direct', 'catalog alias', 'dispatch alias']) {
        test(
          'restricted commands never dispatch: ${restriction.key} /$name via $route',
          () async {
            host.readCatalog = (profile) async => {
              ...host.catalog(profile),
              'canon': {'/shortcut': '/$name'},
              'commands': {
                '/$name': {'desktop': restriction.key},
              },
            };
            host.respond = (_, _) async => {
              'type': 'alias',
              'target': '/$name',
            };
            final text = switch (route) {
              'catalog alias' => '/shortcut argument',
              'dispatch alias' => '/custom argument',
              _ => '/$name argument',
            };
            chat.composer.editText(text);
            await controller.send(chat);
            expect(
              chat.runtime.error,
              contains('not available as a chat command'),
            );
            expect(chat.runtime.error, contains('/$name'));
            expect(chat.runtime.commandRunning, isFalse);
            expect(chat.composer.observation.text, text);
            expect(chat.reading.messages, isEmpty);
            expect(
              host.commandCalls.where(
                (c) => {'slash.exec', 'prompt.submit'}.contains(c.$1),
              ),
              isEmpty,
            );
            expect(
              host.commandCalls
                  .where((c) => c.$1 == 'command.dispatch')
                  .map((c) => c.$2['name']),
              route == 'dispatch alias' ? ['custom'] : isEmpty,
            );
          },
        );
      }
    }
  }

  test('hidden commands remain executable by name', () async {
    host.readCatalog = (profile) async => {
      ...host.catalog(profile),
      'commands': {
        '/model': {'desktop': 'hidden'},
      },
    };
    chat.composer.editText('/model');
    await controller.send(chat);
    expect(chat.runtime.error, isNull);
    expect(chat.composer.observation.text, isEmpty);
    expect(
      host.commandCalls
          .singleWhere((c) => c.$1 == 'command.dispatch')
          .$2['name'],
      'model',
    );
  });

  test('phone-owned commands retain their local handler', () async {
    host.readCatalog = (profile) async => {
      ...host.catalog(profile),
      'commands': {
        '/profile': {'desktop': 'terminal'},
      },
    };
    chat.composer.editText('/profile');
    await controller.send(chat);
    expect(chat.runtime.error, isNull);
    expect(chat.composer.observation.text, isEmpty);
    expect(
      host.commandCalls.where(
        (c) =>
            {'command.dispatch', 'slash.exec', 'prompt.submit'}.contains(c.$1),
      ),
      isEmpty,
    );
    expect(chat.reading.messages.single['content'], 'Profile: a');
  });

  test('terminal commands explain requirement and preserve draft', () async {
    chat.composer.editText('/clear');
    await controller.send(chat);
    expect(chat.runtime.error, contains('requires the Hermes terminal'));
    expect(chat.composer.observation.text, '/clear');
    expect(host.commandCalls.where((c) => c.$1 == 'command.dispatch'), isEmpty);
  });

  test(
    'interrupt while busy uses exact session and preserves turn status',
    () async {
      emitChatEvent(controller, chat, 'message.start');
      chat.composer.editText('/interrupt');
      await controller.send(chat);
      expect(
        host.commandCalls
            .singleWhere((c) => c.$1 == 'session.interrupt')
            .$2['session_id'],
        'a-runtime',
      );
      expect(chat.runtime.execution, ChatExecution.running);
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets('long command warning scrolls at 320dp/200% ${brightness.name}', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      host.warning =
          'Some commands are unavailable while this server is reconnecting. Your draft is kept. You can still send a command by name after checking its availability.';
      final input = SkillComposerController(text: '/a-');
      addTearDown(input.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(brightness),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: Column(
              children: [
                SlashCommandSuggestions(
                  inspectSkill: (_) async {},
                  refreshCommands: () => controller.refreshCommandCatalog(chat),
                  loadCompletion: (query) =>
                      controller.completeCommand(chat, query),
                  saveDraft: (text) => controller.updateDraft(chat, text),
                  composer: input,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(find.text('/a-skill'), 150);
      await tester.tap(find.text('/a-skill'));
      expect(input.text, '/a-skill ');
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'picker searches all skills and inserts selection without sending',
    (tester) async {
      final input = SkillComposerController(text: '/a-');
      addTearDown(input.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                SlashCommandSuggestions(
                  inspectSkill: (_) async {},
                  refreshCommands: () => controller.refreshCommandCatalog(chat),
                  loadCompletion: (query) =>
                      controller.completeCommand(chat, query),
                  saveDraft: (text) => controller.updateDraft(chat, text),
                  composer: input,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(find.text('/a-skill'), findsOneWidget);
      await tester.tap(find.text('/a-skill'));
      expect(input.text, '/a-skill ');
      expect(chat.composer.observation.text, '/a-skill ');
      expect(host.commandCalls.where((c) => c.$1 == 'prompt.submit'), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'completion captures Unicode range and keeps suffix without mutable items',
    () {
      final row = {'text': 'provider/model', 'meta': 'Model'};
      final completion = SlashCompletion.fromJson('/model 😀pr', {
        'items': [row],
        'replace_from': 8,
      }, warning: 'Current catalog warning');
      row['text'] = 'changed later';
      expect(completion.replaceFrom, 9);
      expect(completion.items.single.text, 'provider/model');
      expect(() => completion.items.clear(), throwsUnsupportedError);
      final edit = completion.select(
        completion.items.single,
        text: '/model 😀pr keep',
        cursor: 11,
      )!;
      expect(edit.text, '/model 😀provider/model keep');
      expect(edit.cursor, 23);
      expect(
        completion.select(
          completion.items.single,
          text: '/model other',
          cursor: 12,
        ),
        isNull,
      );
    },
  );

  test('plugin skill names share completion and reference boundaries', () {
    const name = '/mattpocock-skills:writing-for-agents';
    host.extraSkillNames.add(name);
    final catalog = SlashCatalog.fromJson(host.catalog('a'));
    expect(catalog.commands.singleWhere((c) => c.text == name).isSkill, isTrue);
    for (final text in ['$name ', 'Use ($name).', '😀 Use $name, please']) {
      final reference = catalog.skillReferences(text).single;
      expect(reference.text, name);
      expect(text.substring(reference.start, reference.end), name);
    }
    for (final query in [
      '/mattpocock-skills:',
      name,
      'Use /mattpocock-skills:writing-',
    ]) {
      final completion = SlashCompletion.fromCatalog(query, catalog);
      expect(completion.items.single.text, name);
      expect(
        completion
            .select(completion.items.single, text: query, cursor: query.length)!
            .text,
        '${query.startsWith('Use ') ? 'Use ' : ''}$name ',
      );
    }
    expect(SlashCompletion.queryToken('$name review'), '$name review');
    expect(SlashCompletion.usesCatalog('$name review'), isFalse);
    final invocation = SlashInvocation.parse('$name review')!;
    expect(invocation.name, name.substring(1));
    expect(invocation.argument, 'review');
    for (final text in [
      'Use $name-extra',
      'Use $name/path',
      'Use $name\\path',
      'Use /mattpocock-skills:missing',
      'Use ./mattpocock-skills:writing-for-agents',
      'https://example.com/mattpocock-skills:writing-for-agents',
    ]) {
      expect(catalog.skillReferences(text), isEmpty, reason: text);
    }
    expect(
      SlashSkillReference.inText('Use $name', ['/mattpocock-skills']),
      isEmpty,
    );
    expect(SlashInvocation.parse('/a-skill: review')!.name, 'a-skill');
    expect(SlashInvocation.parse('/a-skill: review')!.argument, 'review');
  });

  for (final original in [
    '/mattpocock-skills:writing-for-agents review',
    'Use /mattpocock-skills:writing-for-agents, please',
  ]) {
    test(
      'plugin skill dispatch retains qualified identity: $original',
      () async {
        host.extraSkillNames.add('/mattpocock-skills:writing-for-agents');
        host.respond = (_, params) async => {
          'type': 'skill',
          'message': 'Expanded ${params['name']}',
        };
        chat.composer.editText(original);
        await controller.send(chat);
        expect(
          host.commandCalls
              .singleWhere((c) => c.$1 == 'command.dispatch')
              .$2['name'],
          'mattpocock-skills:writing-for-agents',
        );
        expect(
          host.commandCalls
              .singleWhere((c) => c.$1 == 'prompt.submit')
              .$2['text'],
          'Expanded mattpocock-skills:writing-for-agents',
        );
        expect(chat.reading.messages.single['display_content'], original);
      },
    );
  }

  test('punctuation delimits skill names like whitespace', () {
    const separators = [
      ',',
      '.',
      '!',
      '?',
      ';',
      '(',
      ')',
      '[',
      ']',
      '{',
      '}',
      '"',
      "'",
      '“',
      '”',
      '‘',
      '’',
      '…',
      '—',
      '，',
      '。',
      '+',
      '=',
      r'$',
    ];
    for (final separator in separators) {
      final text = 'Use$separator/a-skill$separator/a_other$separator';
      final references = SlashSkillReference.inText(text, [
        '/a-skill',
        '/a_other',
      ]).toList();
      expect(references.map((r) => r.text), [
        '/a-skill',
        '/a_other',
      ], reason: text);
      for (final reference in references) {
        expect(text.substring(reference.start, reference.end), reference.text);
      }
      expect(
        SlashCompletion.isQuery('Use /a-skill$separator'),
        isFalse,
        reason: separator,
      );
      final query = 'Use$separator/a-';
      final completion = SlashCompletion.fromCatalog(
        query,
        SlashCatalog.fromJson(host.catalog('a')),
      );
      expect(completion.items.single.text, '/a-skill');
      expect(
        completion
            .select(completion.items.single, text: query, cursor: query.length)!
            .text,
        'Use$separator/a-skill ',
      );
      expect(
        SlashInvocation.parse('/a-skill${separator}review')!.name,
        'a-skill',
      );
      expect(
        SlashInvocation.parse('/a-skill${separator}review')!.argument,
        'review',
      );
    }
    for (final text in ['Use /a-skill-extra', 'Use /a-skill_extra']) {
      expect(SlashSkillReference.inText(text, ['/a-skill']), isEmpty);
      expect(SlashCompletion.isQuery(text), isTrue);
    }
    for (final text in [
      'Use /a-skill/path',
      'Use /a-skill\\path',
      'Use word/a-skill',
      'https://example.com/a-skill',
      'Use ./a-skill',
      'Use ../a-skill',
      'Use (./a-skill).',
      'Use "/tmp/../a-skill"',
      'Use C:/a-skill',
      'https://example.com?skill=/a-skill',
      'https://example.com#/a-skill',
    ]) {
      expect(
        SlashSkillReference.inText(text, ['/a-skill']),
        isEmpty,
        reason: text,
      );
      expect(SlashCompletion.isQuery(text), isFalse, reason: text);
    }
    expect(SlashInvocation.parse('/a-skill "review"')!.argument, '"review"');
    expect(SlashInvocation.parse('/a-skill, (review)')!.argument, '(review)');
    const unicodeText = '😀 (/技能_name-2),';
    final unicodeReference = SlashSkillReference.inText(unicodeText, [
      '/技能_name-2',
    ]).single;
    expect(
      unicodeText.substring(unicodeReference.start, unicodeReference.end),
      '/技能_name-2',
    );
  });

  for (final original in [
    'Use /a-skill, then review.',
    'Use (/a-skill).',
    '/a-skill, review.',
    'Use /a-skill,/a-skill.',
  ]) {
    test('punctuation preserves skill dispatch: $original', () async {
      host.respond = (_, params) async => {
        'type': 'skill',
        'message': 'Expanded ${params['name']}',
      };
      chat.composer.editText(original);
      await controller.send(chat);
      expect(
        host.commandCalls
            .singleWhere((c) => c.$1 == 'command.dispatch')
            .$2['name'],
        'a-skill',
      );
      expect(
        host.commandCalls
            .singleWhere((c) => c.$1 == 'command.dispatch')
            .$2['arg'],
        original.startsWith('/') ? 'review.' : original,
      );
      expect(
        host.commandCalls
            .singleWhere((c) => c.$1 == 'prompt.submit')
            .$2['text'],
        'Expanded a-skill',
      );
      expect(chat.reading.messages.single['display_content'], original);
    });
  }

  testWidgets('inline skill picker replaces the token at the cursor', (
    tester,
  ) async {
    final input = SkillComposerController.fromValue(
      const TextEditingValue(
        text: 'Please 😀 use /a- for this task',
        selection: TextSelection.collapsed(offset: 17),
      ),
    );
    addTearDown(input.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SlashCommandSuggestions(
            inspectSkill: (_) async {},
            refreshCommands: () => controller.refreshCommandCatalog(chat),
            loadCompletion: (query) => controller.completeCommand(chat, query),
            saveDraft: (text) => controller.updateDraft(chat, text),
            composer: input,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(find.text('/a-skill'), findsOneWidget);
    expect(find.text('/model'), findsNothing);
    await tester.tap(find.text('/a-skill'));
    expect(input.text, 'Please 😀 use /a-skill for this task');
    expect(input.selection.extentOffset, 22);
    expect(chat.composer.observation.text, input.text);
    expect(host.commandCalls.where((c) => c.$1 == 'prompt.submit'), isEmpty);
    input.value = const TextEditingValue(
      text: 'Use /a-skill,',
      selection: TextSelection.collapsed(offset: 13),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(find.text('No matching commands.'), findsNothing);
    expect(find.text('Commands'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test(
    'inline skills expand through stock dispatch and retain the visible message',
    () async {
      const original = 'Please use /a-skill for this task';
      host.respond = (_, params) async => {
        'type': 'skill',
        'message': 'Expanded instructions for ${params['arg']}',
      };
      chat.composer.editText(original);
      await controller.send(chat);
      final dispatch = host.commandCalls
          .singleWhere((c) => c.$1 == 'command.dispatch')
          .$2;
      expect(dispatch['name'], 'a-skill');
      expect(dispatch['arg'], original);
      expect(dispatch['session_id'], 'a-runtime');
      expect(
        host.commandCalls
            .singleWhere((c) => c.$1 == 'prompt.submit')
            .$2['text'],
        'Expanded instructions for $original',
      );
      expect(chat.reading.messages.single['display_content'], original);
    },
  );

  test(
    'an inline skill failure retains queued work without submitting plain text',
    () async {
      host.respond = (_, _) async => throw StateError('Skill load failed');
      const original = 'Please use /a-skill for this task';
      chat.composer.editText(original);
      await controller.send(chat);
      expect(host.commandCalls.where((c) => c.$1 == 'prompt.submit'), isEmpty);
      expect(chat.composer.observation.queue.single.text, original);
      expect(chat.runtime.error, contains('Skill load failed'));
    },
  );

  testWidgets('a stalled inline skill cannot submit a late prompt', (
    tester,
  ) async {
    final response = Completer<Map<String, dynamic>>();
    addTearDown(() {
      if (!response.isCompleted) response.complete({'output': 'Late'});
    });
    host.respond = (_, _) => response.future;
    const original = 'Please use /a-skill for this task';
    chat.composer.editText(original);
    final sending = controller.send(chat);
    for (
      var i = 0;
      i < 20 && !host.commandCalls.any((c) => c.$1 == 'command.dispatch');
      i++
    ) {
      // Prompt preparation journals through real I/O before skill dispatch.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      host.commandCalls.where((c) => c.$1 == 'command.dispatch'),
      hasLength(1),
    );
    await tester.pump(const Duration(seconds: 61));
    await sending;
    expect(host.commandCalls.where((c) => c.$1 == 'prompt.submit'), isEmpty);
    expect(chat.composer.observation.queue.single.text, original);
    expect(chat.composer.observation.error, isNotNull);
    response.complete({'type': 'skill', 'message': 'Late skill expansion'});
    await tester.pump();
    expect(host.commandCalls.where((c) => c.$1 == 'prompt.submit'), isEmpty);
    expect(chat.composer.observation.queue.single.text, original);
  });

  test('inline commands and paths stay literal', () async {
    const original =
        'Explain /model and /usr/local and https://example.com/a-skill';
    chat.composer.editText(original);
    await controller.send(chat);
    expect(host.commandCalls.where((c) => c.$1 == 'command.dispatch'), isEmpty);
    expect(
      host.commandCalls.singleWhere((c) => c.$1 == 'prompt.submit').$2['text'],
      original,
    );
    for (final text in [
      'hello https://example.com/a-',
      'hello /usr/local',
      'hello word/a-',
      'hello /a- done',
    ]) {
      expect(SlashCompletion.isQuery(text), isFalse, reason: text);
    }
    expect(SlashCompletion.isQuery('hello\n/a-'), isTrue);
  });

  for (final original in [
    'Use /a-skill and /a-other then /a-skill again',
    '/a-skill use /a-other then /a-skill again',
  ]) {
    test('distinct skills load once: $original', () async {
      host.extraSkillNames.add('/a-other');
      host.respond = (_, params) async => {
        'type': 'skill',
        'message': 'Expanded ${params['name']}',
      };
      chat.composer.editText(original);
      await controller.send(chat);
      expect(
        host.commandCalls
            .where((c) => c.$1 == 'command.dispatch')
            .map((c) => c.$2['name']),
        ['a-skill', 'a-other'],
      );
      expect(
        host.commandCalls
            .singleWhere((c) => c.$1 == 'prompt.submit')
            .$2['text'],
        'Expanded a-skill\n\nExpanded a-other',
      );
      expect(chat.reading.messages.single['display_content'], original);
    });
  }

  test(
    'saved inline skill messages recover the original multiline instruction',
    () {
      const original = 'Please use /a-skill\nfor this task';
      const expanded =
          '[IMPORTANT: The user has invoked the "a-skill" skill.\n'
          'The full skill content is loaded below.]\nPrivate skill body\n'
          'The user has provided the following instruction alongside the skill invocation: $original\n\n'
          '[Runtime note: private]';
      expect(
        answerMessageDisplayText({'role': 'user', 'content': expanded}),
        original,
      );
    },
  );

  testWidgets('native command emphasis keeps arguments plain and IME native', (
    tester,
  ) async {
    final input = SkillComposerController(text: '/reload-mcp now use /a-skill');
    addTearDown(input.dispose);
    input.observeCommands(const [
      SlashCommand('/reload-mcp', 'Reload MCP servers', 'Tools & Skills'),
      SlashCommand('/a-skill', '', 'Skills'),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TextField(controller: input)),
      ),
    );
    final context = tester.element(find.byType(EditableText));
    List<TextSpan> spans() => input
        .buildTextSpan(context: context, withComposing: true)
        .children!
        .whereType<TextSpan>()
        .toList();
    final command = spans().singleWhere((s) => s.text == '/reload-mcp');
    expect(command.style!.fontFamily, 'monospace');
    expect(command.style!.fontWeight, FontWeight.w400);
    expect(command.style!.color, Theme.of(context).colorScheme.primary);
    final skill = spans().singleWhere((s) => s.text == '/a-skill');
    expect(skill.style!.fontWeight, FontWeight.w700);
    expect(skill.style!.fontFamily, isNull);
    expect(
      spans().singleWhere((s) => s.text == ' now use ').style!.color,
      isNull,
    );
    input.value = input.value.copyWith(
      selection: const TextSelection.collapsed(offset: 11),
      composing: const TextRange(start: 8, end: 11),
    );
    expect(
      spans()
          .where((s) => s.style!.decoration == TextDecoration.underline)
          .map((s) => s.text)
          .join(),
      'mcp',
    );
    expect(
      input.buildTextSpan(context: context, withComposing: false).toPlainText(),
      input.text,
    );
    expect(input.selection, const TextSelection.collapsed(offset: 11));
    for (final literal in [
      'Use /reload-mcp now',
      '/reload-mc now',
      '/reload-mcp/path',
      'https://example.com/reload-mcp',
    ]) {
      input.text = literal;
      expect(spans().where((s) => s.style!.fontFamily == 'monospace'), isEmpty);
    }
    input.text = '  /reload-mcp now';
    expect(
      spans().singleWhere((s) => s.text == '/reload-mcp').style!.fontFamily,
      'monospace',
    );
    input.setScope('another profile');
    expect(spans().where((s) => s.style!.color != null), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('plugin skill emphasis covers the full qualified name', (
    tester,
  ) async {
    const name = '/mattpocock-skills:writing-for-agents';
    final input = SkillComposerController(text: '$name ');
    addTearDown(input.dispose);
    input.observeCommands(const [SlashCommand(name, '', 'Skills')]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TextField(controller: input)),
      ),
    );
    final context = tester.element(find.byType(EditableText));
    final span = input.buildTextSpan(context: context, withComposing: true);
    expect(span.toPlainText(), '$name ');
    expect(
      span.children!
          .whereType<TextSpan>()
          .where((s) => s.style?.fontWeight == FontWeight.w700)
          .map((s) => s.text),
      [name],
    );
    expect(
      span.children!.whereType<TextSpan>().first.style!.color,
      Theme.of(context).colorScheme.primary,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'skill emphasis preserves plain text, editing and IME decoration',
    (tester) async {
      final input = SkillComposerController(
        text: 'Use /a-skill then /model and /a-skill/path',
      );
      addTearDown(input.dispose);
      input.observeCommands(const [SlashCommand('/a-skill', '', 'Skills')]);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TextField(controller: input)),
        ),
      );
      final editable = tester.widget<EditableText>(find.byType(EditableText));
      final context = tester.element(find.byType(EditableText));
      TextSpan span() => input.buildTextSpan(
        context: context,
        style: editable.style,
        withComposing: true,
      );
      expect(span().toPlainText(), input.text);
      final skill = span().children!.whereType<TextSpan>().singleWhere(
        (s) => s.text == '/a-skill',
      );
      expect(skill.style!.fontWeight, FontWeight.w700);
      expect(skill.style!.color, Theme.of(context).colorScheme.primary);
      input.text = 'Use (/a-skill), then /a-skill.';
      final punctuationSpans = span().children!.whereType<TextSpan>();
      expect(
        punctuationSpans
            .where((s) => s.style?.fontWeight == FontWeight.w700)
            .map((s) => s.text),
        ['/a-skill', '/a-skill'],
      );
      expect(span().toPlainText(), input.text);
      input.text = 'Use /a-skill then /model and /a-skill/path';
      input.value = input.value.copyWith(
        composing: const TextRange(start: 6, end: 10),
      );
      expect(
        span().children!
            .whereType<TextSpan>()
            .where((s) => s.style?.decoration == TextDecoration.underline)
            .map((s) => s.text)
            .join(),
        '-ski',
      );
      input.text = 'Use /a-skil then /model';
      expect(
        span().children!.whereType<TextSpan>().where(
          (s) => s.style?.fontWeight == FontWeight.w700,
        ),
        isEmpty,
      );
      input.text = 'Use /a-skill';
      input.setScope('another profile');
      expect(
        span().children!.whereType<TextSpan>().where(
          (s) => s.style?.fontWeight == FontWeight.w700,
        ),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('command and skill distinction ${brightness.name} $scale', (
        tester,
      ) async {
        tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final captureKey = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: captureKey,
            child: MaterialApp(
              theme: wingTheme(brightness),
              debugShowCheckedModeBanner: false,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(scale),
                  viewInsets: EdgeInsets.only(bottom: scale == 1 ? 280 : 0),
                ),
                child: child!,
              ),
              home: ProfileWorkspaceScreen(
                controller: controller,
                createBotsSession: () => BotsSession((_) async => const []),
              ),
            ),
          ),
        );
        Future<void> capture(String state) async {
          if (!Platform.environment.containsKey('CAPTURE_SKILL_COMPOSER')) {
            return;
          }
          await tester.runAsync(() async {
            final render =
                captureKey.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await render.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              'build/skill-composer/${brightness.name}-$scale-distinction-$state.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }

        final composer = find.byKey(const Key('profile-message-composer'));
        await tester.enterText(composer, '/');
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pumpAndSettle();
        final skillRow = find.ancestor(
          of: find.text('/a-skill'),
          matching: find.byType(ListTile),
        );
        final commandRow = find.ancestor(
          of: find.text('/model'),
          matching: find.byType(ListTile),
        );
        expect(
          find.descendant(
            of: skillRow,
            matching: find.text('Skill · Profile a skill'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: commandRow,
            matching: find.text('Command · Choose model'),
          ),
          findsOneWidget,
        );
        expect(
          find.byTooltip('Inspect /a-skill').hitTestable(),
          findsOneWidget,
        );
        expect(find.byTooltip('Inspect /model'), findsNothing);
        await tester.ensureVisible(find.text('/model'));
        await tester.pumpAndSettle();
        expect(find.text('/model').hitTestable(), findsOneWidget);
        await capture('picker');
        await tester.tap(find.text('/model'));
        await tester.pumpAndSettle();
        final input = tester.widget<TextField>(composer).controller!;
        expect(input.text, '/model ');
        await tester.enterText(composer, '/model use /a-skill');
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pumpAndSettle();
        final span = input.buildTextSpan(
          context: tester.element(composer),
          withComposing: true,
        );
        expect(span.toPlainText(), '/model use /a-skill');
        expect(
          span.children!
              .whereType<TextSpan>()
              .singleWhere((s) => s.text == '/model')
              .style!
              .fontFamily,
          'monospace',
        );
        expect(
          span.children!
              .whereType<TextSpan>()
              .singleWhere((s) => s.text == '/a-skill')
              .style!
              .fontWeight,
          FontWeight.w700,
        );
        expect(
          tester
              .widget<EditableText>(
                find.descendant(
                  of: composer,
                  matching: find.byType(EditableText),
                ),
              )
              .focusNode
              .hasFocus,
          isTrue,
        );
        expect(
          host.commandCalls.where((c) => c.$1 == 'prompt.submit'),
          isEmpty,
        );
        expect(tester.takeException(), isNull);
        await capture('composer');
        await tester.pumpWidget(const SizedBox.shrink());
      });

      testWidgets('manual skill refresh ${brightness.name} $scale', (
        tester,
      ) async {
        tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final captureKey = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: captureKey,
            child: MaterialApp(
              theme: wingTheme(brightness),
              debugShowCheckedModeBanner: false,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(scale),
                  viewInsets: const EdgeInsets.only(bottom: 280),
                ),
                child: child!,
              ),
              home: ProfileWorkspaceScreen(
                controller: controller,
                createBotsSession: () => BotsSession((_) async => const []),
              ),
            ),
          ),
        );
        final composer = find.byKey(const Key('profile-message-composer'));
        await tester.enterText(composer, '/writing-for');
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pumpAndSettle();
        final refresh = find.byTooltip('Refresh skills');
        expect(refresh.hitTestable(), findsOneWidget);
        expect(tester.getSize(refresh).width, greaterThanOrEqualTo(48));
        expect(tester.getSize(refresh).height, greaterThanOrEqualTo(48));
        expect(find.text('No matching commands.'), findsOneWidget);
        final input = tester.widget<TextField>(composer).controller!;
        final before = input.value;
        final editable = tester.widget<EditableText>(
          find.descendant(of: composer, matching: find.byType(EditableText)),
        );
        expect(editable.focusNode.hasFocus, isTrue);
        Future<void> capture(String state) async {
          expect(
            tester.takeException(),
            isNull,
            reason: 'Skill picker $state must fit with the keyboard open',
          );
          expect(refresh.hitTestable(), findsOneWidget);
          expect(tester.getSize(refresh).width, greaterThanOrEqualTo(48));
          expect(tester.getSize(refresh).height, greaterThanOrEqualTo(48));
          expect(tester.getRect(refresh).bottom, lessThanOrEqualTo(844 - 280));
          if (!Platform.environment.containsKey('CAPTURE_SKILL_COMPOSER')) {
            return;
          }
          await tester.runAsync(() async {
            final render =
                captureKey.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await render.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              'build/skill-composer/${brightness.name}-$scale-refresh-$state.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }

        await capture('empty');
        final reload = Completer<Map<String, dynamic>>();
        host.respond = (_, _) => reload.future;
        host.commandCalls.clear();
        await tester.tap(refresh);
        await tester.pump();
        await tester.tap(refresh);
        await tester.pump();
        expect(
          host.commandCalls.where((c) => c.$1 == 'skills.reload'),
          hasLength(1),
        );
        expect(
          host.commandCalls.where((c) => c.$1 == 'commands.catalog'),
          isEmpty,
        );
        expect(input.value, before);
        expect(editable.focusNode.hasFocus, isTrue);
        await capture('loading');
        host.extraSkillNames.add('/writing-for-agents');
        reload.complete({
          'output': 'Skills reloaded',
          'result': {'total': 2, 'commands': 2},
        });
        await tester.pumpAndSettle();
        expect(find.text('/writing-for-agents'), findsOneWidget);
        expect(input.value, before);
        expect(chat.composer.observation.text, '/writing-for');
        expect(editable.focusNode.hasFocus, isTrue);
        expect(
          host.commandCalls.where((c) => c.$1 == 'prompt.submit'),
          isEmpty,
        );
        await capture('loaded');
        host.respond = (_, _) async => throw StateError('Offline');
        await tester.tap(refresh);
        await tester.pumpAndSettle();
        expect(find.text('Could not refresh skills.'), findsOneWidget);
        expect(refresh.hitTestable(), findsOneWidget);
        expect(input.value, before);
        expect(editable.focusNode.hasFocus, isTrue);
        await capture('error');
        await tester.drag(
          find.text('Could not refresh skills.'),
          const Offset(0, -40),
        );
        await tester.pumpAndSettle();
        expect(
          tester.getRect(find.text('Could not refresh skills.')).bottom,
          lessThanOrEqualTo(
            tester.getRect(find.byType(SlashCommandSuggestions)).bottom,
          ),
        );
        expect(refresh.hitTestable(), findsOneWidget);
        host.respond = null;
        await tester.tap(refresh);
        await tester.pumpAndSettle();
        expect(find.text('/writing-for-agents'), findsOneWidget);
        expect(find.text('Could not refresh skills.'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });

      for (final skillName in [
        '/a-skill',
        '/mattpocock-skills:writing-for-agents',
      ]) {
        testWidgets(
          'mobile inline skill composer $skillName ${brightness.name} $scale',
          (tester) async {
            tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            final query = skillName == '/a-skill'
                ? 'Please use /a-'
                : 'Please use /mattpocock-skills:writing-';
            if (skillName != '/a-skill') host.extraSkillNames.add(skillName);
            final captureKey = GlobalKey();
            await tester.pumpWidget(
              RepaintBoundary(
                key: captureKey,
                child: MaterialApp(
                  theme: wingTheme(brightness),
                  debugShowCheckedModeBanner: false,
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(textScaler: TextScaler.linear(scale)),
                    child: child!,
                  ),
                  home: ProfileWorkspaceScreen(
                    controller: controller,
                    createBotsSession: () => BotsSession((_) async => const []),
                  ),
                ),
              ),
            );
            final composer = find.byKey(const Key('profile-message-composer'));
            await tester.enterText(composer, query);
            await tester.pump(const Duration(milliseconds: 200));
            await tester.pumpAndSettle();
            expect(find.text(skillName), findsOneWidget);
            Future<void> capture(String state) async {
              if (!Platform.environment.containsKey('CAPTURE_SKILL_COMPOSER')) {
                return;
              }
              await tester.runAsync(() async {
                final render =
                    captureKey.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary;
                final image = await render.toImage();
                final bytes = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                final file = File(
                  'build/skill-composer/${brightness.name}-$scale-${skillName.contains(':') ? 'plugin-' : ''}$state.png',
                );
                await file.parent.create(recursive: true);
                await file.writeAsBytes(bytes!.buffer.asUint8List());
                image.dispose();
              });
            }

            await capture('picker');
            final inspect = find.byTooltip('Inspect $skillName');
            expect(tester.getSize(inspect).width, greaterThanOrEqualTo(48));
            expect(tester.getSize(inspect).height, greaterThanOrEqualTo(48));
            await tester.tap(inspect);
            await tester.pumpAndSettle();
            expect(find.byType(SkillDocumentViewer), findsOneWidget);
            expect(
              tester
                  .widget<SkillDocumentViewer>(find.byType(SkillDocumentViewer))
                  .document
                  .rawContent,
              contains('Inspect the original sources.'),
            );
            expect(host.skillReads.single, {
              'profile': 'a',
              'name': skillName.substring(1),
            });
            expect(chat.composer.observation.text, query);
            expect(
              host.commandCalls.where((c) => c.$1 == 'prompt.submit'),
              isEmpty,
            );
            await tester.pageBack();
            await tester.pumpAndSettle();
            expect(tester.widget<TextField>(composer).controller!.text, query);
            expect(inspect.hitTestable(), findsOneWidget);
            await tester.tap(find.text(skillName));
            await tester.pumpAndSettle();
            final input = tester.widget<TextField>(composer).controller!;
            expect(input.text, 'Please use $skillName ');
            expect(
              find.byType(SlashCommandSuggestions).hitTestable(),
              findsNothing,
            );
            final editable = tester.widget<EditableText>(
              find.descendant(
                of: composer,
                matching: find.byType(EditableText),
              ),
            );
            final span = input.buildTextSpan(
              context: tester.element(composer),
              style: editable.style,
              withComposing: true,
            );
            expect(
              span.children!
                  .whereType<TextSpan>()
                  .singleWhere((s) => s.text == skillName)
                  .style!
                  .fontWeight,
              FontWeight.w700,
            );
            expect(tester.takeException(), isNull);
            await capture('selected');
            await tester.pumpWidget(const SizedBox.shrink());
          },
        );
      }
    }
  }

  testWidgets('skill inspection failure retains draft and permits retry', (
    tester,
  ) async {
    host.readSkill = () async => throw StateError('Offline');
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileWorkspaceScreen(
          controller: controller,
          createBotsSession: () => BotsSession((_) async => const []),
        ),
      ),
    );
    final composer = find.byKey(const Key('profile-message-composer'));
    await tester.enterText(composer, '/a-');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Inspect /a-skill'));
    await tester.pumpAndSettle();
    expect(find.byType(SkillDocumentViewer), findsNothing);
    expect(
      find.text(
        'Could not read this skill. Check the connection and try again.',
      ),
      findsOneWidget,
    );
    expect(tester.widget<TextField>(composer).controller!.text, '/a-');
    host.readSkill = null;
    await tester.tap(find.byTooltip('Inspect /a-skill'));
    await tester.pumpAndSettle();
    expect(find.byType(SkillDocumentViewer), findsOneWidget);
    expect(host.skillReads, hasLength(2));
    expect(host.commandCalls.where((c) => c.$1 == 'prompt.submit'), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'held skill inspection ignores repeat taps and a changed profile',
    (tester) async {
      final pending = Completer<Map<String, dynamic>>();
      host.readSkill = () => pending.future;
      await tester.pumpWidget(
        MaterialApp(
          home: ProfileWorkspaceScreen(
            controller: controller,
            createBotsSession: () => BotsSession((_) async => const []),
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const Key('profile-message-composer')),
        '/',
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Inspect /model'), findsNothing);
      final inspect = find.byTooltip('Inspect /a-skill');
      await tester.tap(inspect);
      await tester.pump();
      await tester.tap(inspect);
      await tester.pump();
      expect(host.skillReads, hasLength(1));
      await controller.switchProfile('b');
      await tester.pump();
      pending.complete({'name': 'a-skill', 'content': 'Late instructions'});
      await tester.pumpAndSettle();
      expect(find.byType(SkillDocumentViewer), findsNothing);
      expect(host.skillReads.single, {'profile': 'a', 'name': 'a-skill'});
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test('completion keeps the owning session after a profile switch', () async {
    await controller.switchProfile('b');
    final other = await controller.createChat(canDispatch: () => true);

    expect(other.runtime.runtimeId, isNot(chat.runtime.runtimeId));
    await controller.completeCommand(chat, '/approvals ');
    await controller.completeCommand(other, '/model ');

    expect(
      host.commandCalls
          .where((call) => call.$1 == 'complete.slash')
          .map((call) => call.$2),
      [
        {'session_id': chat.runtime.runtimeId, 'text': '/approvals '},
        {'session_id': other.runtime.runtimeId, 'text': '/model '},
      ],
    );
  });

  testWidgets('selecting /approvals does not show a command loading error', (
    tester,
  ) async {
    host.warning =
        'slash command /handoff unavailable — name taken by built-in; use /skill handoff; '
        'slash command /plan unavailable — name taken by built-in; use /skill plan';
    final input = SkillComposerController(text: '/app');
    addTearDown(input.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SlashCommandSuggestions(
            inspectSkill: (_) async {},
            refreshCommands: () => controller.refreshCommandCatalog(chat),
            loadCompletion: (query) => controller.completeCommand(chat, query),
            saveDraft: (text) => controller.updateDraft(chat, text),
            composer: input,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    await tester.tap(find.text('/approvals'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    expect(input.text, '/approvals ');
    expect(chat.composer.observation.text, '/approvals ');
    expect(find.text('Could not load commands.'), findsNothing);
    expect(find.text('manual'), findsOneWidget);
    expect(host.commandCalls.singleWhere((c) => c.$1 == 'complete.slash').$2, {
      'session_id': 'a-runtime',
      'text': '/approvals ',
    });
    expect(host.commandCalls.where((c) => c.$1 == 'prompt.submit'), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'argument completion replaces only the server range and keeps suffix',
    (tester) async {
      host.respond = (_, _) async => {
        'items': [
          {'text': 'provider/model', 'meta': 'Model'},
        ],
        'replace_from': 7,
      };
      final input = SkillComposerController.fromValue(
        const TextEditingValue(
          text: '/model pr keep',
          selection: TextSelection.collapsed(offset: 9),
        ),
      );
      addTearDown(input.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SlashCommandSuggestions(
              inspectSkill: (_) async {},
              refreshCommands: () => controller.refreshCommandCatalog(chat),
              loadCompletion: (query) =>
                  controller.completeCommand(chat, query),
              saveDraft: (text) => controller.updateDraft(chat, text),
              composer: input,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      await tester.tap(find.text('provider/model'));
      expect(input.text, '/model provider/model keep');
      expect(input.selection.extentOffset, 21);
      await tester.pumpWidget(const SizedBox.shrink());
      final preferences = await SharedPreferences.getInstance();
      await preferences.reload();
      final saved =
          await ComposerDraftStore(
            preferences,
            connectionIdentity: controller.connectionIdentity,
          ).read(
            profileName: chat.key.workspace.profileName,
            sessionId: chat.key.sessionId,
          );
      expect(saved?.text, '/model provider/model keep');
      final restored = ProfileWorkspaceController(
        access: controller.access,
        connectionIdentity: controller.connectionIdentity,
        preferences: preferences,
        appPreferences: appPreferences,
        gatewayFactory: host.gateway,
      );
      addTearDown(restored.dispose);
      await restored.initialize();
      await restored.openSession(chat.key);
      expect(
        restored.current!.chat!.composer.observation.text,
        '/model provider/model keep',
      );
    },
  );

  testWidgets('late completion cannot replace a newer search', (tester) async {
    final delayed = Completer<Map<String, dynamic>>();
    host.respond = (_, _) => delayed.future;
    final input = SkillComposerController(text: '/model pr');
    addTearDown(input.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SlashCommandSuggestions(
            inspectSkill: (_) async {},
            refreshCommands: () => controller.refreshCommandCatalog(chat),
            loadCompletion: (query) => controller.completeCommand(chat, query),
            saveDraft: (text) => controller.updateDraft(chat, text),
            composer: input,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    input.text = '/a-';
    await tester.pump(const Duration(milliseconds: 200));
    delayed.complete({
      'items': [
        {'text': 'stale model', 'meta': ''},
      ],
      'replace_from': 7,
    });
    await tester.pumpAndSettle();
    expect(find.text('/a-skill'), findsOneWidget);
    expect(find.text('stale model'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'mobile composer sends skill and displays invocation, not expanded body',
    (tester) async {
      host.respond = (_, _) async => {
        'type': 'skill',
        'message': 'Internal expanded skill body',
        'display': '/a-skill task',
      };
      await tester.pumpWidget(
        MaterialApp(
          home: ProfileWorkspaceScreen(
            controller: controller,
            createBotsSession: () => BotsSession((_) async => const []),
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const Key('profile-message-composer')),
        '/a-skill task',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Send'));
      // The fixture and widget callbacks use different async zones.
      for (var i = 0; i < 100 && chat.runtime.commandRunning; i++) {
        await tester.pump(const Duration(milliseconds: 10));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      await tester.pump();
      expect(chat.runtime.commandRunning, isFalse);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is SelectableText &&
              (widget.data ?? widget.textSpan?.toPlainText()) ==
                  '/a-skill task',
        ),
        findsOneWidget,
      );
      expect(find.text('Internal expanded skill body'), findsNothing);
      expect(chat.runtime.execution, ChatExecution.running);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
