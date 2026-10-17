import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/widgets/composer_action_button.dart';
import 'package:wing/core/models/attachment_draft.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/models/queued_prompt_draft.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/composer_draft_store.dart';
import 'package:wing/core/services/attachment_draft_service.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/server_connection_status.dart';
import 'package:wing/core/services/profile_selection_store.dart';
import 'package:wing/core/services/profiles_repository.dart';
import 'package:wing/core/services/ws_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DelayedAttachmentDraftService extends AttachmentDraftService {
  final Completer<void> preparationStarted = Completer<void>();
  final Completer<void> finishPreparation = Completer<void>();

  DelayedAttachmentDraftService({required super.cacheDirectoryProvider});

  @override
  Future<AttachmentDraft> prepareGenericFile({
    required String sourcePath,
    required String displayName,
    String mediaType = 'application/octet-stream',
    required Iterable<AttachmentDraft> existingDrafts,
  }) async {
    preparationStarted.complete();
    await finishPreparation.future;
    return super.prepareGenericFile(
      sourcePath: sourcePath,
      displayName: displayName,
      mediaType: mediaType,
      existingDrafts: existingDrafts,
    );
  }
}

class Host {
  final gateways = <String, ProfileGateway>{};
  final calls = <(String, String, Map<String, dynamic>)>[];
  final reads = <(String, Map<String, String>)>[];
  final delays = <String, Completer<void>>{};
  final failures = <String>{};
  final closed = <String>[];
  List<String> profiles = ['a', 'b'];
  bool running = true;
  bool promptSubmitFails = false;
  bool fileAttachFails = false;
  Map<String, dynamic> imageAttachResult = {
    'attached': true,
    'path': '/profile/images/upload.png',
  };
  bool approvalFails = false;
  int approvalResolved = 1;
  List<Map<String, dynamic>> notificationActiveSessions = [];
  Map<String, dynamic>? notificationReplay;
  List<Map<String, dynamic>>? pendingApprovals;
  List<Map<String, dynamic>> approvalOpenRequests = [];
  Completer<void>? pendingApprovalDelay;
  Completer<void>? approvalDelay;
  Completer<void>? promptSubmitStarted;
  Completer<void>? promptSubmitDelay;
  Completer<void>? connectDelay;
  Completer<void>? activeListDelay;
  int connectFailures = 0;
  Object? connectError;
  int connectCalls = 0;
  int disconnectCalls = 0;
  int resumeFailures = 0;
  bool expireUnsubmittedResume = false;
  int sessionCreates = 0;
  Completer<void>? replacementCreateStarted;
  Completer<void>? replacementCreateDelay;
  Completer<void>? expiredResumeStarted;
  Completer<void>? expiredResumeDelay;
  bool expiredResumeWasDelayed = false;
  Map<String, dynamic>? inflight;
  Map<String, dynamic>? todoState;
  List<Map<String, dynamic>>? historyMessages;
  Completer<void>? projectDelay;
  bool wrongProjectOwner = false;
  Object? discoveryFailure;
  Map<String, dynamic> clarifyResult = {'status': 'ok'};
  Map<String, dynamic> steerResult = {'status': 'queued'};
  Future<ProfileDiscovery> discover() async {
    if (discoveryFailure case final failure?) throw failure;
    return ProfileDiscovery(
      profiles: profiles.map((p) => HermesProfile(name: p)).toList(),
      currentName: 'a',
      activeName: 'a',
    );
  }

  ProfileGateway gateway(WorkspaceScope scope) {
    final name = scope.profileName;
    return gateways[name] = ProfileGateway(
      scope: scope,
      discover: discover,
      connect: () async {
        connectCalls++;
        await connectDelay?.future;
        if (connectError != null) throw connectError!;
        if (connectFailures > 0) {
          connectFailures--;
          throw TimeoutException('Network is waking up');
        }
      },
      close: () => closed.add(name),
      disconnect: () => disconnectCalls++,
      get: (path, query) async {
        reads.add((path, query));
        await delays[name]?.future;
        if (failures.contains(name)) throw Exception('offline');
        if (path == 'sessions') {
          return {
            'offset': int.parse(query['offset']!),
            'limit': int.parse(query['limit']!),
            'total': 1,
            'sessions': [
              {'id': 'same', 'title': '$name chat', 'profile': name},
            ],
          };
        }
        return {
          'session_id': path.split('/')[1],
          'pagination': {
            'limit': 50,
            'offset': 0,
            'order': 'latest',
            'returned': historyMessages?.length ?? 1,
          },
          'messages':
              historyMessages ??
              [
                {'id': 1, 'role': 'assistant', 'content': '$name completed'},
              ],
        };
      },
      delete: (endpoint, query) async {
        calls.add((name, 'DELETE $endpoint', query));
      },
      rpc: (method, params) async {
        calls.add((name, method, params));
        if (method == 'session.active_list') {
          await activeListDelay?.future;
          return {'sessions': notificationActiveSessions};
        }
        if (method == 'session.events.since') return notificationReplay ?? {};
        if (method == 'file.attach') {
          if (fileAttachFails) throw StateError('Synthetic upload failure');
          return {'attached': true, 'ref_text': 'attached:${params['name']}'};
        }
        if (method == 'image.attach_bytes') return imageAttachResult;
        if (method == 'prompt.submit') {
          promptSubmitStarted?.complete();
          await promptSubmitDelay?.future;
        }
        if (method == 'prompt.submit' && promptSubmitFails) {
          throw TimeoutException('Prompt acknowledgement was lost');
        }
        if (method == 'approval.pending') {
          final pending = pendingApprovals
              ?.map(Map<String, dynamic>.of)
              .toList();
          await pendingApprovalDelay?.future;
          return {'approvals': ?pending};
        }
        if (method == 'approval.respond') {
          await approvalDelay?.future;
          if (approvalFails) throw TimeoutException('Approval failed');
          pendingApprovals?.removeWhere(
            (r) => r['request_id'] == params['request_id'],
          );
          return {'resolved': approvalResolved};
        }
        if (method == 'session.steer') return steerResult;
        if (method == 'session.resume' && resumeFailures > 0) {
          resumeFailures--;
          throw TimeoutException('Session resume temporarily unavailable');
        }
        if (method == 'session.resume' &&
            expireUnsubmittedResume &&
            params['session_id'] == 'same') {
          if (!expiredResumeWasDelayed && expiredResumeDelay != null) {
            expiredResumeWasDelayed = true;
            expiredResumeStarted?.complete();
            await expiredResumeDelay!.future;
          }
          throw JsonRpcError('session.resume', 'session not found', code: 4007);
        }
        if (method == 'clarify.lock' || method == 'request.answer') {
          // Hermes contracts/prompt_voice.py uses Params, not SessionParams:
          // these replies are owned by the server request ID. Unknown fields
          // are rejected by contracts/registry.py before the handler runs.
          final allowed = method == 'clarify.lock'
              ? {'request_id', 'question_id', 'answer', 'profile'}
              : {'id', 'result', 'profile'};
          final unknown = params.keys.where((key) => !allowed.contains(key));
          if (unknown.isNotEmpty) {
            throw JsonRpcError(
              method,
              'invalid params: ${unknown.first}: Extra inputs are not permitted',
              code: 4000,
            );
          }
          return clarifyResult;
        }
        if (method == 'projects.tree') {
          return {
            'projects': [
              {
                'id': 'same',
                'label': '$name project',
                'sessionIds': <String>[],
                'path': '/$name',
                'lastActive': 1,
              },
            ],
          };
        }
        if (method == 'projects.project_sessions') {
          await projectDelay?.future;
          return {
            'project': {
              'id': params['project_id'],
              'repos': [
                {
                  'groups': [
                    {
                      'sessions': [
                        {
                          'id': 'project-chat',
                          'title': 'Project chat',
                          'profile': wrongProjectOwner ? 'other' : name,
                        },
                      ],
                    },
                  ],
                },
              ],
            },
          };
        }
        if (method == 'session.create' || method == 'session.resume') {
          if (method == 'session.create') sessionCreates++;
          final replacement = sessionCreates > 1;
          if (method == 'session.create' && replacement) {
            replacementCreateStarted?.complete();
            await replacementCreateDelay?.future;
          }
          return {
            'session_id': replacement
                ? '$name-replacement-runtime'
                : '$name-runtime',
            'stored_session_id': replacement ? 'replacement' : 'same',
            'session_key': replacement ? 'replacement' : 'same',
            'messages': <Map<String, dynamic>>[],
            'running': method == 'session.resume' && running,
            'inflight': inflight,
            'open_requests': approvalOpenRequests,
            'todo_state': todoState,
            'info': {'profile_name': name},
          };
        }
        if (method == 'projects.create') {
          return {
            'project': {'id': 'new'},
          };
        }
        return {};
      },
    );
  }

  void event(
    String profile,
    String type, [
    Map<String, dynamic> data = const {},
  ]) {
    gateways[profile]!.onEvent!(
      StreamEvent(type: type, data: data, sessionId: '$profile-runtime'),
    );
  }
}

void main() {
  late Host host;
  late ProfileWorkspaceController controller;
  late SharedPreferences preferences;
  late List<ProfileSessionKey> notifications;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    host = Host();
    notifications = [];
    controller = ProfileWorkspaceController(
      connectionIdentity: 'original-settings',
      connection: SavedConnection(
        id: 'host',
        label: 'Host',
        host: 'localhost',
        port: 1,
        apiKey: '',
      ),
      preferences: preferences,
      gatewayFactory: host.gateway,
      onAttention: (notification) async => notifications.add(notification.key),
    );
    await controller.initialize();
  });
  tearDown(() => controller.dispose());

  test(
    'reconnect notification uses recovered answer instead of generic status',
    () async {
      final received = <ProfileNotification>[];
      final connection = controller.connection;
      controller.dispose();
      controller = ProfileWorkspaceController(
        connectionIdentity: 'original-settings',
        connection: connection,
        preferences: preferences,
        gatewayFactory: host.gateway,
        onAttention: (notice) async => received.add(notice),
      );
      await controller.initialize();
      final chat = await controller.createChat();
      chat.draft = 'work';
      await controller.send(chat);
      host.historyMessages = [
        {
          'id': 42,
          'role': 'assistant',
          'content': 'The report is ready for review.',
        },
      ];
      host.running = false;
      await controller.reconnect(chat.key.workspace);
      await Future<void>.delayed(Duration.zero);
      expect(received.last.content.preview, 'The report is ready for review.');
      expect(received.last.focus?.kind, 'answer');
    },
  );

  test(
    'cold approval review loads requests without selecting the chat',
    () async {
      host.running = false;
      host.pendingApprovals = [
        {
          'request_id': 'cold-review',
          'command': 'print(1)',
          'choices': ['once', 'deny'],
        },
      ];
      final key = ProfileSessionKey(controller.current!.scope, 'same');
      controller.showList();
      final chat = await controller.loadNotificationApproval(key);
      await Future<void>.delayed(Duration.zero);
      expect(chat?.approval?['request_id'], 'cold-review');
      expect(controller.notificationChat, isNull);
      expect(controller.visible, isFalse);
      expect(
        host.calls.where((call) => call.$2 == 'approval.respond'),
        isEmpty,
      );
    },
  );

  for (final outcome in [
    'recovered',
    'failed',
    'replaced',
    'joined',
    'timed out',
  ]) {
    test('notification approval recovery: $outcome', () async {
      host.running = false;
      final chat = await controller.createChat();
      final request = <String, dynamic>{
        'request_id': 'notification-original',
        'command': 'print("test")',
        'choices': ['once', 'deny'],
      };
      host.pendingApprovals = [request];
      host.event('a', 'approval', request);
      host.gateways['a']!.onConnectionChanged!(false);
      if (outcome == 'failed') host.connectFailures = 20;
      if (outcome == 'replaced') {
        host.pendingApprovals = [
          {...request, 'request_id': 'replacement'},
        ];
      }
      if (outcome == 'joined' || outcome == 'timed out') {
        host.connectDelay = Completer<void>();
      }
      Future<void>? recovering;
      if (outcome == 'joined') {
        recovering = controller.reconnect(chat.key.workspace);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      Object? failure;
      var finished = false;
      final action = controller
          .approveNotification(chat, 'once', requestId: 'notification-original')
          .catchError((Object error) {
            failure = error;
          })
          .whenComplete(() {
            finished = true;
          });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      if (outcome == 'joined') {
        expect(finished, isFalse);
        host.connectDelay!.complete();
      }
      if (outcome == 'timed out') {
        await Future<void>.delayed(const Duration(seconds: 16));
        expect(finished, isTrue);
        // Completing recovery later must not submit the timed-out intent.
        host.connectDelay!.complete();
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await action;
      if (recovering != null) await recovering;
      final decisions = host.calls
          .where((c) => c.$2 == 'approval.respond')
          .toList();
      if (outcome == 'recovered' || outcome == 'joined') {
        expect(failure, isNull);
        expect(decisions, hasLength(1));
        expect(decisions.single.$3['request_id'], 'notification-original');
      } else {
        expect(failure, isNotNull);
        expect(decisions, isEmpty);
        if (outcome == 'failed' || outcome == 'timed out') {
          expect(
            chat.notificationActionErrorRequestId,
            'notification-original',
          );
          expect(chat.notificationActionError, isNotNull);
        }
        host.connectFailures = 0;
        await controller.reconnect(chat.key.workspace);
        expect(host.calls.where((c) => c.$2 == 'approval.respond'), isEmpty);
      }
    });
  }

  test('restores draft text after controller restart', () async {
    final chat = await controller.createChat();
    await controller.updateDraft(chat, 'unfinished thought');
    final key = chat.key;
    final connection = controller.connection;
    controller.dispose();

    controller = ProfileWorkspaceController(
      connectionIdentity: 'original-settings',
      connection: connection,
      preferences: preferences,
      gatewayFactory: host.gateway,
    );
    await controller.initialize();
    await controller.openSession(key);

    expect(controller.current!.chat!.draft, 'unfinished thought');
  });

  test('recovers a cold saved draft into a fresh local chat', () async {
    final store = ComposerDraftStore(
      preferences,
      connectionIdentity: 'original-settings',
    );
    final source = ProfileSessionKey(controller.current!.scope, 'cold-draft');
    await store.write(
      profileName: 'a',
      sessionId: source.sessionId,
      text: 'Cold camera draft check',
      attachments: const [],
      queuedPrompts: [QueuedPromptDraft(text: 'send later')],
    );
    expect((await controller.savedDraft(source))!.text, contains('Cold'));
    final destination = await controller.createChat();

    await controller.recoverDraft(source, destination);

    expect(destination.draft, 'Cold camera draft check');
    expect(destination.draftSubmissionUncertain, isFalse);
    expect(destination.queuedPrompts.single.text, 'send later');
    expect(destination.queuePaused, isTrue);
    expect(await controller.savedDraft(source), isNull);
    final durable = await store.read(
      profileName: 'a',
      sessionId: destination.key.sessionId,
    );
    expect(durable!.text, 'Cold camera draft check');
    expect(durable.queuePaused, isTrue);
    expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
    expect(
      host.calls.where(
        (call) =>
            call.$2 == 'session.resume' &&
            call.$3['session_id'] == source.sessionId,
      ),
      isEmpty,
    );
  });

  test('does not recover from a draft owned by a live chat', () async {
    final store = ComposerDraftStore(
      preferences,
      connectionIdentity: 'original-settings',
    );
    final source = await controller.createChat();
    await controller.updateDraft(source, 'still being edited');
    final destination = await controller.createChat();

    await expectLater(
      controller.recoverDraft(source.key, destination),
      throwsStateError,
    );

    expect(destination.draft, isEmpty);
    expect(
      (await store.read(
        profileName: 'a',
        sessionId: source.key.sessionId,
      ))!.text,
      'still being edited',
    );
  });

  test('lost prompt acknowledgement preserves the draft', () async {
    final store = ComposerDraftStore(
      preferences,
      connectionIdentity: 'original-settings',
    );
    final chat = await controller.createChat();
    await controller.updateDraft(chat, 'send once');
    host.promptSubmitFails = true;

    await controller.send(chat);

    expect(chat.draft, 'send once');
    expect(
      (await store.read(profileName: 'a', sessionId: 'same'))!.text,
      'send once',
    );

    await controller.reconnect(chat.key.workspace);

    expect(chat.draft, 'send once');
    expect(chat.error, contains('Check the server history'));
  });

  test('accepted prompt clears the durable draft', () async {
    final store = ComposerDraftStore(
      preferences,
      connectionIdentity: 'original-settings',
    );
    final chat = await controller.createChat();
    await controller.updateDraft(chat, 'send once');

    await controller.send(chat);

    expect(chat.draft, isEmpty);
    expect(await store.read(profileName: 'a', sessionId: 'same'), isNull);
  });

  test(
    'expired unsubmitted runtime keeps its draft and project on replacement',
    () async {
      final store = ComposerDraftStore(
        preferences,
        connectionIdentity: 'original-settings',
      );
      final project = controller.current!.projects.single;
      final chat = await controller.createChat(inProject: project);
      final oldKey = chat.key;
      final attachment = AttachmentDraft(
        id: 'camera',
        cachedPath: 'camera.png',
        name: 'camera.png',
        byteLength: 20,
        mediaType: 'image/png',
        kind: AttachmentDraftKind.image,
        sourceImageFormat: AttachmentImageFormat.png,
        sanitized: true,
      );
      chat.attachments.add(attachment);
      chat.queuedPrompts.add(QueuedPromptDraft(text: 'later'));
      chat
        ..model = 'chosen-model'
        ..provider = 'chosen-provider'
        ..reasoningEffort = 'low'
        ..intelligenceRuntime = chat.runtimeId
        ..yolo = true;
      await controller.updateDraft(chat, 'keep this draft');
      host.expireUnsubmittedResume = true;
      controller.current!.reconnectError =
          'Could not reconnect to a. No prompts were resent.';

      await controller.navigateProfile('a');
      await controller.openSession(oldKey, recoverExpiredDraft: true);

      expect(chat.key.sessionId, 'replacement');
      expect(chat.runtimeId, 'a-replacement-runtime');
      expect(chat.draft, 'keep this draft');
      expect(chat.attachments, [same(attachment)]);
      expect(chat.queuedPrompts.single.text, 'later');
      expect(chat.projectId, project['id']);
      expect(chat.intelligenceRuntime, 'a-replacement-runtime');
      expect(chat.yolo, isTrue);
      expect(controller.current!.chat, same(chat));
      expect(controller.current!.reconnectError, isNull);
      expect(
        host.calls.lastWhere((call) => call.$2 == 'session.create').$3['cwd'],
        project['primary_path'],
      );
      expect(await store.read(profileName: 'a', sessionId: 'same'), isNull);
      final migrated = await store.read(
        profileName: 'a',
        sessionId: 'replacement',
      );
      expect(migrated?.text, 'keep this draft');
      expect(migrated?.attachments.single.id, 'camera');
      expect(migrated?.queuedPrompts.single.text, 'later');
      expect(
        host.calls
            .where((call) => call.$2 == 'config.set')
            .map((call) => call.$3['session_id']),
        everyElement('a-replacement-runtime'),
      );
      expect(
        host.calls
            .where((call) => call.$2 == 'config.set')
            .map((call) => call.$3['key']),
        containsAll(['model', 'reasoning', 'yolo']),
      );
    },
  );

  test(
    'unknown resume failure does not replace an unsubmitted runtime',
    () async {
      final chat = await controller.createChat();
      final oldKey = chat.key;
      await controller.updateDraft(chat, 'keep this draft');
      host.resumeFailures = 1;

      await controller.navigateProfile('a');
      await expectLater(
        controller.openSession(oldKey),
        throwsA(isA<TimeoutException>()),
      );

      expect(chat.key, oldKey);
      expect(chat.draft, 'keep this draft');
      expect(host.sessionCreates, 1);
    },
  );

  test('ordinary open does not replace a definitively expired draft', () async {
    final chat = await controller.createChat();
    final oldKey = chat.key;
    await controller.updateDraft(chat, 'keep this draft');
    host.expireUnsubmittedResume = true;

    await controller.navigateProfile('a');
    await expectLater(
      controller.openSession(oldKey),
      throwsA(isA<JsonRpcError>()),
    );

    expect(chat.key, oldKey);
    expect(chat.draft, 'keep this draft');
    expect(host.sessionCreates, 1);
  });

  test('reconnect replaces the selected definitively expired draft', () async {
    final chat = await controller.createChat();
    await controller.updateDraft(chat, 'keep this draft');
    host.expireUnsubmittedResume = true;

    await controller.reconnect(chat.key.workspace);

    expect(chat.key.sessionId, 'replacement');
    expect(chat.draft, 'keep this draft');
    expect(controller.current!.chat, same(chat));
    expect(controller.current!.reconnectError, isNull);
  });

  test(
    'replacement blocks composer writes until the durable key moves',
    () async {
      final store = ComposerDraftStore(
        preferences,
        connectionIdentity: 'original-settings',
      );
      final chat = await controller.createChat();
      final oldKey = chat.key;
      await controller.updateDraft(chat, 'keep this draft');
      host
        ..expireUnsubmittedResume = true
        ..replacementCreateStarted = Completer<void>()
        ..replacementCreateDelay = Completer<void>();
      await controller.navigateProfile('a');

      final opening = controller.openSession(oldKey, recoverExpiredDraft: true);
      await host.replacementCreateStarted!.future;
      final typing = controller.updateDraft(chat, 'racing edit');
      await controller.send(chat);
      await expectLater(
        controller.queuePrompt(chat, 'racing queue'),
        throwsStateError,
      );
      host.replacementCreateDelay!.complete();
      await opening;
      await typing;

      expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
      expect(await store.read(profileName: 'a', sessionId: 'same'), isNull);
      expect(
        (await store.read(profileName: 'a', sessionId: 'replacement'))?.text,
        'racing edit',
      );
    },
  );

  test(
    'camera target follows a draft already replaced by background reconnect',
    () async {
      final chat = await controller.createChat();
      final capturedKey = chat.key;
      await controller.updateDraft(chat, 'camera draft');
      host.expireUnsubmittedResume = true;

      await controller.reconnect(capturedKey.workspace);
      expect(chat.key, isNot(capturedKey));
      await controller.navigateProfile('a');
      await expectLater(
        controller.openSession(capturedKey),
        throwsA(isA<JsonRpcError>()),
      );
      final opened = await controller.openSession(
        capturedKey,
        recoverExpiredDraft: true,
      );

      expect(opened, same(chat));
      expect(chat.draft, 'camera draft');
      expect(
        chat.messages
            .where((row) => row['_command_notice'] == true)
            .map((row) => row['content']),
        isEmpty,
      );
      expect(host.sessionCreates, 2);
      expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
    },
  );

  test(
    'explicit recovery waits for an in-flight replacement of its captured key',
    () async {
      final chat = await controller.createChat();
      final capturedKey = chat.key;
      await controller.updateDraft(chat, 'camera draft');
      host
        ..expireUnsubmittedResume = true
        ..replacementCreateStarted = Completer<void>()
        ..replacementCreateDelay = Completer<void>();

      final reconnecting = controller.reconnect(capturedKey.workspace);
      await host.replacementCreateStarted!.future;
      final opening = controller.openSession(
        capturedKey,
        recoverExpiredDraft: true,
      );
      final openingResult = opening.then<Object?>(
        (value) => value,
        onError: (Object error) => error,
      );

      host.replacementCreateDelay!.complete();
      await reconnecting;
      expect(await openingResult, same(chat));

      expect(chat.key.sessionId, 'replacement');
      expect(chat.draft, 'camera draft');
      expect(host.sessionCreates, 2);
      expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
    },
  );

  test(
    'explicit recovery joins replacement started during its resume request',
    () async {
      final chat = await controller.createChat();
      final capturedKey = chat.key;
      await controller.updateDraft(chat, 'camera draft');
      host
        ..expireUnsubmittedResume = true
        ..expiredResumeStarted = Completer<void>()
        ..expiredResumeDelay = Completer<void>()
        ..replacementCreateStarted = Completer<void>()
        ..replacementCreateDelay = Completer<void>();

      final opening = controller.openSession(
        capturedKey,
        recoverExpiredDraft: true,
      );
      await host.expiredResumeStarted!.future;
      final reconnecting = controller.reconnect(capturedKey.workspace);
      await host.replacementCreateStarted!.future;
      final openingExpectation = expectLater(opening, completion(same(chat)));

      host.expiredResumeDelay!.complete();
      host.replacementCreateDelay!.complete();
      await reconnecting;
      await openingExpectation;

      expect(chat.key.sessionId, 'replacement');
      expect(chat.draft, 'camera draft');
      expect(host.sessionCreates, 2);
      expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
    },
  );

  test('definitive resume failure does not replace a submitted chat', () async {
    final chat = await controller.createChat();
    final oldKey = chat.key;
    await controller.updateDraft(chat, 'accepted prompt');
    await controller.send(chat);
    host.expireUnsubmittedResume = true;

    await controller.navigateProfile('a');
    await expectLater(
      controller.openSession(oldKey),
      throwsA(isA<JsonRpcError>()),
    );

    expect(chat.key, oldKey);
    expect(host.sessionCreates, 1);
  });

  test(
    'reconnect does not clear text edited after a lost acknowledgement',
    () async {
      final chat = await controller.createChat();
      await controller.updateDraft(chat, 'first version');
      host.promptSubmitFails = true;
      await controller.send(chat);
      await controller.updateDraft(chat, 'edited while checking');
      host.promptSubmitFails = false;

      await controller.reconnect(chat.key.workspace);

      expect(chat.draft, 'edited while checking');
    },
  );

  test('rapid prompt taps submit once', () async {
    final chat = await controller.createChat();
    await controller.updateDraft(chat, 'one prompt');
    host.promptSubmitStarted = Completer<void>();
    host.promptSubmitDelay = Completer<void>();

    final first = controller.send(chat);
    final second = controller.send(chat);
    await host.promptSubmitStarted!.future;
    expect(
      host.calls.where((call) => call.$2 == 'prompt.submit'),
      hasLength(1),
    );
    host.promptSubmitDelay!.complete();
    await Future.wait([first, second]);
  });

  test(
    'accepted prompt does not clear follow-up text typed while waiting',
    () async {
      final chat = await controller.createChat();
      await controller.updateDraft(chat, 'first prompt');
      host.promptSubmitStarted = Completer<void>();
      host.promptSubmitDelay = Completer<void>();

      final sending = controller.send(chat);
      await host.promptSubmitStarted!.future;
      await controller.updateDraft(chat, 'follow-up draft');
      host.promptSubmitDelay!.complete();
      await sending;

      expect(chat.draft, 'follow-up draft');
    },
  );

  test('adds and removes the next attachment while a response runs', () async {
    final sandbox = await Directory.systemTemp.createTemp(
      'hermes-running-attachment-',
    );
    try {
      final attachmentService = DelayedAttachmentDraftService(
        cacheDirectoryProvider: () async =>
            Directory('${sandbox.path}${Platform.pathSeparator}cache'),
      );
      controller.dispose();
      controller = ProfileWorkspaceController(
        connectionIdentity: 'original-settings',
        connection: SavedConnection(
          id: 'host',
          label: 'Host',
          host: 'localhost',
          port: 1,
          apiKey: '',
        ),
        preferences: preferences,
        gatewayFactory: host.gateway,
        attachmentService: attachmentService,
      );
      await controller.initialize();
      final chat = await controller.createChat();
      await controller.updateDraft(chat, 'first prompt');
      host.promptSubmitStarted = Completer<void>();
      host.promptSubmitDelay = Completer<void>();
      final sending = controller.send(chat);
      await host.promptSubmitStarted!.future;
      expect(chat.status, ProfileTurnStatus.running);

      final source = File(
        '${sandbox.path}${Platform.pathSeparator}follow-up.txt',
      );
      await source.writeAsString('follow-up file');
      host.promptSubmitDelay!.complete();
      await sending;
      host
        ..promptSubmitStarted = null
        ..promptSubmitDelay = null;
      expect(chat.status, ProfileTurnStatus.running);
      await controller.updateDraft(chat, 'queued follow-up');
      await controller.queuePrompt(chat, 'queued follow-up');
      expect(chat.queuedPrompts, hasLength(1));
      bool? lastCanAdd;
      void observeAttachmentControls() {
        lastCanAdd = controller.canAddAttachment(chat);
      }

      controller.addListener(observeAttachmentControls);
      final adding = controller.addAttachment(
        chat,
        source.path,
        'follow-up.txt',
      );
      await attachmentService.preparationStarted.future;
      final settled = Completer<void>();
      void observeSettlement() {
        if (chat.status == ProfileTurnStatus.completed &&
            !settled.isCompleted) {
          settled.complete();
        }
      }

      controller.addListener(observeSettlement);
      host.event('a', 'message.complete');
      await settled.future;
      controller.removeListener(observeSettlement);
      attachmentService.finishPreparation.complete();
      await adding;

      final added = chat.attachments.single;
      expect(chat.queuedPrompts, isEmpty);
      expect(chat.queuePaused, isFalse);
      final submissions = host.calls
          .where((call) => call.$2 == 'prompt.submit')
          .toList();
      expect(submissions, hasLength(2));
      expect(submissions.last.$3['text'], 'queued follow-up');
      expect(lastCanAdd, isTrue);
      controller.removeListener(observeAttachmentControls);
      expect(controller.canRemoveAttachment(chat, added), isTrue);
      expect(await File(added.cachedPath).exists(), isTrue);
      await controller.removeAttachment(chat, added);
      expect(chat.attachments, isEmpty);
      expect(await File(added.cachedPath).exists(), isFalse);
    } finally {
      if (await sandbox.exists()) await sandbox.delete(recursive: true);
    }
  });

  test('cannot remove an attachment captured by prompt submission', () async {
    final sandbox = await Directory.systemTemp.createTemp(
      'hermes-submitting-attachment-',
    );
    try {
      controller.dispose();
      controller = ProfileWorkspaceController(
        connectionIdentity: 'original-settings',
        connection: SavedConnection(
          id: 'host',
          label: 'Host',
          host: 'localhost',
          port: 1,
          apiKey: '',
        ),
        preferences: preferences,
        gatewayFactory: host.gateway,
        attachmentService: AttachmentDraftService(
          cacheDirectoryProvider: () async =>
              Directory('${sandbox.path}${Platform.pathSeparator}cache'),
        ),
      );
      await controller.initialize();
      final chat = await controller.createChat();
      final source = File(
        '${sandbox.path}${Platform.pathSeparator}original.txt',
      );
      await source.writeAsString('original file');
      await controller.addAttachment(chat, source.path, 'original.txt');
      final captured = chat.attachments.single;
      host.promptSubmitStarted = Completer<void>();
      host.promptSubmitDelay = Completer<void>();
      final sending = controller.send(chat);
      await host.promptSubmitStarted!.future;

      expect(controller.canAddAttachment(chat), isFalse);
      expect(controller.canRemoveAttachment(chat, captured), isFalse);
      await controller.removeAttachment(chat, captured);
      expect(chat.attachments, contains(same(captured)));

      host.promptSubmitDelay!.complete();
      await sending;
      expect(chat.attachments, isEmpty);
      expect(controller.canAddAttachment(chat), isTrue);
    } finally {
      if (await sandbox.exists()) await sandbox.delete(recursive: true);
    }
  });

  test('adds a locally picked file while a saved chat reconnects', () async {
    final sandbox = await Directory.systemTemp.createTemp(
      'hermes-reconnecting-attachment-',
    );
    try {
      controller.dispose();
      controller = ProfileWorkspaceController(
        connectionIdentity: 'original-settings',
        connection: SavedConnection(
          id: 'host',
          label: 'Host',
          host: 'localhost',
          port: 1,
          apiKey: '',
        ),
        preferences: preferences,
        gatewayFactory: host.gateway,
        attachmentService: AttachmentDraftService(
          cacheDirectoryProvider: () async =>
              Directory('${sandbox.path}${Platform.pathSeparator}cache'),
        ),
      );
      await controller.initialize();
      final key = ProfileSessionKey(controller.current!.scope, 'same');
      await controller.openSession(key);
      final chat = controller.current!.chat!;
      await controller.updateDraft(chat, 'Keep this next message');
      final existing = File(
        '${sandbox.path}${Platform.pathSeparator}existing.txt',
      );
      await existing.writeAsString('existing file');
      await controller.addAttachment(chat, existing.path, 'existing.txt');
      final callsBeforePickerReturn = host.calls.length;
      chat.status = ProfileTurnStatus.reconnecting;
      final picked = File('${sandbox.path}${Platform.pathSeparator}picked.txt');
      await picked.writeAsString('picked after background reconnect');

      await controller.addAttachment(chat, picked.path, 'picked.txt');

      expect(chat.draft, 'Keep this next message');
      expect(chat.attachments.map((draft) => draft.name), [
        'existing.txt',
        'picked.txt',
      ]);
      expect(host.calls, hasLength(callsBeforePickerReturn));
      expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
      expect(host.calls.where((call) => call.$2 == 'file.attach'), isEmpty);
    } finally {
      if (await sandbox.exists()) await sandbox.delete(recursive: true);
    }
  });

  test('a stale question panel cannot answer a newer request', () async {
    final chat = await controller.createChat();
    final old = <String, dynamic>{
      'request_id': 'old',
      'question': 'Old question',
    };
    chat.clarification = {'request_id': 'new', 'question': 'New question'};
    await expectLater(
      controller.clarify(chat, 'old answer', expectedRequest: old),
      throwsStateError,
    );
    expect(
      host.calls.where(
        (call) => {'clarify.lock', 'request.answer'}.contains(call.$2),
      ),
      isEmpty,
    );
    expect(chat.clarification!['request_id'], 'new');
  });

  test(
    'failed profile navigation preserves the previous project load',
    () async {
      final data = controller.current!;
      host.projectDelay = Completer<void>();
      final pending = controller.selectProject(data.projects.first);
      host.failures.add('b');
      await controller.navigateProfile('b');
      expect(controller.current, same(data));
      expect(data.projectSessionsLoading, isTrue);
      host.projectDelay!.complete();
      await pending;
      expect(data.projectSessions.single['id'], 'project-chat');
      expect(data.projectSessionsError, isNull);
    },
  );

  test('all reads and RPCs carry immutable canonical profile', () async {
    await controller.createProject('Test', '/a');
    final chat = await controller.createChat();
    chat.draft = 'hello';
    await controller.send(chat);
    chat.approvals.add({
      'request_id': 'once',
      'choices': ['once', 'deny'],
    });
    await controller.approve(
      chat,
      'once',
      requestId: chat.approval!['request_id'] as String,
    );
    await controller.stop(chat);
    expect(host.calls.every((c) => c.$3['profile'] == c.$1), isTrue);
    expect(host.reads.every((r) => r.$2['profile'] == 'a'), isTrue);
    expect(
      host.calls.map((c) => c.$2),
      containsAll([
        'projects.create',
        'session.create',
        'prompt.submit',
        'approval.respond',
        'session.interrupt',
      ]),
    );
  });

  test(
    'steer preserves ownership and reports accepted or rejected status',
    () async {
      final chat = await controller.createChat();
      chat.draft = 'hello';
      await controller.send(chat);
      expect(await controller.steer(chat, 'focus on the error'), isTrue);
      expect(host.calls.last.$2, 'session.steer');
      expect(host.calls.last.$3, {
        'session_id': 'a-runtime',
        'text': 'focus on the error',
        'profile': 'a',
      });

      host.steerResult = {'status': 'rejected'};
      expect(await controller.steer(chat, 'keep this draft'), isFalse);
      expect(chat.runtimeId, 'a-runtime');
    },
  );

  test('steer rejects slash text and a chat without a running turn', () async {
    final chat = await controller.createChat();
    expect(await controller.steer(chat, '/status'), isFalse);
    expect(await controller.steer(chat, 'later'), isFalse);
    expect(host.calls.where((call) => call.$2 == 'session.steer'), isEmpty);
  });

  testWidgets('long approval commands keep actions within a bounded panel', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await controller.createChat();
    host.event('a', 'approval', {
      'request_id': 'long',
      'command': List.generate(100, (i) => 'echo command line $i').join('\n'),
      'choices': ['once', 'deny'],
    });
    await tester.pumpWidget(
      MaterialApp(home: ProfileWorkspaceScreen(controller: controller)),
    );
    await tester.pump();
    expect(
      tester
          .getSize(
            find
                .ancestor(
                  of: find.byType(SelectableText).first,
                  matching: find.byType(SingleChildScrollView),
                )
                .first,
          )
          .height,
      lessThanOrEqualTo(160),
    );
    expect(find.text('Allow once').hitTestable(), findsOneWidget);
    expect(find.text('Deny').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('approval accepts each server-supported scope', () async {
    final chat = await controller.createChat();
    chat.draft = 'hello';
    await controller.send(chat);

    chat.approvals.add({
      'request_id': 'session',
      'choices': ['session', 'deny'],
    });
    await controller.approve(
      chat,
      'session',
      requestId: chat.approval!['request_id'] as String,
    );
    chat.approvals.add({
      'request_id': 'always',
      'choices': ['always', 'deny'],
    });
    await controller.approve(
      chat,
      'always',
      requestId: chat.approval!['request_id'] as String,
    );

    expect(
      host.calls
          .where((call) => call.$2 == 'approval.respond')
          .map((call) => call.$3['choice']),
      ['session', 'always'],
    );
  });

  test('approval sends request ID and keeps a replacement request', () async {
    final chat = await controller.createChat();
    chat.approvals.add({
      'request_id': 'old-request',
      'choices': ['once', 'deny'],
      'command': 'old command',
    });
    host.approvalDelay = Completer<void>();
    final response = controller.approve(
      chat,
      'once',
      requestId: chat.approval!['request_id'] as String,
    );
    await Future<void>.delayed(Duration.zero);
    expect(chat.approvalResponding, isTrue);
    chat.approvals.add({
      'request_id': 'new-request',
      'choices': ['session', 'deny'],
      'command': 'new command',
    });
    host.approvalDelay!.complete();
    await response;
    expect(chat.approval?['request_id'], 'new-request');
    expect(chat.approvalResponding, isFalse);
    expect(
      host.calls.lastWhere((c) => c.$2 == 'approval.respond').$3['request_id'],
      'old-request',
    );
  });

  test('failed approval retains the request for retry', () async {
    final chat = await controller.createChat();
    chat.approvals.add({
      'request_id': 'failed-request',
      'choices': ['always', 'deny'],
    });
    host.approvalFails = true;
    await expectLater(
      controller.approve(
        chat,
        'always',
        requestId: chat.approval!['request_id'] as String,
      ),
      throwsException,
    );
    expect(chat.approval?['request_id'], 'failed-request');
    expect(chat.approvalResponding, isFalse);
  });

  test('approval rejects a scope the server did not offer', () async {
    final chat = await controller.createChat();
    chat.approvals.add({
      'request_id': 'once-only',
      'choices': ['once', 'deny'],
    });
    await expectLater(
      controller.approve(
        chat,
        'always',
        requestId: chat.approval!['request_id'] as String,
      ),
      throwsArgumentError,
    );
    expect(host.calls.where((call) => call.$2 == 'approval.respond'), isEmpty);
  });

  test(
    'completion refresh keeps the entered project bound to refreshed rows',
    () async {
      await controller.selectProject(controller.current!.projects.single);
      final chat = await controller.createChat();
      chat.draft = 'Project work';
      await controller.send(chat);
      host.event('a', 'message.complete');
      await Future<void>.delayed(Duration.zero);
      expect(chat.status, ProfileTurnStatus.completed);
      expect(
        controller.current!.selectedProject,
        same(controller.current!.projects.single),
      );
      await controller.selectProject(controller.current!.selectedProject);
      expect(controller.current!.projectSessionsError, isNull);
    },
  );

  test(
    'unsolicited message starts settle as separate turns without clearing composer state',
    () async {
      final chat = await controller.createChat();
      final attachment = AttachmentDraft(
        id: 'kept-attachment',
        cachedPath: '/tmp/kept.txt',
        name: 'kept.txt',
        byteLength: 4,
        mediaType: 'text/plain',
        kind: AttachmentDraftKind.genericFile,
      );
      chat
        ..messages = [
          {'id': 1, 'role': 'user', 'content': 'Keep this turn'},
        ]
        ..draft = 'Keep this draft'
        ..attachments.add(attachment)
        ..queuedPrompts.add(QueuedPromptDraft(text: 'Keep this queued prompt'))
        ..queuePaused = true
        ..model = 'known-model'
        ..provider = 'known-provider'
        ..reasoningEffort = 'high'
        ..status = ProfileTurnStatus.completed;

      host.event('a', 'message.start');
      expect(chat.status, ProfileTurnStatus.running);
      expect(chat.draft, 'Keep this draft');
      expect(chat.attachments, [same(attachment)]);
      expect(chat.queuedPrompts.single.text, 'Keep this queued prompt');
      expect(chat.model, 'known-model');
      expect(chat.provider, 'known-provider');
      expect(chat.reasoningEffort, 'high');
      expect(chat.messages.single['content'], 'Keep this turn');

      host.event('a', 'message.delta', {'text': 'First'});
      host.event('a', 'message.start');
      expect(chat.streaming, 'First');
      host.event('a', 'message.delta', {'text': ' loop reply'});
      host.historyMessages = [
        {'id': 1, 'role': 'user', 'content': 'Keep this turn'},
        {'id': 2, 'role': 'assistant', 'content': 'First loop reply'},
      ];
      host.event('a', 'message.complete');
      await Future<void>.delayed(Duration.zero);
      expect(chat.status, ProfileTurnStatus.completed);
      expect(chat.streaming, isEmpty);

      host.event('a', 'message.start');
      expect(chat.status, ProfileTurnStatus.running);
      host.event('a', 'message.delta', {'text': 'Second loop reply'});
      host.historyMessages = [
        {'id': 1, 'role': 'user', 'content': 'Keep this turn'},
        {'id': 2, 'role': 'assistant', 'content': 'First loop reply'},
        {'id': 3, 'role': 'assistant', 'content': 'Second loop reply'},
      ];
      host.event('a', 'message.complete');
      await Future<void>.delayed(Duration.zero);

      expect(chat.status, ProfileTurnStatus.completed);
      expect(chat.streaming, isEmpty);
      expect(chat.historyError, isNull);
      expect(
        chat.messages
            .where((message) => message['role'] == 'assistant')
            .map((message) => message['content']),
        ['First loop reply', 'Second loop reply'],
      );
      expect(chat.draft, 'Keep this draft');
      expect(chat.attachments, [same(attachment)]);
      expect(chat.queuedPrompts.single.text, 'Keep this queued prompt');
      expect(chat.queuePaused, isTrue);
    },
  );

  testWidgets('send is available while completed history is still loading', (
    tester,
  ) async {
    final chat = await controller.createChat();
    await controller.updateDraft(chat, 'Next question');
    host.event('a', 'message.start');
    final history = host.delays['a'] = Completer<void>();
    host.event('a', 'message.complete', {'text': 'First answer'});
    await tester.pumpWidget(
      MaterialApp(home: ProfileWorkspaceScreen(controller: controller)),
    );
    try {
      final send = tester.widget<IconButton>(
        find.descendant(
          of: find.byType(ComposerActionButton),
          matching: find.byType(IconButton),
        ),
      );
      expect(send.onPressed, isNotNull);
      await tester.runAsync(() => controller.send(chat));
      expect(
        host.calls.where((call) => call.$2 == 'prompt.submit'),
        hasLength(1),
      );
      expect(chat.status, ProfileTurnStatus.running);
    } finally {
      history.complete();
      await tester.pump();
    }
    // The older history response must not remove the new prompt or finish it.
    expect(chat.status, ProfileTurnStatus.running);
    expect(chat.messages.last['content'], 'Next question');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('an older idle snapshot cannot finish a new submission', () async {
    final chat = await controller.createChat();
    host.running = false;
    host.notificationActiveSessions = [
      {
        'id': chat.runtimeId,
        'session_key': chat.key.sessionId,
        'status': 'idle',
      },
    ];
    host.activeListDelay = Completer<void>();
    host.event('a', 'sessions.changed');
    await Future<void>.delayed(Duration.zero);
    await controller.updateDraft(chat, 'New turn');
    await controller.send(chat);
    host.activeListDelay!.complete();
    await Future<void>.delayed(Duration.zero);
    expect(chat.status, ProfileTurnStatus.running);
    expect(host.calls.where((call) => call.$2 == 'session.resume'), isEmpty);
  });

  test(
    'completion before acknowledgement cannot submit the next draft twice',
    () async {
      final chat = await controller.createChat();
      await controller.updateDraft(chat, 'First question');
      host.promptSubmitStarted = Completer<void>();
      host.promptSubmitDelay = Completer<void>();
      final sending = controller.send(chat);
      await host.promptSubmitStarted!.future;
      host.event('a', 'message.complete', {'text': 'First answer'});
      await controller.updateDraft(chat, 'Next question');
      try {
        await controller.send(chat);
        expect(
          host.calls.where((call) => call.$2 == 'prompt.submit'),
          hasLength(1),
        );
        expect(chat.draft, 'Next question');
      } finally {
        host.promptSubmitDelay!.complete();
        await sending;
      }
      host.promptSubmitStarted = null;
      await controller.send(chat);
      expect(
        host.calls.where((call) => call.$2 == 'prompt.submit'),
        hasLength(2),
      );
    },
  );

  test(
    'queued follow-up waits for acknowledgement after early completion',
    () async {
      final chat = await controller.createChat();
      chat.queuedPrompts.add(QueuedPromptDraft(text: 'Queued question'));
      await controller.updateDraft(chat, 'First question');
      host.promptSubmitStarted = Completer<void>();
      host.promptSubmitDelay = Completer<void>();
      final sending = controller.send(chat);
      await host.promptSubmitStarted!.future;
      host.event('a', 'message.complete', {'text': 'First answer'});
      await Future<void>.delayed(Duration.zero);
      try {
        expect(chat.queuePaused, isFalse);
        expect(chat.queuedPrompts, hasLength(1));
      } finally {
        host.promptSubmitStarted = null;
        host.promptSubmitDelay!.complete();
        await sending;
      }
      await Future<void>.delayed(Duration.zero);
      expect(chat.queuePaused, isFalse);
      expect(chat.queuedPrompts, isEmpty);
      expect(
        host.calls.where((call) => call.$2 == 'prompt.submit'),
        hasLength(2),
      );
    },
  );

  test(
    'unsolicited message start survives an older completed history refresh',
    () async {
      final chat = await controller.createChat();
      chat.status = ProfileTurnStatus.completed;
      host.delays['a'] = Completer<void>();
      host.historyMessages = [
        {'id': 1, 'role': 'assistant', 'content': 'First reply'},
      ];

      host.event('a', 'message.start');
      host.event('a', 'message.delta', {'text': 'First reply'});
      host.event('a', 'message.complete');
      expect(chat.status, ProfileTurnStatus.completed);

      host.event('a', 'message.start');
      host.event('a', 'reasoning.delta', {'text': 'Second reasoning'});
      host.event('a', 'message.delta', {'text': 'Second reply'});
      expect(chat.status, ProfileTurnStatus.running);
      expect(chat.streaming, 'Second reply');
      expect(chat.reasoning, 'Second reasoning');

      host.delays['a']!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(chat.status, ProfileTurnStatus.running);
      expect(chat.streaming, 'Second reply');
      expect(chat.reasoning, 'Second reasoning');

      host.historyMessages = [
        {'id': 1, 'role': 'assistant', 'content': 'First reply'},
        {'id': 2, 'role': 'assistant', 'content': 'Second reply'},
      ];
      host.event('a', 'message.complete');
      await Future<void>.delayed(Duration.zero);
      expect(chat.status, ProfileTurnStatus.completed);
      expect(chat.streaming, isEmpty);
      expect(chat.historyError, isNull);
      expect(chat.messages.map((message) => message['content']), [
        'First reply',
        'Second reply',
      ]);
    },
  );

  test('A continues while B is visible; duplicate IDs stay separate', () async {
    final a = await controller.createChat();
    a.draft = 'A work';
    await controller.send(a);
    controller.setRouteVisibility(controller, true);
    await controller.switchProfile('b');
    final b = await controller.createChat();
    b.draft = 'B draft';
    host.event('a', 'message.delta', {'text': 'A result'});
    expect(a.streaming, 'A result');
    expect(b.streaming, isEmpty);
    expect(a.key, isNot(b.key));
    expect(host.closed, isEmpty);
    expect(host.calls.where((c) => c.$2 == 'session.interrupt'), isEmpty);
    host.event('a', 'message.complete');
    await Future<void>.delayed(Duration.zero);
    expect(a.status, ProfileTurnStatus.completed);
    expect(controller.current!.chat, same(b));
    expect(b.draft, 'B draft');
    expect(notifications, [a.key]);
    await controller.openSession(a.key);
    expect(controller.current!.scope.profileName, 'a');
    expect(controller.current!.chat!.messages.single['content'], 'a completed');
  });

  test('forwards the server push identity with live attention', () async {
    final eventIds = <String?>[];
    final connection = controller.connection;
    controller.dispose();
    controller = ProfileWorkspaceController(
      connectionIdentity: 'original-settings',
      connection: connection,
      preferences: preferences,
      gatewayFactory: host.gateway,
      onAttention: (notification) async => eventIds.add(notification.eventId),
    );
    await controller.initialize();
    final chat = await controller.createChat();
    chat.draft = 'work';
    await controller.send(chat);
    host.event('a', 'message.complete', {'mobile_push_event_id': 'delivery-1'});
    await Future<void>.delayed(Duration.zero);
    expect(eventIds, ['delivery-1']);
  });

  test('rapid A B A ignores a late B load and persists A', () async {
    host.delays['b'] = Completer<void>();
    final b = controller.switchProfile('b');
    await Future<void>.delayed(Duration.zero);
    expect(await controller.switchProfile('a'), isTrue);
    host.delays['b']!.complete();
    expect(await b, isFalse);
    expect(controller.current!.scope.profileName, 'a');
    expect(ProfileSelectionStore(preferences).read('original-settings'), 'a');
  });

  test(
    'project entry uses authoritative scoped membership and owns drafts',
    () async {
      final project = controller.current!.projects.single;
      await controller.selectProject(project);
      expect(controller.current!.visibleSessions.single['id'], 'project-chat');
      expect(host.calls.last.$3, {
        'project_id': 'same',
        'session_limit': 5000,
        'profile': 'a',
      });
      final draft = await controller.createChat();
      expect(draft.projectId, project['id']);
      expect(
        host.calls.lastWhere((call) => call.$2 == 'session.create').$3['cwd'],
        '/a',
      );
      await controller.selectProject(null);
      expect(controller.current!.visibleSessions.single['id'], 'same');
    },
  );

  test('late project load cannot undo leaving the project', () async {
    host.projectDelay = Completer<void>();
    final loading = controller.selectProject(
      controller.current!.projects.single,
    );
    await Future<void>.delayed(Duration.zero);
    await controller.selectProject(null);
    host.projectDelay!.complete();
    await loading;
    expect(controller.current!.selectedProject, isNull);
    expect(controller.current!.projectSessions, isEmpty);
    expect(controller.current!.projectSessionsLoading, isFalse);
  });

  test('project response with another profile fails closed', () async {
    host.wrongProjectOwner = true;
    await controller.selectProject(controller.current!.projects.single);
    expect(controller.current!.visibleSessions, isEmpty);
    expect(controller.current!.projectSessionsError, contains('owner'));
  });

  test('stock error completion is not reported as success', () async {
    final chat = await controller.createChat();
    chat.draft = 'test';
    await controller.send(chat);
    host.event('a', 'message.complete', {
      'status': 'error',
      'text': 'Provider unavailable',
      'error': 'Provider unavailable',
    });
    await Future<void>.delayed(Duration.zero);
    expect(chat.status, ProfileTurnStatus.failed);
    expect(chat.error, contains('Provider unavailable'));
  });

  test('final text survives a failed history refresh', () async {
    final chat = await controller.createChat();
    chat.draft = 'test';
    await controller.send(chat);
    host.failures.add('a');
    host.event('a', 'message.complete', {
      'status': 'completed',
      'text': 'The final response',
    });
    await Future<void>.delayed(Duration.zero);
    expect(chat.messages.last['content'], 'The final response');
    expect(chat.status, ProfileTurnStatus.completed);
    expect(chat.error, contains('History refresh failed'));
  });

  test('failed switch retains committed profile and data', () async {
    host.failures.add('b');
    expect(await controller.switchProfile('b'), isFalse);
    expect(controller.current!.scope.profileName, 'a');
    expect(controller.error, contains('Couldn’t open this workspace'));
  });

  test('deleted profile blocks write, never retries unscoped', () async {
    await controller.switchProfile('b');
    host.profiles = ['a'];
    final before = host.calls.length;
    await expectLater(controller.createChat(), throwsStateError);
    expect(host.calls.length, before);
    expect(controller.current!.scope.profileName, 'b');
  });

  test(
    'notification target for missing profile does not open default',
    () async {
      await controller.openSession(
        ProfileSessionKey(
          WorkspaceScope(
            connectionId: 'host',
            profileName: 'missing',
            connectionIdentity: 'original-settings',
          ),
          'same',
        ),
      );
      expect(controller.current!.scope.profileName, 'a');
      expect(controller.current!.chat, isNull);
      expect(controller.error, contains('no longer available'));
    },
  );

  test(
    'cross-profile project object is rejected even with identical ID',
    () async {
      final aProject = controller.current!.projects.single;
      await controller.switchProfile('b');
      expect(() => controller.selectProject(aProject), throwsArgumentError);
    },
  );

  test('reconnect uses original durable owner without resubmitting', () async {
    final a = await controller.createChat();
    a.draft = 'once';
    await controller.send(a);
    await controller.switchProfile('b');
    await controller.reconnect(a.key.workspace);
    expect(host.calls.where((c) => c.$2 == 'prompt.submit').length, 1);
    final resume = host.calls.lastWhere((c) => c.$2 == 'session.resume');
    expect(resume.$3, {
      'session_id': 'same',
      'profile': 'a',
      'omit_messages': true,
    });
    expect(a.status, ProfileTurnStatus.running);
  });

  test(
    'reconnect restores stock inflight assistant text and failure',
    () async {
      final chat = await controller.createChat();
      chat.draft = 'once';
      await controller.send(chat);
      host.inflight = {'assistant': 'Partial response', 'streaming': true};
      await controller.reconnect(chat.key.workspace);
      expect(chat.streaming, 'Partial response');
      host.running = false;
      host.inflight = {
        'assistant': 'Partial response',
        'status': 'error',
        'error': 'Provider stopped',
      };
      await controller.reconnect(chat.key.workspace);
      expect(chat.status, ProfileTurnStatus.failed);
      expect(chat.error, 'Provider stopped');
      expect(host.calls.where((c) => c.$2 == 'prompt.submit').length, 1);
    },
  );

  test(
    'partial response survives resume until server history is available',
    () async {
      final chat = await controller.createChat();
      chat.status = ProfileTurnStatus.running;
      chat.streaming = 'An answer in progress';
      host.running = false;
      host.failures.add('a');
      await controller.reconnect(chat.key.workspace);
      expect(chat.streaming, 'An answer in progress');
      host.failures.clear();
      await controller.reconnect(chat.key.workspace);
      expect(chat.streaming, isEmpty);
      expect(chat.messages.single['content'], 'a completed');
      expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
    },
  );

  testWidgets('startup timeout then DNS failure recovers without user action', (
    tester,
  ) async {
    controller.dispose();
    controller = ProfileWorkspaceController(
      connection: SavedConnection(
        id: 'host',
        label: 'Host',
        host: 'localhost',
        port: 1,
        apiKey: '',
      ),
      connectionIdentity: 'original-settings',
      preferences: preferences,
      gatewayFactory: host.gateway,
    );
    host.discoveryFailure = TimeoutException(
      'Future not completed',
      const Duration(seconds: 20),
    );
    await controller.initialize();
    expect(controller.error, isNull);
    host.discoveryFailure = const SocketException('Failed host lookup');
    await tester.pump(const Duration(seconds: 1));
    expect(controller.error, isNull);
    host.discoveryFailure = null;
    await tester.pump(const Duration(seconds: 2));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(controller.current?.scope.profileName, 'a');
    expect(controller.error, isNull);
    expect(host.calls.where((c) => c.$2 == 'prompt.submit'), isEmpty);
  });

  testWidgets('refresh keeps loaded chats visible while the network stalls', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: ProfileWorkspaceScreen(controller: controller)),
    );
    await tester.pumpAndSettle();
    expect(find.text('a chat'), findsOneWidget);
    late Future<void> refresh;
    await tester.runAsync(() async {
      host.delays['a'] = Completer<void>();
      refresh = controller.refresh();
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
    expect(find.text('a chat'), findsOneWidget);
    await tester.runAsync(() async {
      host.delays['a']!.complete();
      await refresh;
    });
    await tester.pump();
  });

  testWidgets('idle chat recovers after a transient reconnect failure', (
    tester,
  ) async {
    final chat = await controller.createChat();
    host.running = false;
    host.connectFailures = 1;
    host.gateways['a']!.onConnectionChanged!(false);
    await tester.pump(const Duration(seconds: 1));
    expect(controller.error, isNull);
    await tester.pump(const Duration(seconds: 2));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();

    expect(host.calls.where((c) => c.$2 == 'session.resume'), hasLength(1));
    expect(controller.error, isNull);
    expect(chat.status, ProfileTurnStatus.idle);
    expect(host.calls.where((c) => c.$2 == 'prompt.submit'), isEmpty);
  });

  testWidgets('successful automatic recovery clears the reconnect banner', (
    tester,
  ) async {
    final chat = await controller.createChat();
    chat.draft = 'once';
    await tester.runAsync(() => controller.send(chat));
    host.connectFailures = 1;
    host.gateways['a']!.onConnectionChanged!(false);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 2));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();

    expect(chat.status, ProfileTurnStatus.running);
    expect(controller.error, isNull);
    expect(host.calls.where((c) => c.$2 == 'prompt.submit'), hasLength(1));
  });

  testWidgets('idle chat retries a transient session resume failure', (
    tester,
  ) async {
    final chat = await controller.createChat();
    host.running = false;
    host.resumeFailures = 1;
    await controller.reconnect(chat.key.workspace);
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(host.calls.where((c) => c.$2 == 'session.resume'), hasLength(2));
    expect(controller.error, isNull);
    expect(controller.current!.retry, isNull);
  });

  testWidgets('app focus restarts recovery after the short retry burst', (
    tester,
  ) async {
    final chat = await controller.createChat();
    await controller.updateDraft(chat, 'Keep this draft');
    host.running = false;
    host.connectFailures = 5;
    await tester.pumpWidget(
      MaterialApp(home: ProfileWorkspaceScreen(controller: controller)),
    );
    final before = host.connectCalls;
    host.gateways['a']!.onConnectionChanged!(false);
    for (final seconds in [1, 2, 4, 8, 16]) {
      await tester.pump(Duration(seconds: seconds));
      expect(controller.error, isNull);
      expect(find.byType(MaterialBanner), findsNothing);
    }
    expect(host.connectCalls - before, 5);
    expect(controller.connectionStatus.liveAvailable('a'), isFalse);
    expect(chat.draft, 'Keep this draft');
    await controller.send(chat);
    expect(host.calls.where((c) => c.$2 == 'prompt.submit'), isEmpty);
    // No perpetual polling after the initial burst. Returning to Wing is
    // enough to retry immediately, without a tap on Retry.
    await tester.pump(const Duration(minutes: 2));
    expect(host.connectCalls - before, 5);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(controller.recovering, isFalse);
    await tester.pumpAndSettle();
    expect(find.text('Live updates interrupted'), findsNothing);
    expect(chat.draft, 'Keep this draft');
    expect(chat.status, ProfileTurnStatus.idle);
    expect(host.calls.where((c) => c.$2 == 'prompt.submit'), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('retry clears a failed unopened profile while chat works', () async {
    final owner = controller.current!;
    host.connectError = const SocketException('Connection interrupted');
    expect(await controller.switchProfile('b'), isFalse);
    host.connectError = null;
    expect(controller.current, same(owner));
    expect(await owner.gateway.call('session.active_list'), {'sessions': []});
    expect(controller.connectionStatus.description, 'Reconnecting');

    await controller.resumeConnection();

    expect(await owner.gateway.call('session.active_list'), {'sessions': []});
    expect(controller.connectionStatus.description, 'Connected');
  });

  testWidgets('failed unopened profile reconnects while current chat works', (
    tester,
  ) async {
    host.connectFailures = 1;
    expect(await controller.switchProfile('b'), isFalse);
    expect(controller.current!.scope.profileName, 'a');
    expect(await controller.current!.gateway.call('tools.list'), isEmpty);
    expect(controller.connectionStatus.liveAvailable('b'), isFalse);

    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();

    expect(controller.connectionStatus.description, 'Connected');
    expect(controller.current!.scope.profileName, 'a');
    expect(controller.error, isNull);
  });

  test(
    'restored chat socket clears warning during slow notification checks',
    () async {
      host.activeListDelay = Completer<void>();
      final recovery = controller.reconnect(controller.current!.scope);
      await Future<void>.delayed(Duration.zero);

      expect(await controller.current!.gateway.call('tools.list'), isEmpty);
      expect(controller.connectionStatus.liveAvailable('a'), isTrue);
      expect(
        controller.connectionStatus.phase,
        ServerConnectionPhase.connected,
      );

      host.activeListDelay!.complete();
      await recovery;
    },
  );

  test('retry recovers an interrupted activity-only profile', () async {
    final owner = controller.current!;
    final background = controller.browserResource('b');
    await background.gateway.connect();
    expect(background.loaded, isFalse);
    expect(background.chats, isEmpty);
    host.resumeFailures = 1;
    await expectLater(
      background.gateway.resume('same'),
      throwsA(isA<TimeoutException>()),
    );
    expect(controller.connectionStatus.liveAvailable('b'), isFalse);
    expect(background.retry, isNotNull);

    await controller.resumeConnection();

    expect(await owner.gateway.call('session.active_list'), {'sessions': []});
    expect(controller.connectionStatus.description, 'Connected');
    expect(controller.current, same(owner));
    expect(background.loaded, isFalse);
    expect(background.retry, isNull);
  });

  test(
    'network loss includes a live profile whose list was never loaded',
    () async {
      final background = controller.browserResource('b');
      await background.gateway.connect();
      expect(background.loaded, isFalse);
      final before = host.disconnectCalls;

      controller.networkUnavailable();

      expect(host.disconnectCalls, before + 2);
      expect(controller.connectionStatus.liveAvailable('a'), isFalse);
      expect(controller.connectionStatus.liveAvailable('b'), isFalse);
      // Only an explicit networkRestored() lifts the device-level outage
      // flag (see ServerConnectionStatus.networkLost); a plain resume
      // attempt proving the socket works is not itself proof of the OS's
      // own network state.
      controller.networkRestored();
      await controller.resumeConnection();
      expect(controller.connectionStatus.description, 'Connected');
    },
  );

  test(
    'a message queued during a real network outage shows offline at once and sends exactly once on reconnect',
    () async {
      final chat = await controller.createChat();
      await controller.updateDraft(chat, 'Queue me please');
      // The gateway would throw if a drain were attempted right now; the
      // queue must not even try while the device has no network.
      host.promptSubmitFails = true;

      controller.networkUnavailable();

      // No backoff wait: the device's own network loss is authoritative,
      // unlike the reconnect attempt's own up-to-31s retry budget.
      expect(
        controller.connectionStatus.phase,
        ServerConnectionPhase.disconnected,
      );

      await controller.queuePrompt(chat, chat.draft);

      expect(chat.queuedPrompts.map((p) => p.text), ['Queue me please']);
      expect(chat.queuePaused, isFalse);
      expect(host.calls.where((c) => c.$2 == 'prompt.submit'), isEmpty);

      host.promptSubmitFails = false;
      // This chat never had a turn submitted, so the resumed session reports
      // idle, not running (unlike the sent-prompt scenarios other tests here
      // exercise with the fixture's default `running: true`).
      host.running = false;
      // Mirrors ProfileWorkspaceRegistry.recoverConnections(), which always
      // marks the network restored before asking a controller to reconnect.
      controller.networkRestored();
      await controller.reconnect(chat.key.workspace);

      expect(chat.queuedPrompts, isEmpty);
      expect(host.calls.where((c) => c.$2 == 'prompt.submit'), hasLength(1));
      expect(
        controller.connectionStatus.phase,
        ServerConnectionPhase.connected,
      );
    },
  );

  test(
    'retry leaves browser-only profiles without sockets unchecked',
    () async {
      final background = controller.browserResource('b');
      final before = host.connectCalls;

      await controller.resumeConnection();

      expect(host.connectCalls, before + 1);
      expect(background.loaded, isFalse);
      expect(controller.connectionStatus.liveAvailable('b'), isFalse);
      expect(controller.connectionStatus.description, 'Connected');
    },
  );

  testWidgets('network change restarts exhausted chat-list recovery', (
    tester,
  ) async {
    host.connectFailures = 5;
    host.gateways['a']!.onConnectionChanged!(false);
    for (final seconds in [1, 2, 4, 8, 16]) {
      await tester.pump(Duration(seconds: seconds));
    }
    expect(controller.connectionStatus.liveAvailable('a'), isFalse);
    final calls = host.connectCalls;
    await tester.pump(const Duration(minutes: 2));
    expect(host.connectCalls, calls);
    await tester.runAsync(
      () => controller.resumeConnection(networkChanged: true),
    );
    await tester.pump();
    expect(controller.connectionStatus.description, 'Connected');
    expect(host.calls.where((c) => c.$2 == 'prompt.submit'), isEmpty);
  });

  testWidgets(
    'each recovery burst is bounded and an explicit retry restarts it',
    (tester) async {
      host.connectFailures = 20;
      host.gateways['a']!.onConnectionChanged!(false);
      for (final seconds in [1, 2, 4, 8, 16]) {
        await tester.pump(Duration(seconds: seconds));
      }
      final calls = host.connectCalls;
      await tester.pump(const Duration(minutes: 2));
      expect(host.connectCalls, calls);
      expect(controller.current!.retry, isNull);
      expect(controller.recovering, isTrue);
      expect(controller.current!.reconnectAttempt, 5);
      host.connectFailures = 0;
      await tester.runAsync(controller.resumeConnection);
      await tester.pump();
      expect(controller.connectionStatus.description, 'Connected');
      expect(controller.current!.retry, isNull);
    },
  );

  testWidgets('exhausted session recovery cannot show a green connection', (
    tester,
  ) async {
    final chat = await controller.createChat();
    await controller.updateDraft(chat, 'Keep this draft');
    host.running = false;
    host.resumeFailures = 5;
    host.gateways['a']!.onConnectionChanged!(false);
    for (final seconds in [1, 2, 4, 8, 16]) {
      await tester.pump(Duration(seconds: seconds));
    }
    // An independent activity read can restore the transport without restoring
    // this conversation. That must not clear its failed recovery indicator.
    await tester.runAsync(() => controller.current!.gateway.connect());
    expect(controller.connectionStatus.liveAvailable('a'), isTrue);
    expect(controller.recovering, isTrue);
    expect(controller.current!.retry, isNull);
    expect(
      controller.connectionStatus.phase,
      ServerConnectionPhase.disconnected,
    );
    expect(controller.connectionStatus.recoveryProblem, isNotNull);
    await tester.runAsync(controller.connectionStatus.retry!);
    expect(controller.recovering, isFalse);
    expect(controller.connectionStatus.phase, ServerConnectionPhase.connected);
    expect(chat.draft, 'Keep this draft');
    expect(host.calls.where((call) => call.$2 == 'prompt.submit'), isEmpty);
  });

  testWidgets('sign-in rejection stops automatic live recovery', (
    tester,
  ) async {
    host.connectError = const DashboardHttpException(401, '/api/ws');
    host.gateways['a']!.onConnectionChanged!(false);
    await tester.pump(const Duration(seconds: 1));
    final calls = host.connectCalls;
    await tester.pump(const Duration(minutes: 2));
    expect(host.connectCalls, calls);
    expect(controller.current!.retry, isNull);
    expect(controller.current!.reconnectError, contains('Sign-in'));
    expect(controller.recovering, isFalse);
  });

  testWidgets('manual reconnect cancels a pending automatic retry', (
    tester,
  ) async {
    await controller.createChat();
    host.running = false;
    host.gateways['a']!.onConnectionChanged!(false);
    await tester.runAsync(
      () => controller.reconnect(controller.current!.scope),
    );
    final before = host.connectCalls;
    await tester.pump(const Duration(minutes: 1));
    expect(host.connectCalls, before);
    expect(controller.current!.retry, isNull);
  });

  test(
    'refresh resumes the selected chat and keeps unrelated errors',
    () async {
      final chat = await controller.createChat();
      host.running = false;
      await controller.refresh();
      expect(host.calls.where((c) => c.$2 == 'session.resume'), hasLength(1));
      expect(chat.status, ProfileTurnStatus.idle);

      controller.error = 'An unrelated operation failed';
      await controller.reconnect(chat.key.workspace);
      expect(controller.error, 'An unrelated operation failed');
    },
  );

  testWidgets('background recovery stays with its profile', (tester) async {
    final a = controller.current!;
    await controller.switchProfile('b');
    host.connectFailures = 6;
    host.gateways['a']!.onConnectionChanged!(false);
    for (final seconds in [1, 2, 4, 8, 16]) {
      await tester.pump(Duration(seconds: seconds));
    }
    expect(a.recovering, isTrue);
    expect(a.reconnectError, isNull);
    expect(controller.recovering, isFalse);
    expect(controller.error, isNull);
    host.connectFailures = 0;
    await tester.runAsync(() => controller.reconnect(a.scope));
    expect(a.recovering, isFalse);
    expect(controller.current!.scope.profileName, 'b');
  });

  test('background approval stays with its owning profile', () async {
    final a = await controller.createChat();
    a.draft = 'test';
    await controller.send(a);
    await controller.switchProfile('b');
    host.event('a', 'approval', {'request_id': 'dummy', 'command': 'dummy'});
    expect(a.status, ProfileTurnStatus.attention);
    expect(notifications, [a.key]);
    await controller.approve(
      a,
      'deny',
      requestId: a.approval!['request_id'] as String,
    );
    expect(host.calls.lastWhere((c) => c.$2 == 'approval.respond').$3, {
      'session_id': 'a-runtime',
      'request_id': 'dummy',
      'choice': 'deny',
      'profile': 'a',
    });
  });

  test(
    'persistent targets include connection profile and durable ID only',
    () async {
      final a = await controller.createChat();
      a.draft = 'secret draft';
      await controller.send(a);
      final key = preferences.getKeys().singleWhere(
        (k) => k.startsWith('profile_pending'),
      );
      final value = preferences.getStringList(key)!.single;
      expect(value, contains('"profile":"a"'));
      expect(value, contains('"session":"same"'));
      expect(value, isNot(contains('secret draft')));
    },
  );

  test('unavailable pending owner survives unrelated journal writes', () async {
    final chat = await controller.createChat();
    chat.draft = 'A turn';
    await controller.send(chat);
    final connection = controller.connection;
    controller.dispose();
    host.profiles = ['b'];
    controller = ProfileWorkspaceController(
      connectionIdentity: 'original-settings',
      connection: connection,
      preferences: preferences,
      gatewayFactory: host.gateway,
    );
    await controller.initialize();
    final b = await controller.createChat();
    b.draft = 'B turn';
    await controller.send(b);
    final journalKey = preferences.getKeys().singleWhere(
      (k) => k.startsWith('profile_pending'),
    );
    final saved = preferences.getStringList(journalKey)!;
    expect(saved.any((value) => value.contains('"profile":"a"')), isTrue);
    expect(saved.any((value) => value.contains('"profile":"b"')), isTrue);
  });

  test(
    'stock batched clarification routes the unanswered question ID',
    () async {
      final chat = await controller.createChat();
      chat.clarification = {
        'request_id': 'request',
        'questions': [
          {'qid': 'q0', 'question': 'First question'},
          {'qid': 'q1', 'question': 'What is the recovery marker?'},
        ],
        'answers': {'q0': 'already answered'},
      };
      expect(chat.pendingQuestion!['question'], 'What is the recovery marker?');
      await controller.clarify(chat, 'PROCESS_RECOVERY_QA');
      expect(host.calls.last.$3['question_id'], 'q1');
      expect(host.calls.last.$3['request_id'], 'request');
    },
  );

  test(
    'batch answers keep remaining questions attached to their owner',
    () async {
      final chat = await controller.createChat();
      chat.status = ProfileTurnStatus.attention;
      chat.clarification = {
        'request_id': 'batch',
        'questions': [
          {'qid': 'q0', 'question': 'First'},
          {'qid': 'q1', 'question': 'Second'},
        ],
      };
      await controller.switchProfile('b');
      host.clarifyResult = {
        'status': 'ok',
        'remaining': ['q1'],
      };
      await controller.clarify(chat, 'one');
      expect(chat.pendingQuestion!['question'], 'Second');
      expect(chat.status, ProfileTurnStatus.attention);
      expect(host.calls.last.$1, 'a');
      expect(host.calls.last.$3['question_id'], 'q0');
      host.clarifyResult = {'status': 'ok', 'remaining': []};
      await controller.clarify(chat, 'two');
      expect(host.calls.last.$3['question_id'], 'q1');
      expect(chat.clarification, isNull);
      expect(chat.status, ProfileTurnStatus.running);
      expect(controller.current!.scope.profileName, 'b');
    },
  );

  test(
    'single clarification sends its request ID without a batch ID',
    () async {
      final chat = await controller.createChat();
      chat.status = ProfileTurnStatus.attention;
      chat.clarification = {
        'request_id': 'single',
        'question': 'Which marker?',
      };
      expect(chat.pendingQuestion!['question'], 'Which marker?');
      await controller.clarify(chat, 'marker');
      expect(host.calls.last.$2, 'request.answer');
      expect(host.calls.last.$3['id'], 'single');
      expect(host.calls.last.$3['result'], {'answer': 'marker'});
      expect(host.calls.last.$3.containsKey('question_id'), isFalse);
      expect(chat.clarification, isNull);
    },
  );

  test(
    'expired input refreshes its owner without retrying the answer',
    () async {
      final chat = await controller.createChat();
      chat.status = ProfileTurnStatus.attention;
      chat.clarification = {'request_id': 'expired', 'question': 'Marker?'};
      host.running = false;
      host.clarifyResult = {'status': 'expired'};
      await controller.clarify(chat, 'marker');
      expect(chat.clarification, isNull);
      expect(chat.status, ProfileTurnStatus.completed);
      expect(chat.error, contains('expired'));
      expect(host.calls.where((c) => c.$2 == 'request.answer'), hasLength(1));
      expect(host.calls.where((c) => c.$2 == 'prompt.submit'), isEmpty);
    },
  );

  test('server cancellation removes only the matching clarification', () async {
    final chat = await controller.createChat();
    host.event('a', 'clarify', {
      'request_id': 'current-request',
      'questions': [
        {'qid': 'q0', 'question': 'Which room?'},
      ],
    });
    host.event('a', 'request.cancel', {
      'id': 'old-request',
      'method': 'clarify',
      'reason': 'timeout',
    });
    expect(chat.pendingQuestion!['question'], 'Which room?');
    host.event('a', 'request.cancel', {
      'id': 'current-request',
      'method': 'clarify',
      'reason': 'timeout',
    });
    expect(chat.pendingQuestion, isNull);
    expect(chat.status, ProfileTurnStatus.running);
    expect(
      host.calls.where(
        (call) => {
          'clarify.lock',
          'request.answer',
          'prompt.submit',
        }.contains(call.$2),
      ),
      isEmpty,
    );
  });
}
