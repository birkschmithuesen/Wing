import 'package:wing/core/services/chat_runtime.dart';
import 'dart:async';
import 'dart:io';
import 'support/composer_fixture.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/attachment_draft_service.dart';
import 'package:wing/core/models/notification_focus.dart';
import 'package:wing/core/models/queued_prompt_draft.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';

import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'support/profile_paging_fixture.dart';

class RetentionFixture extends ProfilePagingFixture {
  bool obligationDataset = false;

  @override
  List<Map<String, dynamic>> sessions(String profile) => [
    ...super.sessions(profile),
    if (obligationDataset) ...[
      {
        'id': 'protected',
        'title': 'Protected',
        'profile': profile,
        'last_active': now - count * 60,
      },
      for (var i = 0; i < 30; i++)
        {
          'id': 'idle-$i',
          'title': 'Idle idle-$i',
          'profile': profile,
          'last_active': now - (count + i + 1) * 60,
        },
    ],
  ];
  @override
  ProfileGateway gateway(WorkspaceScope scope) {
    final wire = super.gateway(scope);
    return ProfileGateway(
      scope: scope,
      discover: wire.discover,
      get: wire.read,
      ownedDelete: (path, query, canDispatch, onDispatched) async {
        if (!canDispatch()) {
          throw DashboardRequestNotSentException(StateError('Owner retired'));
        }
        onDispatched();
        return {'ok': true};
      },
      rpc: (method, params) async {
        if (method == 'session.resume') {
          final durableId = params['session_id'];
          if (!sessions(
            scope.profileName,
          ).any((row) => row['id'] == durableId)) {
            throw StateError('Unknown authored retention session');
          }
          return wire.call(method, params);
        }
        if (method == 'subagent.list') {
          return {'subagents': <Map<String, dynamic>>[]};
        }
        if (method == 'commands.catalog') {
          return {
            'pairs': [
              ['btw', 'Ask a side question'],
            ],
          };
        }
        if (method == 'prompt.btw') return {'task_id': 'side'};
        return wire.call(method, params);
      },
    );
  }

  @override
  List<Map<String, dynamic>> historyRows(String profile, String id) => [
    for (var i = 0; i < 50; i++)
      {'id': i, 'role': 'assistant', 'content': List.filled(1024, 'x').join()},
  ];
}

void main() {
  late Directory attachmentCache;
  late RetentionFixture fixture;
  late ProfileWorkspaceController owner;
  late WorkspaceRuntimeFixture runtimes;
  late AppPreferences appPreferences;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    attachmentCache = Directory.systemTemp.createTempSync('wing-retention-');
    runtimes = WorkspaceRuntimeFixture();
    fixture = RetentionFixture()..count = 200;
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    owner = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: identityTestConnection(),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'retention',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: fixture.gateway,
      runtimeFactory: runtimes.create,
      attachmentService: AttachmentDraftService(
        cacheDirectoryProvider: () async => attachmentCache,
      ),
    );
    await owner.initialize();
  });
  tearDown(() {
    owner.dispose();
    appPreferences.dispose();
    attachmentCache.deleteSync(recursive: true);
  });

  test(
    'increasing navigation dataset plateaus transcript payload and owned chats',
    () async {
      final observations = <(int, int)>[];
      for (var i = 0; i < 100; i++) {
        await owner.openSession(
          ProfileSessionKey(owner.current!.scope, 'chat-$i'),
        );
        owner.showList();
        await Future<void>.delayed(Duration.zero);
        owner.pruneSettledState();
        final contentUnits = owner.current!.chats.values.fold<int>(
          0,
          (sum, chat) =>
              sum +
              chat.reading.messages.fold<int>(
                0,
                (size, row) => size + (row['content'] as String).length,
              ),
        );
        observations.add((owner.retainedChatCount, contentUnits));
      }
      expect(observations.skip(20).map((item) => item.$1).toSet(), {20});
      expect(observations.skip(20).map((item) => item.$2).toSet(), {
        20 * 50 * 1024,
      });
      expect(owner.current!.chats.containsKey('chat-0'), isFalse);
      final firstReads = fixture.calls
          .where((call) => call.$2 == 'session.resume')
          .length;
      await owner.openSession(
        ProfileSessionKey(owner.current!.scope, 'chat-0'),
      );
      expect(
        fixture.calls.where((call) => call.$2 == 'session.resume').length,
        firstReads + 1,
      );
      expect(owner.current!.chat!.reading.messages, hasLength(50));
    },
  );

  final obligations =
      <String, FutureOr<void> Function(ChatRuntime, ProfileChat)>{
        'running turn': (runtime, chat) => runtime.beginTurn(submitting: false),
        'recovery': (runtime, chat) => runtime.beginRecovery(),
        'draft': (runtime, chat) => chat.composer.editText('Unsent'),
        'uncertain draft': (runtime, chat) => restoreComposerFixture(
          chat: chat,
          preferences: owner.preferences,
          text: 'Uncertain work',
          uncertain: true,
        ),
        'attachment': (runtime, chat) async {
          final source = File('${attachmentCache.path}/source.txt')
            ..writeAsStringSync('a');
          final draft = await owner.attachments.prepareGenericFile(
            sourcePath: source.path,
            displayName: 'file.txt',
            mediaType: 'text/plain',
            existingDrafts: const [],
          );
          await restoreComposerFixture(
            chat: chat,
            preferences: owner.preferences,
            appendAttachments: [draft],
          );
        },
        'queue': (runtime, chat) => restoreComposerFixture(
          chat: chat,
          preferences: owner.preferences,
          appendQueued: [QueuedPromptDraft(text: 'Next')],
        ),
        'queue editor': (runtime, chat) async {
          await restoreComposerFixture(
            chat: chat,
            preferences: owner.preferences,
            appendQueued: [QueuedPromptDraft(text: 'Next')],
          );
          await owner.beginQueuedPromptEdit(
            chat,
            chat.composer.observation.queue.single.id,
          );
        },
        'approval': (runtime, chat) => runtime.receiveApproval({
          'request_id': 'approval',
          'command': 'cmd',
        }),
        'question': (runtime, chat) => runtime.receiveQuestions({
          'request_id': 'question',
          'question': 'Which?',
        }),
        'mutation': (runtime, chat) =>
            runtime.beginAnswerChange(submitting: false),
        'command': (runtime, chat) => runtime.beginCommand(),
        'notification': (runtime, chat) =>
            chat.reading.recordNotificationResult(
              const NotificationFocus('answer', 'result'),
            ),
        'subagent': (runtime, chat) => emitChatEvent(
          owner,
          chat,
          'subagent.start',
          {'subagent_id': 'child', 'goal': 'Work'},
        ),
        'unconfirmed child': (runtime, chat) async {
          emitChatEvent(owner, chat, 'subagent.start', {
            'subagent_id': 'child',
            'goal': 'Work',
          });
          await owner.refreshSubagents(chat);
          expect(chat.unconfirmedSubagentIds, {'child'});
        },
        'side question': (runtime, chat) async {
          await owner.updateDraft(chat, '/btw Work');
          await owner.send(chat);
          expect(chat.sideQuestionDeliveries.single.taskId, 'side');
        },
      };
  for (final obligation in obligations.entries) {
    test(
      '${obligation.key} survives cache pressure and retains obsolete owner',
      () async {
        fixture.obligationDataset = true;
        final resource = owner.current!;
        final protected = await openFixtureChat(
          controller: owner,
          key: ProfileSessionKey(resource.scope, 'protected'),
          title: 'Protected',
          select: false,
        );
        final runtime = runtimes.forChat(protected);

        await protected.composer.restore();
        await obligation.value(runtime, protected);
        for (var i = 0; i < 30; i++) {
          await openFixtureChat(
            controller: owner,
            key: ProfileSessionKey(resource.scope, 'idle-$i'),
            title: 'Idle',
            select: false,
          );
          await resource.chats['idle-$i']!.composer.restore();
        }
        owner.pruneSettledState();
        expect(resource.chats['protected'], same(protected));
        expect(owner.retainedChatCount, 21);
        expect(owner.hasRetentionObligations, isTrue);
        // The real delete authority retires the registry after native/runtime work settles.
        runtime.installResume({
          'session_id': 'settled-${protected.runtime.runtimeId}',
          'running': false,
          'open_requests': <Map<String, dynamic>>[],
        });
        runtime.recovered();
        final retiringKey = protected.key;
        await owner.mutateSession(
          retiringKey,
          delete: true,
          canDispatch: () =>
              identical(owner.current, resource) &&
              identical(resource.chats[retiringKey.sessionId], protected),
        );
        expect(resource.chats.containsKey('protected'), isFalse);
        expect(owner.hasRetentionObligations, isFalse);
      },
    );
  }
}
