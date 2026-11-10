/// Native lifecycle fixture. Run with tools/qa/check_background_monitoring.py.
/// Uses production controllers, notification posting and the retained Android
/// engine; only Hermes transport responses are fixtures. No model calls.
library;

import 'package:wing/core/models/app_preferences.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/administration_repository.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/models/hermes_profile.dart';

import 'package:wing/core/services/connection_access.dart';
import 'dart:async';
import '../test/support/composer_fixture.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_connection_identity.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/profile_workspace_registry.dart';
import 'package:wing/core/services/turn_notification_service.dart';
import 'package:wing/core/services/ws_client.dart';
import 'package:wing/main.dart';

import '../test/profile_connection_identity_test.dart' show MemoryIdentityStore;
import '../test/support/host_resources_fixture.dart';
import '../test/profile_notification_coverage_test.dart'
    show NotificationCoverageHost;

// This fixture never opens administration, the other screen that uses a
// 30-second periodic timer. Observe the production WingApp polling timer without
// changing its callback, cadence or cancellation behavior.
class _NotificationPollProbe {
  final timers = <Timer>[];
  int ticks = 0;

  Timer createPeriodicTimer(
    Zone self,
    ZoneDelegate parent,
    Zone zone,
    Duration duration,
    void Function(Timer) callback,
  ) {
    if (duration != const Duration(seconds: 30)) {
      return parent.createPeriodicTimer(zone, duration, callback);
    }
    final timer = parent.createPeriodicTimer(zone, duration, (timer) {
      ticks++;
      callback(timer);
    });
    timers.add(timer);
    return timer;
  }

  Map<String, Object> get snapshot => {
    'schema': 1,
    'periodSeconds': 30,
    'created': timers.length,
    'active': timers.where((timer) => timer.isActive).length,
    'ticks': ticks,
  };
}

Future<void> main() {
  final probe = _NotificationPollProbe();
  // Binding initialization and runApp must share the instrumented zone.
  return runZoned(
    () => _runFixture(probe),
    zoneSpecification: ZoneSpecification(
      createPeriodicTimer: probe.createPeriodicTimer,
    ),
  );
}

Future<void> _runFixture(_NotificationPollProbe probe) async {
  WidgetsFlutterBinding.ensureInitialized();
  final preferences = await SharedPreferences.getInstance();
  final secrets = MemoryIdentityStore();
  final manager = ConnectionManager(preferences, credentialStore: secrets);
  final connection = SavedConnection(
    id: 'monitoring-native-fixture',
    label: 'Monitoring fixture',
    host: '127.0.0.1',
    port: 1,
    apiKey: '',
  );
  await manager.importConnections(
    [connection],
    replaceExisting: true,
    canCommit: () => true,
  );
  await preferences.setString('last_connection_id', connection.id);
  await preferences.setBool(
    AppPreferenceField.completedNotifications.storageKey,
    true,
  );
  await preferences.setBool(
    AppPreferenceField.attentionNotifications.storageKey,
    true,
  );
  final host = NotificationCoverageHost();
  final app = GlobalKey<WingAppState>();
  final sink = PluginTurnNotificationSink(
    onOpen: (payload) {
      app.currentState?.openProfileNotification(payload);
    },
  );
  await sink.initialize();
  var alerts = 0;
  var nextReplyId = 1;
  var nextQuestionId = 1;
  final generation = DateTime.now().microsecondsSinceEpoch.toString();
  // Stock session.create returns a new identity. A recreated fixture engine
  // must not accidentally reopen an earlier generation's persisted outbox.
  for (final profile in ['a', 'b']) {
    final id = 'monitoring-$generation-$profile';
    host.createdSessionIds[profile] = id;
    host.saved[profile] = [
      {'id': id, 'profile': profile},
    ];
  }
  final appPreferences = AppPreferences(preferences);
  final registry = ProfileWorkspaceRegistry(
    identities: ProfileConnectionIdentity(credentialStore: secrets),
    create: (saved, identity) => ProfileWorkspaceController(
      access: ConnectionAccess(connection: saved, dashboardOAuth: null),
      connectionIdentity: identity,
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
      onAttention: (chat) async {
        final id = 240001 + alerts;
        await sink.show(
          TurnNotification(
            id: id,
            title: chat.title,
            body: chat.content.body(showPreview: true),
            expandedBody: chat.content.body(showPreview: true, limit: 800),
            scopeLabel:
                '${chat.connectionLabel} / ${chat.key.workspace.profileName}',
            payload: jsonEncode(chat.key.toJson()),
            channel: TurnNotificationService.turnChannel,
          ),
        );
        alerts++;
      },
    ),
  );
  final controller = await registry.forConnection(connection);
  // Recents warms the independent Bots transport at startup too. Keep it on
  // fixture responses instead of attempting the deliberately unused TCP port.
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
      gateway: (profile) => ProfileGateway(
        scope: WorkspaceScope(
          connectionId: connection.id,
          connectionIdentity: controller.connectionIdentity,
          profileName: profile,
        ),
        discover: host.discover,
        get: (path, query) async =>
            throw StateError('Unexpected administration read: $path'),
        rpc: (method, params) async => switch (method) {
          'profiles.list' => {
            'bot_mode_protocol': true,
            'install_id': controller.connectionIdentity,
            'profiles': <Map<String, dynamic>>[],
          },
          'groups.list' => {'rooms': <Map<String, dynamic>>[]},
          'groups.capabilities' => {
            'driver': true,
            'seatable_profiles': <String>[],
            'methods': <String>[],
          },
          'setup.status' => {'profile': profile, 'provider_configured': true},
          _ => throw StateError('Unexpected administration method: $method'),
        },
      ),
    ),
  );
  await controller.initialize();
  final chats = <String, ProfileChat>{};
  for (final profile in ['a', 'b']) {
    await controller.switchProfile(profile);
    final chat = await controller.createChat(canDispatch: () => true);
    emitChatEvent(controller, chat, 'session.title', {
      'session_id': chat.key.sessionId,
      'title': profile == 'a' ? 'First task' : 'Second task',
    });
    chats[profile] = chat;
  }
  await controller.switchProfile('a');
  runApp(
    WingApp(
      key: app,
      connManager: manager,
      profileControllers: registry,
      appPreferences: appPreferences,
    ),
  );
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 18765);
  await for (final request in server) {
    try {
      if (request.method == 'POST' && request.uri.path == '/event') {
        final event =
            jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        final profile = event['profile'] as String;
        final chat = chats[profile]!;
        final state = event['state'] as String;
        final reply = '**Reply ready.** ${'More readable context. ' * 20}';
        if (state == 'idle') {
          // Recovery reads the completed reply from its actual profile owner.
          // Each completed turn has a distinct durable message identity.
          host.historyByProfile[profile] = [
            {'id': nextReplyId++, 'role': 'assistant', 'content': reply},
          ];
        }
        host.workingProfiles.remove(profile);
        host.waitingProfiles.remove(profile);
        if (state == 'working') host.workingProfiles.add(profile);
        if (state == 'waiting') host.waitingProfiles.add(profile);
        // Polling and stream observations describe the same backend state.
        host.active = [
          for (final entry in chats.entries)
            {
              'id': entry.value.runtime.runtimeId,
              'session_key': entry.value.key.sessionId,
              'status': host.workingProfiles.contains(entry.key)
                  ? 'working'
                  : host.waitingProfiles.contains(entry.key)
                  ? 'waiting'
                  : 'idle',
              'last_active': 1,
            },
        ];
        if (state == 'working') {
          if (chat.runtime.pendingQuestion != null) {
            await controller.clarify(chat, 'Continue');
          } else {
            chat.composer.editText('Native fixture work');
            await controller.send(chat);
          }
          host.startTurn(profile, chat.runtime.runtimeId);
        } else if (state == 'idle') {
          host.completeTurn(profile, chat.runtime.runtimeId, reply);
        } else {
          // A new question is not a replay of the previous answered request.
          // Recovery must observe the same unique identity as the live event.
          final questionId = 'question-$profile-${nextQuestionId++}';
          host.questionIds[profile] = questionId;
          host.gateways[profile]!.onEvent!(
            StreamEvent(
              type: 'clarify',
              sessionId: chat.runtime.runtimeId,
              data: {'request_id': questionId, 'question': 'Continue?'},
            ),
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      if (request.method == 'POST' && request.uri.path == '/close-activity') {
        await SystemNavigator.pop();
      }
      if (request.method == 'POST' && request.uri.path == '/alerts') {
        final enabled =
            jsonDecode(await utf8.decoder.bind(request).join()) as bool;
        await preferences.setBool(
          AppPreferenceField.completedNotifications.storageKey,
          enabled,
        );
        await preferences.setBool(
          AppPreferenceField.attentionNotifications.storageKey,
          enabled,
        );
        app.currentState!.refreshPreferences();
      }
      await preferences.reload();
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'fixture': 'background-monitoring-native',
          'buildMode': kDebugMode
              ? 'debug'
              : kProfileMode
              ? 'profile'
              : 'release',
          'notificationPoll': probe.snapshot,
          'generation': generation,
          'ready': host.gateways.containsKey('a'),
          'alerts': alerts,
          'active': registry.hasActiveChats,
          'controllerActive': controller.hasActiveChats,
          'switching': controller.switching,
          'selectedProfile': controller.current?.scope.profileName,
          'chats': {
            for (final entry in chats.entries)
              entry.key: {
                'session': entry.value.key.sessionId,
                'runtime': entry.value.runtime.runtimeId,
                'execution': entry.value.runtime.execution.name,
                'recovery': entry.value.runtime.recovery.name,
                'liveSessionConfirmed':
                    entry.value.runtime.liveSessionConfirmed,
                'needsInput': entry.value.runtime.needsInput,
                'error': entry.value.runtime.error,
                'composerError': entry.value.composer.observation.error,
                'queued': entry.value.composer.observation.queue.length,
                'paused': entry.value.composer.observation.paused,
                'sending': entry.value.composer.observation.sending,
              },
          },
          'lifecycle': WidgetsBinding.instance.lifecycleState?.name,
          'enabled':
              (preferences.getBool(
                    AppPreferenceField.completedNotifications.storageKey,
                  ) ??
                  true) ||
              (preferences.getBool(
                    AppPreferenceField.attentionNotifications.storageKey,
                  ) ??
                  true),
        }),
      );
    } catch (error, stack) {
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({'error': error.toString(), 'stack': stack.toString()}),
      );
    } finally {
      await request.response.close();
    }
  }
}
