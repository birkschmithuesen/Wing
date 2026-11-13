/// Isolated native QA entry point. Build with -PnotificationQa=true; never
/// install this fixture under the production package. Hermes is entirely fake.
library;

import 'package:wing/core/models/app_preferences.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:flutter/services.dart';
import 'package:wing/core/models/bots.dart';
import 'package:wing/core/models/chat_notification_content.dart';
import 'package:wing/core/models/group_notification.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/models/notification_focus.dart';
import 'package:wing/core/services/native_notification_sink.dart';
import 'package:wing/core/services/administration_repository.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/bots_repository.dart';
import 'package:wing/core/services/android_launch_intent_service.dart';
import '../test/support/bots_fixture.dart';
import '../test/support/host_resources_fixture.dart';
import 'package:wing/core/services/turn_notification_service.dart';

import 'dart:async';
import '../test/support/composer_fixture.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/ws_client.dart';
import 'package:wing/main.dart';
import 'package:wing/core/widgets/app_drawer.dart';
import '../test/profile_connection_identity_test.dart' show MemoryIdentityStore;
import '../test/profile_workspace_controller_test.dart' show Host;

ProfileGateway Function(WorkspaceScope) notificationFixtureGateways(
  Host primary,
  Host secondary,
) {
  // The discovery workspace is recovered on foreground entry too. It owns no
  // chats; returning primary's index violates the stock profile boundary and
  // makes the whole connection unavailable during notification Review.
  final bootstrap = Host()..indexedSessions = [];
  return (scope) => switch (scope.profileName) {
    'default' => bootstrap.gateway(scope),
    'a' => primary.gateway(scope),
    'b' => secondary.gateway(scope),
    _ => throw ArgumentError('Unknown notification fixture profile'),
  };
}

Future<({ProfileChat chat, ProfileChat other})> prepareNotificationFixtureChats(
  ProfileWorkspaceController controller, {
  required bool restarting,
}) async {
  if (restarting) {
    // The real native sink may already be opening its queued target. Reuse
    // the saved chats and hydrate their runtimes without selecting a profile
    // or creating replacement chats over that navigation.
    final chat = controller.notificationChats.singleWhere(
      (chat) =>
          chat.key.workspace.profileName == 'a' && chat.key.sessionId == 'same',
    );
    final other = controller.notificationChats.singleWhere(
      (chat) =>
          chat.key.workspace.profileName == 'b' && chat.key.sessionId == 'same',
    );
    await controller.loadNotificationApproval(chat.key);
    await controller.loadNotificationApproval(other.key);
    // Loading a runtime does not clear the profile's offline reading snapshot.
    // Recover both owners before later fixture sends, without selecting either.
    await controller.reconnect(chat.key.workspace);
    await controller.reconnect(other.key.workspace);
    return (chat: chat, other: other);
  }
  await controller.initialize();
  await controller.switchProfile('a');
  final chat = await controller.createChat(canDispatch: () => true);
  emitChatEvent(controller, chat, 'session.title', {
    'session_id': chat.key.sessionId,
    'title': 'Website refresh',
  });
  await controller.switchProfile('b');
  final other = await controller.createChat(canDispatch: () => true);
  emitChatEvent(controller, other, 'session.title', {
    'session_id': other.key.sessionId,
    'title': 'Weekly report',
  });
  return (chat: chat, other: other);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final manager = ConnectionManager(
    prefs,
    credentialStore: MemoryIdentityStore(),
  );
  final connection = SavedConnection(
    id: 'notification-qa',
    label: 'Home server',
    host: '127.0.0.1',
    port: 1,
    apiKey: '',
  );
  await manager.importConnections(
    [connection],
    replaceExisting: true,
    canCommit: () => true,
  );
  await prefs.setBool(
    AppPreferenceField.completedNotifications.storageKey,
    true,
  );
  await prefs.setBool(
    AppPreferenceField.attentionNotifications.storageKey,
    true,
  );
  await prefs.setBool('notification_permission_requested', true);
  await prefs.setBool('microphone_permission_requested', true);
  final savedHistory = prefs.getString('notification_qa_reply_history');
  final savedApprovals = prefs.getString('notification_qa_approvals');
  final host = Host()
    ..historyMessages = savedHistory == null
        ? null
        : (jsonDecode(savedHistory) as List)
              .map((row) => Map<String, dynamic>.from(row as Map))
              .toList()
    ..running = false
    ..pendingApprovals = savedApprovals == null
        ? []
        : (jsonDecode(savedApprovals) as List)
              .map((row) => Map<String, dynamic>.from(row as Map))
              .toList();
  final otherHost = Host()..running = false;
  final readAcknowledgements = <Map<String, String>>[];
  for (final (profile, fixture) in [('a', host), ('b', otherHost)]) {
    final title = profile == 'a' ? 'Website refresh' : 'Weekly report';
    fixture
      ..sessionTitle = title
      ..indexedSessions = [
        {'id': 'same', 'title': title, 'profile': profile},
      ];
    fixture.ownedPatch = (endpoint, body, canDispatch, onDispatched) async {
      if (endpoint != 'sessions/same' ||
          body.length != 5 ||
          body['profile'] != profile ||
          body['unread'] != false ||
          body['request_id'] is! String ||
          (body['request_id'] as String).isEmpty ||
          body['expected_revision'] != 0 ||
          body['expected_generation'] != 0 ||
          !canDispatch()) {
        throw StateError(
          'Unexpected notification read acknowledgement: $endpoint',
        );
      }
      onDispatched();
      readAcknowledgements.add({'profile': profile, 'session': 'same'});
      return {'ok': true};
    };
  }
  final savedDecisions = prefs.getString('notification_qa_decisions');
  if (savedDecisions != null) {
    for (final row in jsonDecode(savedDecisions) as List) {
      host.calls.add((
        'a',
        row['method'] as String,
        Map<String, dynamic>.from(row['params'] as Map),
      ));
    }
  }
  Future<void> persistApprovalState() async {
    await prefs.setString(
      'notification_qa_approvals',
      jsonEncode(host.pendingApprovals),
    );
    await prefs.setString(
      'notification_qa_decisions',
      jsonEncode(
        host.calls
            .where(
              (c) => c.$2 == 'approval.respond' || c.$2 == 'request.answer',
            )
            .map((c) => {'method': c.$2, 'params': c.$3})
            .toList(),
      ),
    );
  }

  host.onApprovalResponse = persistApprovalState;
  final groups = BotsFixture();
  for (final row in groups.profiles) {
    row['canonical_session'] = null;
  }
  groups.events.add({
    'room_id': 'room-1',
    'seq': 1,
    'kind': 'message.member',
    'created_at': 1791818730.0,
    'actor': {
      'kind': 'member',
      'id': 'atlas',
      'profile': 'atlas',
      'display_name': 'Atlas',
    },
    'payload': {'text': 'The shared discussion reached its exact destination.'},
  });
  final groupHost = Host();
  ProfileGateway gateway(WorkspaceScope scope) {
    final base = groupHost.gateway(scope);
    return ProfileGateway(
      scope: scope,
      discover: groupHost.discover,
      get: base.read,
      rpc: (method, params) =>
          method.startsWith('groups.') || method == 'profiles.list'
          ? groups.read(scope.profileName, method, params)
          : base.call(method, params),
    );
  }

  final launchIntents = AndroidLaunchIntentService();
  await launchIntents.initialize();
  final app = GlobalKey<WingAppState>();
  final fixtureGateway = notificationFixtureGateways(host, otherHost);
  runApp(
    WingApp(
      appPreferences: AppPreferences(prefs),
      key: app,
      launchIntents: launchIntents,
      connManager: manager,
      gatewayFactory: (_, scope) => fixtureGateway(scope),
    ),
  );
  await WidgetsBinding.instance.endOfFrame;
  final controller = await app.currentState!.profileController(connection);
  final resources = HostResourcesFixture(
    identity: controller.connectionIdentity,
  );
  controller.healthSession(
    repository: AdministrationRepository(
      connectionId: connection.id,
      connectionIdentity: controller.connectionIdentity,
      connectionLabel: connection.label,
      request: resources.server.request,
      settingsWrite: resources.server.settingsWrite,
      ownedMutation: resources.server.ownedMutation,
      gateway: (profile) => gateway(
        WorkspaceScope(
          connectionId: connection.id,
          connectionIdentity: controller.connectionIdentity,
          profileName: profile,
        ),
      ),
    ),
  );
  final (:chat, :other) = await prepareNotificationFixtureChats(
    controller,
    restarting: prefs.containsKey('notification_qa_sequence'),
  );
  final chatGateway = host.gateways['a']!;
  final otherGateway = otherHost.gateways['b']!;
  void event(ProfileChat target, String type, Map<String, dynamic> data) {
    final gateway = identical(target, chat) ? chatGateway : otherGateway;
    if (type == 'approval') {
      type = 'approval.request';
      data = {
        ...data,
        'kind': 'approval',
        'prompt_id': data['request_id'],
        'execution_generation': gateway.canonical
            .session(target.runtime.runtimeId)!
            .generation,
      }..remove('request_id');
    }
    (identical(target, chat) ? chatGateway : otherGateway).onEvent!(
      StreamEvent(type: type, sessionId: target.runtime.runtimeId, data: data),
    );
  }

  var sequence = prefs.getInt('notification_qa_sequence') ?? 0;
  Completer<void>? notificationHistory;
  final nativeGroupTarget = GroupNotificationTarget(
    WorkspaceScope(
      connectionId: connection.id,
      connectionIdentity: controller.connectionIdentity,
      profileName: 'a',
    ),
    'room-1',
  );
  final nativeGroupChat = jsonEncode(nativeGroupTarget.toJson());
  final monitoredGroup = BotsRepository.decodeGroup(
    nativeGroupTarget.scope,
    connection.label,
    groups.room,
  );
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 18766);
  await for (final request in server) {
    try {
      final data = request.method == 'POST'
          ? jsonDecode(await utf8.decoder.bind(request).join()) as Map
          : const {};
      switch (request.uri.path) {
        case '/native-group-answer':
          final answerTarget = data['room'] is String
              ? GroupNotificationTarget(
                  nativeGroupTarget.scope,
                  data['room'] as String,
                )
              : nativeGroupTarget;
          final notification = TurnNotification.chat(
            title: data['title'] as String? ?? 'Research team',
            content: ChatNotificationContent.reply(
              'The shared discussion reached its exact destination.',
            ),
            showPreview: true,
            scopeLabel: 'Home server / Group',
            payload: jsonEncode({
              ...answerTarget.toJson(),
              'focus': const NotificationFocus('answer', '1').toJson(),
            }),
            focus: const NotificationFocus('answer', '1'),
            chatIdentity: jsonEncode(answerTarget.toJson()),
            revision: 'answer:1',
          );
          await const MethodChannel(
            NativeNotificationSink.channelName,
          ).invokeMethod<void>('show', notification.toJson());
        case '/native-group-approval':
          final action = BotGroupAction(
            kind: 'approval',
            task: 'qa-task',
            member: 'qa-member',
            request: 'qa-request',
            generation: 1,
            command: data['long'] == true
                ? List.filled(80, 'echo group approval').join(' ')
                : 'echo group approval',
            choices: const ['once', 'deny'],
          );
          final focus = NotificationFocus(
            action.kind,
            groupApprovalFocusId(action),
          );
          final notification = TurnNotification.chat(
            title: 'Native group approval',
            content: ChatNotificationContent.approval(action.command, ''),
            showPreview: true,
            scopeLabel: 'Home server / Group',
            payload: jsonEncode({
              ...nativeGroupTarget.toJson(),
              'focus': focus.toJson(),
            }),
            focus: focus,
            chatIdentity: nativeGroupChat,
            revision: focus.identity,
            choices: action.choices,
            pending: '1 approval',
          );
          // Exercise the actual native renderer without installing another
          // sink handler or creating actionable backend work.
          await const MethodChannel(
            NativeNotificationSink.channelName,
          ).invokeMethod<void>('show', notification.toJson());
        case '/cancel-native-group-approval':
          await const MethodChannel(
            NativeNotificationSink.channelName,
          ).invokeMethod<void>(
            'cancel',
            TurnNotificationService.notificationIdFor(nativeGroupChat),
          );
        case '/hold-history':
          notificationHistory = Completer<void>();
          host.heldHistoryDelay = notificationHistory;
          host.heldHistoryStarted = Completer<void>();
        case '/release-history':
          notificationHistory?.complete();
          notificationHistory = null;
        case '/monitor-group':
          await controller.beginGroupSend(monitoredGroup, 'qa-monitored-send');
        case '/stop-monitor-group':
          await controller.finishGroupSend(
            monitoredGroup,
            'qa-monitored-send',
            dispatched: false,
          );
        case '/work-primary':
          host.running = true;
          chat.composer.editText('Update the website');
          await controller.send(chat);
        case '/work':
          otherHost.running = true;
          other.composer.editText('Prepare the weekly report');
          await controller.send(other);
        case '/approval':
          final id = 'qa-${++sequence}';
          final approval = <String, dynamic>{
            'request_id': id,
            'command': data['command'] ?? 'npm run deploy',
            'description': 'Publish the website preview',
            'choices': data['choices'] ?? ['once', 'session', 'always', 'deny'],
          };
          host.pendingApprovals!.add(approval);
          event(chat, 'approval', approval);
        case '/question':
          final count = (data['count'] as num?)?.toInt() ?? 3;
          final questions = [
            for (var index = 0; index < count; index++)
              {
                'qid': 'q$index',
                'question': 'Which sample output should I prepare?',
                'choices': ['Summary', 'Checklist'],
              },
          ];
          final request = {
            'id': 'qa-question-count',
            'method': 'clarify',
            'params': {
              'session_id': chat.runtime.runtimeId,
              'questions': questions,
            },
          };
          // Native shade navigation can reconnect the controller. Its stock
          // snapshots must retain the same pending request as the live event.
          host.approvalOpenRequests = [request];
          host.notificationActiveSessions = [
            {'id': chat.runtime.runtimeId, 'session_key': chat.key.sessionId},
          ];
          host.notificationReplay = {
            'open_requests': [request],
            'events': [],
            'latest_seq': 0,
            'truncated': false,
          };
          host.historyMessages = [];
          event(chat, 'clarify', {
            'request_id': request['id'],
            'questions': questions,
          });
        case '/reply':
          if (!chat.runtime.blocksTurnAdmission) {
            chat.composer.editText('Update the website');
            await controller.send(chat);
          }
          final answer =
              data['text'] as String? ??
              'The updated website is ready. Review the new mobile layout before publishing.';
          host.historyMessages = [
            {'id': ++sequence, 'role': 'assistant', 'content': answer},
          ];
          await prefs.setString(
            'notification_qa_reply_history',
            jsonEncode(host.historyMessages),
          );
          host.running = false;
          event(chat, 'message.complete', {'text': answer});
        case '/error':
          event(chat, 'turn.error', {
            'message':
                'The provider is unavailable. Review the chat before retrying.',
          });
        case '/disconnect':
          host.connectFailures = data['fail'] == true ? 20 : 0;
          chatGateway.onConnectionChanged!(false);
        case '/delay-decision':
          host.approvalDelay = Completer<void>();
        case '/release-decision':
          host.approvalDelay?.complete();
          host.approvalDelay = null;
        case '/fail':
          host.approvalFails = data['enabled'] == true;
        case '/remote':
          host.pendingApprovals!.clear();
          host.approvalOpenRequests.clear();
          host.notificationActiveSessions = [
            {'id': chat.runtime.runtimeId, 'session_key': chat.key.sessionId},
          ];
          host.notificationReplay = {
            'open_requests': [],
            'events': [],
            'latest_seq': 0,
            'truncated': false,
          };
        case '/preview':
          await prefs.setBool(
            AppPreferenceField.notificationPreviews.storageKey,
            data['enabled'] == true,
          );
          app.currentState!.refreshPreferences();
        case '/stop':
          otherHost.running = false;
          event(other, 'message.complete', {
            'text': 'The weekly report is ready to read.',
          });
        case '/list':
          // Use the ordinary Home navigation route underneath the later native
          // notification route; a direct /open alone misses shared visibility.
          HomeScreenState? home;
          void findHome(Element element) {
            if (element is StatefulElement &&
                element.state is HomeScreenState) {
              home = element.state as HomeScreenState;
            }
            element.visitChildren(findHome);
          }
          findHome(WidgetsBinding.instance.rootElement!);
          if (home == null) throw StateError('QA Home route is unavailable');
          controller.showList();
          await home!.selectWorkspaceConnection(
            connection,
            AppDestination.chats,
          );
        case '/open':
          await app.currentState!.openProfileNotification(
            jsonEncode(chat.key.toJson()),
          );
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await persistApprovalState();
      await prefs.setInt('notification_qa_sequence', sequence);
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'ready': true,
          'group_notification_id': TurnNotificationService.notificationIdFor(
            nativeGroupChat,
          ),
          'history_held':
              notificationHistory != null &&
              !notificationHistory.isCompleted &&
              host.heldHistoryStarted?.isCompleted == true,
          'runtime': chat.runtime.runtimeId,
          'pending': host.pendingApprovals,
          'decisions': host.calls
              .where(
                (c) => c.$2 == 'approval.respond' || c.$2 == 'request.answer',
              )
              .map((c) => {'method': c.$2, 'params': c.$3})
              .toList(),
          'notices': prefs.getString('chat_notification_state'),
          'lifecycle': WidgetsBinding.instance.lifecycleState?.name,
          'chat_visible': controller.visible,
          'selected_chat': controller.current?.chat?.key.sessionId,
          'selected_profile':
              controller.current?.chat?.key.workspace.profileName,
          'read_target': chat.reading.notificationReadTarget?.toJson(),
          'read_acks': readAcknowledgements,
          'mark_read_failed': chat.markReadFailed,
          'read_guards': {
            'opening': chat.runtime.opening,
            'offline_snapshot': chat.runtime.offline,
            'history_loading': chat.reading.historyLoading,
            'history_error': chat.reading.historyError,
            'history_session': chat.reading.historySessionId,
            'selected_is_target': identical(controller.current?.chat, chat),
          },
          'notification_focus': chat.reading.notificationFocus?.toJson(),
          'notification_focus_generation':
              chat.reading.notificationFocusGeneration,
          'message_rows': [
            for (final row in chat.reading.messages)
              {
                'id': row['id'],
                'role': row['role'],
                'content_type': row['content'].runtimeType.toString(),
                'content_empty': row['content']?.toString().trim().isEmpty,
                'hidden': row['display_kind'] == 'hidden',
              },
          ],
        }),
      );
    } catch (error, stack) {
      request.response.statusCode = 500;
      request.response.write('$error\n$stack');
    } finally {
      await request.response.close();
    }
  }
}
