import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';

import 'profile_connection_identity_test.dart' show identityTestConnection;
import 'profile_workspace_controller_test.dart' show Host;

/// Stock f42f579cf8bac4918ac9599bece71618afadd846: process.stop ignores its
/// optional owner fields and kills the whole registry. process.list/kill resolve
/// the live session and its processes (tui_gateway/methods_tools.py:265,285).
class _ScopedProcessHost extends Host {
  final owners = <String, String>{
    'owned-1': 'a-runtime',
    'owned-2': 'a-runtime',
    'owned-exited': 'a-runtime',
    'sibling': 'a-sibling-runtime',
    'other-profile': 'b-runtime',
  };
  final statuses = <String, String>{
    'owned-1': 'running',
    'owned-2': 'running',
    'owned-exited': 'exited',
    'sibling': 'running',
    'other-profile': 'running',
  };
  final processCalls = <(String, Map<String, dynamic>)>[];
  bool failList = false;
  bool failInterrupt = false;
  String? unconfirmedKill;
  Completer<Map<String, dynamic>>? delayedList;
  Completer<void>? listStarted;

  @override
  ProfileGateway gateway(WorkspaceScope scope) {
    final base = super.gateway(scope);
    return ProfileGateway(
      scope: scope,
      discover: base.discover,
      connect: base.connect,
      close: base.close,
      get: base.read,
      rpc: (method, params) async {
        if (method == 'commands.catalog') {
          return {'pairs': <Object>[], 'categories': <Object>[]};
        }
        if (method == 'session.interrupt' || method.startsWith('process.')) {
          processCalls.add((method, Map.of(params)));
          if (method == 'process.stop') {
            statuses.updateAll((_, _) => 'exited');
            return {'killed': owners.length};
          }
          final allowed = {
            'session_id',
            'profile',
            if (method == 'process.kill') 'process_id',
            if (method == 'session.interrupt') 'execution_generation',
          };
          expect(params.keys.toSet().difference(allowed), isEmpty);
          expect(params['session_id'], isA<String>());
          expect(params['profile'], scope.profileName);
          if (method == 'session.interrupt') {
            expect(params['execution_generation'], 0);
            if (failInterrupt) throw StateError('Interrupt rejected');
            return {'status': 'interrupted'};
          }
          if (method == 'process.list') {
            final delayed = delayedList;
            if (delayed != null) {
              delayedList = null;
              listStarted?.complete();
              return delayed.future;
            }
            if (failList) throw StateError('Process list unavailable');
            return {
              'processes': [
                for (final entry in owners.entries)
                  if (entry.value == params['session_id'])
                    {
                      'session_id': entry.key,
                      'command': 'worker ${entry.key}',
                      'status': statuses[entry.key],
                    },
              ],
            };
          }
          final id = params['process_id'] as String;
          expect(owners[id], params['session_id']);
          if (unconfirmedKill == id) return {'status': 'error'};
          statuses[id] = 'exited';
          return {'status': 'killed', 'session_id': id};
        }
        return base.call(method, params);
      },
    );
  }
}

void main() {
  late _ScopedProcessHost host;
  late ProfileWorkspaceController controller;
  late AppPreferences appPreferences;
  late ProfileChat chat;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    host = _ScopedProcessHost();
    final preferences = await SharedPreferences.getInstance();
    appPreferences = AppPreferences(preferences);
    controller = ProfileWorkspaceController(
      access: ConnectionAccess(
        connection: identityTestConnection(),
        dashboardOAuth: null,
      ),
      connectionIdentity: 'stop-command-scope',
      preferences: preferences,
      appPreferences: appPreferences,
      gatewayFactory: host.gateway,
    );
    await controller.initialize();
    chat = await controller.createChat(canDispatch: () => true);
  });

  tearDown(() {
    controller.dispose();
    appPreferences.dispose();
  });

  Future<void> send(String command) async {
    await controller.updateDraft(chat, command);
    await controller.send(chat);
  }

  test('/stop kills only this chat running processes', () async {
    await send('/stop');

    expect(host.processCalls.first.$1, 'session.interrupt');
    final kills = host.processCalls.where((call) => call.$1 == 'process.kill');
    expect(kills.map((call) => call.$2['process_id']), ['owned-1', 'owned-2']);
    expect(kills.every((call) => call.$2['session_id'] == 'a-runtime'), isTrue);
    expect(host.statuses['sibling'], 'running');
    expect(host.statuses['other-profile'], 'running');
    expect(host.statuses['owned-exited'], 'exited');
    expect(host.processCalls.any((call) => call.$1 == 'process.stop'), isFalse);
    expect(chat.composer.observation.text, isEmpty);
    expect(chat.runtime.error, isNull);
    expect(
      chat.reading.messages.last['content'],
      'Background processes stopped: 2',
    );
  });

  test('/interrupt leaves background processes running', () async {
    await send('/interrupt');
    expect(host.processCalls.map((call) => call.$1), ['session.interrupt']);
    expect(host.statuses['owned-1'], 'running');
    expect(host.statuses['sibling'], 'running');
  });

  test(
    '/stop refuses process writes when the list cannot be verified',
    () async {
      host.failList = true;
      await send('/stop');
      expect(host.processCalls.map((call) => call.$1), [
        'session.interrupt',
        'process.list',
      ]);
      expect(host.statuses['owned-1'], 'running');
      expect(host.statuses['sibling'], 'running');
      expect(chat.composer.observation.text, '/stop');
      expect(chat.runtime.error, contains('could not be confirmed'));
    },
  );

  test(
    '/stop reports an unconfirmed partial stop and retains its command',
    () async {
      host.unconfirmedKill = 'owned-2';
      await send('/stop');
      expect(host.statuses['owned-1'], 'exited');
      expect(host.statuses['owned-2'], 'running');
      expect(host.statuses['sibling'], 'running');
      expect(host.statuses['other-profile'], 'running');
      expect(chat.composer.observation.text, '/stop');
      expect(chat.runtime.error, contains('stop could not be confirmed'));
      expect(chat.reading.messages.last['content'], 'Interrupt requested.');
    },
  );

  test('/stop never kills processes after a rejected interrupt', () async {
    host.failInterrupt = true;
    await send('/stop');
    expect(host.processCalls.map((call) => call.$1), ['session.interrupt']);
    expect(host.statuses['owned-1'], 'running');
    expect(chat.composer.observation.text, '/stop');
    expect(chat.runtime.error, 'Interrupt rejected');
  });

  test(
    '/stop retains its command when the runtime changes during its read',
    () async {
      final delayed = host.delayedList = Completer<Map<String, dynamic>>();
      final started = host.listStarted = Completer<void>();
      final stopping = send('/stop');
      await started.future;
      host.runtimeForResume['a'] = 'replacement-runtime';
      await controller.openSession(chat.key);
      delayed.complete({'processes': <Object>[]});
      await stopping;

      expect(
        host.processCalls.where((call) => call.$1 == 'process.kill'),
        isEmpty,
      );
      expect(chat.composer.observation.text, '/stop');
      expect(chat.runtime.error, contains('could not be confirmed'));
      expect(chat.reading.messages.last['content'], 'Interrupt requested.');
    },
  );

  test(
    '/stop does not trust an empty cached list after a superseded read',
    () async {
      final delayed = host.delayedList = Completer<Map<String, dynamic>>();
      final started = host.listStarted = Completer<void>();
      final stopping = send('/stop');
      await started.future;
      // A concurrent refresh supersedes the command's response but fails, so the
      // empty cached list still does not describe the server's running workers.
      host.failList = true;
      await controller.refreshProcesses(chat);
      delayed.complete({
        'processes': [
          {
            'session_id': 'owned-1',
            'command': 'worker owned-1',
            'status': 'running',
          },
        ],
      });
      await stopping;

      expect(
        host.processCalls.where((call) => call.$1 == 'process.kill'),
        isEmpty,
      );
      expect(host.statuses['owned-1'], 'running');
      expect(chat.composer.observation.text, '/stop');
      expect(chat.runtime.error, contains('could not be confirmed'));
      expect(chat.reading.messages.last['content'], 'Interrupt requested.');
    },
  );

  test(
    '/stop confirms zero processes only after a valid fresh empty read',
    () async {
      host.statuses.updateAll((_, _) => 'exited');
      await send('/stop');

      expect(host.processCalls.map((call) => call.$1), [
        'session.interrupt',
        'process.list',
      ]);
      expect(chat.composer.observation.text, isEmpty);
      expect(chat.runtime.error, isNull);
      expect(
        chat.reading.messages.last['content'],
        'Background processes stopped: 0',
      );
    },
  );
}
